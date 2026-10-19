-- Make invoice posting atomic for API/MCP calls
-- Accept optional p_user_id to set JWT context within the same transaction

-- ============================================================================
-- POST INVOICE (with optional user_id for API/MCP)
-- ============================================================================

create or replace function post_invoice(
  p_invoice_id uuid,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_total_cents bigint;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_line record;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Set JWT context if user_id provided (for API/MCP calls)
  if p_user_id is not null then
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', p_user_id::text)::text,
      true  -- local to this transaction
    );
  end if;

  -- Get current user
  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Get invoice with lock
  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  -- Check membership and role (must be bookkeeper+)
  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  v_current_role := "current_role"();

  -- Check can_post
  select can_post into v_can_post
  from memberships
  where organization_id = v_organization_id
    and user_id = v_current_user_id;

  if not v_can_post then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: can_post permission required'
    );
  end if;

  -- Only allow Draft or Quote status
  if v_invoice.status != 'Draft' and v_invoice.status != 'Quote' then
    return jsonb_build_object(
      'success', false,
      'error', format('Invoice is already %s', v_invoice.status)
    );
  end if;

  -- Refuse to post Quote
  if v_invoice.status = 'Quote' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a quote. Change status to Draft first.'
    );
  end if;

  -- Get customer contact and validate it's type Customer
  declare
    v_contact_type text;
  begin
    select contact_type into v_contact_type
    from contacts
    where id = v_invoice.customer_id
      and organization_id = v_organization_id;

    if v_contact_type != 'Customer' then
      return jsonb_build_object(
        'success', false,
        'error', 'Only Customer contacts can be invoiced. Parent contacts must use draft_journal for equity (Dr 1010 / Cr 3100).'
      );
    end if;
  end;

  -- Check period lock
  v_period_info := check_period_lock(v_organization_id, v_invoice.invoice_date);
  if (v_period_info->>'locked')::boolean then
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot post invoice with date %s: %s is Locked. No one can post to a locked month. Reopen the period in Settings → Periods first.',
        v_invoice.invoice_date,
        v_period_info->>'month_name'
      )
    );
  end if;

  -- Get AR account (1100)
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100'
  limit 1;

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Accounts Receivable account (1100) not found'
    );
  end if;

  -- Generate journal number
  select count(*) + 1 into v_journal_number
  from journals
  where organization_id = v_organization_id;

  v_journal_number := 'JE-' || extract(year from v_invoice.invoice_date) || '-' || lpad(v_journal_number::text, 4, '0');

  -- Create journal
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    v_invoice.invoice_date,
    'Invoice ' || v_invoice.number,
    'Draft',
    'invoice',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Create journal lines: Dr 1100 AR / Cr Revenue accounts
  for v_line in
    select account_id, amount_cents, description
    from invoice_lines
    where invoice_id = p_invoice_id
    order by line_number
  loop
    -- Credit revenue account
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_organization_id,
      v_journal_id,
      v_line.account_id,
      0,
      v_line.amount_cents,
      v_line.description
    );
  end loop;

  -- Debit AR account
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    v_invoice.total_cents,
    0,
    'Invoice ' || v_invoice.number
  );

  -- Post the journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception 'Failed to post journal: %', v_post_result->>'error';
    end if;
  end;

  -- Update invoice status to Posted (atomic with journal post)
  update invoices
  set 
    status = 'Posted',
    recognition_journal_id = v_journal_id,
    updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  insert into audit_log (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    details
  ) values (
    v_organization_id,
    v_current_user_id,
    'invoice.posted',
    'invoice',
    p_invoice_id,
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'journal_id', v_journal_id,
      'journal_number', v_journal_number,
      'amount_cents', v_invoice.total_cents
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function post_invoice to authenticated, service_role;

comment on function post_invoice is 'Post a draft invoice (creates Dr 1100 / Cr Revenue journal). Accepts optional p_user_id for API/MCP calls to set JWT context atomically.';

-- ============================================================================
-- RECORD RECEIPT (with optional user_id)
-- ============================================================================

create or replace function record_receipt(
  p_invoice_id uuid,
  p_receipt_date date,
  p_amount_cents bigint,
  p_cash_account_id uuid,
  p_notes text default null,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_remaining_cents bigint;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Set JWT context if user_id provided
  if p_user_id is not null then
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', p_user_id::text)::text,
      true
    );
  end if;

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Get invoice with lock
  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  -- Check permissions
  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied'
    );
  end if;

  select can_post into v_can_post
  from memberships
  where organization_id = v_organization_id
    and user_id = v_current_user_id;

  if not v_can_post then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: can_post permission required'
    );
  end if;

  -- Validate invoice status
  if v_invoice.status != 'Posted' and v_invoice.status != 'Partial' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice must be posted before recording receipts'
    );
  end if;

  -- Check period lock
  v_period_info := check_period_lock(v_organization_id, p_receipt_date);
  if (v_period_info->>'locked')::boolean then
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot record receipt with date %s: %s is Locked. Reopen the period first.',
        p_receipt_date,
        v_period_info->>'month_name'
      )
    );
  end if;

  -- Get AR account
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100'
  limit 1;

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'AR account (1100) not found'
    );
  end if;

  -- Generate journal number
  select count(*) + 1 into v_journal_number
  from journals
  where organization_id = v_organization_id;

  v_journal_number := 'JE-' || extract(year from p_receipt_date) || '-' || lpad(v_journal_number::text, 4, '0');

  -- Create journal: Dr Cash / Cr AR
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    p_receipt_date,
    'Receipt for Invoice ' || v_invoice.number,
    'Draft',
    'receipt',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Cash
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    p_cash_account_id,
    p_amount_cents,
    0,
    coalesce(p_notes, 'Receipt for Invoice ' || v_invoice.number)
  );

  -- Cr AR
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    0,
    p_amount_cents,
    'Receipt for Invoice ' || v_invoice.number
  );

  -- Post journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception 'Failed to post journal: %', v_post_result->>'error';
    end if;
  end;

  -- Update invoice (atomic with journal post)
  v_remaining_cents := v_invoice.total_cents - (v_invoice.received_cents + p_amount_cents);

  update invoices
  set 
    received_cents = received_cents + p_amount_cents,
    status = case
      when received_cents + p_amount_cents >= total_cents then 'Paid'
      else 'Partial'
    end,
    updated_at = now()
  where id = p_invoice_id;

  -- Audit log
  insert into audit_log (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    details
  ) values (
    v_organization_id,
    v_current_user_id,
    'invoice.receipt',
    'invoice',
    p_invoice_id,
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'journal_id', v_journal_id,
      'amount_cents', p_amount_cents,
      'remaining_cents', v_remaining_cents
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function record_receipt to authenticated, service_role;

-- ============================================================================
-- ISSUE CREDIT NOTE (with optional user_id)
-- ============================================================================

create or replace function issue_credit_note(
  p_invoice_id uuid,
  p_credit_date date,
  p_amount_cents bigint,
  p_reason text,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_revenue_account_id uuid;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Set JWT context if user_id provided
  if p_user_id is not null then
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', p_user_id::text)::text,
      true
    );
  end if;

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied'
    );
  end if;

  select can_post into v_can_post
  from memberships
  where organization_id = v_organization_id
    and user_id = v_current_user_id;

  if not v_can_post then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: can_post permission required'
    );
  end if;

  if v_invoice.status != 'Posted' and v_invoice.status != 'Partial' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice must be posted before issuing credits'
    );
  end if;

  v_period_info := check_period_lock(v_organization_id, p_credit_date);
  if (v_period_info->>'locked')::boolean then
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot issue credit with date %s: %s is Locked.',
        p_credit_date,
        v_period_info->>'month_name'
      )
    );
  end if;

  -- Get AR account
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100'
  limit 1;

  -- Get primary revenue account from invoice lines
  select account_id into v_revenue_account_id
  from invoice_lines
  where invoice_id = p_invoice_id
  order by amount_cents desc
  limit 1;

  select count(*) + 1 into v_journal_number
  from journals
  where organization_id = v_organization_id;

  v_journal_number := 'JE-' || extract(year from p_credit_date) || '-' || lpad(v_journal_number::text, 4, '0');

  -- Create journal: Dr Revenue / Cr AR
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    p_credit_date,
    'Credit Note for Invoice ' || v_invoice.number,
    'Draft',
    'credit_note',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Revenue
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_revenue_account_id,
    p_amount_cents,
    0,
    p_reason
  );

  -- Cr AR
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    0,
    p_amount_cents,
    'Credit Note: ' || p_reason
  );

  -- Post journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception 'Failed to post journal: %', v_post_result->>'error';
    end if;
  end;

  -- Update invoice total (atomic)
  update invoices
  set 
    total_cents = total_cents - p_amount_cents,
    updated_at = now()
  where id = p_invoice_id;

  insert into audit_log (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    details
  ) values (
    v_organization_id,
    v_current_user_id,
    'invoice.credit',
    'invoice',
    p_invoice_id,
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'journal_id', v_journal_id,
      'amount_cents', p_amount_cents,
      'reason', p_reason
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function issue_credit_note to authenticated, service_role;

-- ============================================================================
-- WRITE OFF INVOICE (with optional user_id)
-- ============================================================================

create or replace function write_off_invoice(
  p_invoice_id uuid,
  p_write_off_date date,
  p_amount_cents bigint,
  p_reason text,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_bad_debt_account_id uuid;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Set JWT context if user_id provided
  if p_user_id is not null then
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', p_user_id::text)::text,
      true
    );
  end if;

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied'
    );
  end if;

  select can_post into v_can_post
  from memberships
  where organization_id = v_organization_id
    and user_id = v_current_user_id;

  if not v_can_post then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: can_post permission required'
    );
  end if;

  if v_invoice.status != 'Posted' and v_invoice.status != 'Partial' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice must be posted before writing off'
    );
  end if;

  v_period_info := check_period_lock(v_organization_id, p_write_off_date);
  if (v_period_info->>'locked')::boolean then
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot write off with date %s: %s is Locked.',
        p_write_off_date,
        v_period_info->>'month_name'
      )
    );
  end if;

  -- Get accounts
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100'
  limit 1;

  select id into v_bad_debt_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '5110'
  limit 1;

  if v_bad_debt_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Bad Debt Expense account (5110) not found'
    );
  end if;

  select count(*) + 1 into v_journal_number
  from journals
  where organization_id = v_organization_id;

  v_journal_number := 'JE-' || extract(year from p_write_off_date) || '-' || lpad(v_journal_number::text, 4, '0');

  -- Create journal: Dr Bad Debt / Cr AR
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    p_write_off_date,
    'Write-off for Invoice ' || v_invoice.number,
    'Draft',
    'write_off',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Bad Debt
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_bad_debt_account_id,
    p_amount_cents,
    0,
    p_reason
  );

  -- Cr AR
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    0,
    p_amount_cents,
    'Write-off: ' || p_reason
  );

  -- Post journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception 'Failed to post journal: %', v_post_result->>'error';
    end if;
  end;

  -- Update invoice (atomic)
  update invoices
  set 
    received_cents = received_cents + p_amount_cents,
    status = case
      when received_cents + p_amount_cents >= total_cents then 'Paid'
      else 'Partial'
    end,
    updated_at = now()
  where id = p_invoice_id;

  insert into audit_log (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    details
  ) values (
    v_organization_id,
    v_current_user_id,
    'invoice.write_off',
    'invoice',
    p_invoice_id,
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'journal_id', v_journal_id,
      'amount_cents', p_amount_cents,
      'reason', p_reason
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function write_off_invoice to authenticated, service_role;

-- ============================================================================
-- SEND INVOICE REMINDER (with optional user_id)
-- ============================================================================

create or replace function send_invoice_reminder(
  p_invoice_id uuid,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_organization_id uuid;
  v_current_user_id uuid;
begin
  -- Set JWT context if user_id provided
  if p_user_id is not null then
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', p_user_id::text)::text,
      true
    );
  end if;

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select * into v_invoice
  from invoices
  where id = p_invoice_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  if current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied'
    );
  end if;

  -- Just log audit event (no email, no journal)
  insert into audit_log (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    details
  ) values (
    v_organization_id,
    v_current_user_id,
    'invoice.reminder_sent',
    'invoice',
    p_invoice_id,
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'note', 'Reminder logged (no email sent)'
    )
  );

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function send_invoice_reminder to authenticated, service_role;

comment on function send_invoice_reminder is 'Log invoice reminder in audit log only. No email sent, no journal created, no Pay now.';
