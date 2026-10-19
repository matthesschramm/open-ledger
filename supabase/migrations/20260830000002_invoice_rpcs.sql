-- Open Ledger S2-6: Invoice RPCs
-- SECURITY DEFINER functions for invoice posting, receipts, credit notes, and write-offs

-- ============================================================================
-- POST INVOICE
-- ============================================================================

create or replace function post_invoice(p_invoice_id uuid)
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

  -- Check if already posted
  if v_invoice.status = 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice already posted'
    );
  end if;

  -- Check if paid
  if v_invoice.status = 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a paid invoice'
    );
  end if;

  -- Check if void
  if v_invoice.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a void invoice'
    );
  end if;

  -- Refuse to post Quote status
  if v_invoice.status = 'Quote' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a quote. Save the invoice as Draft instead.'
    );
  end if;

  -- Check period status
  v_can_post := can_post_to_period(
    v_organization_id,
    v_invoice.invoice_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, v_invoice.invoice_date);
    
    if v_period_info is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Cannot post to this date'
      );
    end if;

    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot post invoice with date %s: %s is %s. %s',
        to_char(v_invoice.invoice_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status',
        case
          when v_period_info->>'status' = 'Soft-closed' then 'Only the owner can post to a soft-closed month.'
          when v_period_info->>'status' = 'Locked' then 'No one can post to a locked month. Reopen the period in Settings → Periods first.'
          else ''
        end
      ),
      'period_name', v_period_info->>'period_name',
      'period_status', v_period_info->>'status'
    );
  end if;

  -- Validate customer contact type
  declare
    v_contact_type contact_type;
  begin
    select type into v_contact_type
    from contacts
    where id = v_invoice.customer_id;

    if v_contact_type != 'Customer' then
      return jsonb_build_object(
        'success', false,
        'error', format('Cannot invoice contact type %s. Only Customer contacts can be invoiced.', v_contact_type)
      );
    end if;
  end;

  -- Get or create AR account (1100)
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100'
    and is_active = true;

  if v_ar_account_id is null then
    -- Create AR account if missing
    insert into accounts (
      organization_id,
      code,
      name,
      type,
      category,
      is_system,
      is_active
    ) values (
      v_organization_id,
      '1100',
      'Accounts Receivable',
      'Asset',
      'AR',
      true,
      true
    )
    returning id into v_ar_account_id;
  end if;

  -- Calculate total from lines
  select coalesce(sum(amount_cents), 0) into v_total_cents
  from invoice_lines
  where invoice_id = p_invoice_id;

  if v_total_cents = 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice must have at least one line with non-zero amount'
    );
  end if;

  -- Update invoice total if needed
  if v_invoice.total_cents != v_total_cents then
    update invoices
    set total_cents = v_total_cents,
        updated_at = now()
    where id = p_invoice_id;
  end if;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from v_invoice.invoice_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create recognition journal (Draft first)
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
    format('Invoice %s', v_invoice.number),
    'Draft',
    'manual',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr 1100 Accounts Receivable
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
    v_total_cents,
    0,
    format('Invoice %s', v_invoice.number)
  );

  -- Cr revenue accounts (one line per invoice line)
  for v_line in
    select * from invoice_lines
    where invoice_id = p_invoice_id
    order by line_number
  loop
    -- Validate account is revenue type
    declare
      v_account_type account_type;
    begin
      select type into v_account_type
      from accounts
      where id = v_line.account_id;

      if v_account_type != 'Revenue' then
        raise exception 'Account % is not a revenue account', v_line.account_id;
      end if;
    end;

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

  -- Post the journal via existing post_journal RPC
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      return v_post_result;
    end if;
  end;

  -- Update invoice
  update invoices
  set status = 'Posted',
      recognition_journal_id = v_journal_id,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'invoice_posted',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'invoice_date', v_invoice.invoice_date,
      'total_cents', v_total_cents,
      'journal_id', v_journal_id,
      'journal_number', v_journal_number
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function post_invoice to authenticated;

comment on function post_invoice is 'Posts an invoice, creating Dr AR / Cr Revenue journal. Validates period locks and revenue account types.';

-- ============================================================================
-- RECORD RECEIPT (PAYMENT)
-- ============================================================================

create or replace function record_receipt(
  p_invoice_id uuid,
  p_receipt_date date,
  p_amount_cents bigint,
  p_cash_account_id uuid,
  p_notes text default null
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
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_new_received_cents bigint;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
  v_current_role := "current_role"();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Check role
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
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

  -- Check if invoice is posted
  if v_invoice.status != 'Posted' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only record receipts for Posted or Paid invoices'
    );
  end if;

  -- Check amount
  if p_amount_cents <= 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Receipt amount must be greater than zero'
    );
  end if;

  v_new_received_cents := v_invoice.received_cents + p_amount_cents;

  if v_new_received_cents > v_invoice.total_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Receipt amount exceeds invoice balance'
    );
  end if;

  -- Check period
  v_can_post := can_post_to_period(
    v_organization_id,
    p_receipt_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_receipt_date);
    
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot record receipt with date %s: %s is %s.',
        to_char(p_receipt_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status'
      )
    );
  end if;

  -- Get AR account (1100)
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100';

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'AR account (1100) not found'
    );
  end if;

  -- Validate cash account
  declare
    v_is_cash boolean;
  begin
    select is_cash into v_is_cash
    from accounts
    where id = p_cash_account_id
      and organization_id = v_organization_id;

    if not v_is_cash then
      return jsonb_build_object(
        'success', false,
        'error', 'Selected account is not a cash account'
      );
    end if;
  end;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from p_receipt_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create receipt journal (Draft first)
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
    format('Receipt for invoice %s', v_invoice.number),
    'Draft',
    'manual',
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
    format('Receipt for %s', v_invoice.number)
  );

  -- Cr AR (1100)
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
    format('Receipt for %s', v_invoice.number)
  );

  -- Post the journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      return v_post_result;
    end if;
  end;

  -- Record receipt
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    notes,
    created_by
  ) values (
    v_organization_id,
    p_invoice_id,
    v_journal_id,
    p_receipt_date,
    p_amount_cents,
    'payment',
    p_notes,
    v_current_user_id
  );

  -- Update invoice
  update invoices
  set received_cents = v_new_received_cents,
      status = case
        when v_new_received_cents >= total_cents then 'Paid'::invoice_status
        else 'Posted'::invoice_status
      end,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'receipt_recorded',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'receipt_date', p_receipt_date,
      'amount_cents', p_amount_cents,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function record_receipt to authenticated;

comment on function record_receipt is 'Records a cash receipt against an invoice: Dr Cash / Cr AR';

-- ============================================================================
-- ISSUE CREDIT NOTE
-- ============================================================================

create or replace function issue_credit_note(
  p_invoice_id uuid,
  p_credit_date date,
  p_amount_cents bigint,
  p_reason text
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
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_revenue_account_id uuid;
  v_new_received_cents bigint;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
  v_current_role := "current_role"();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Check role
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
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

  -- Check if invoice is posted
  if v_invoice.status != 'Posted' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only issue credit notes for Posted or Paid invoices'
    );
  end if;

  -- Check amount
  if p_amount_cents <= 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Credit note amount must be greater than zero'
    );
  end if;

  v_new_received_cents := v_invoice.received_cents + p_amount_cents;

  if v_new_received_cents > v_invoice.total_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Credit note amount exceeds invoice balance'
    );
  end if;

  -- Check period
  v_can_post := can_post_to_period(
    v_organization_id,
    p_credit_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_credit_date);
    
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot issue credit note with date %s: %s is %s.',
        to_char(p_credit_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status'
      )
    );
  end if;

  -- Get AR account (1100) for credit note
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100';

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'AR account (1100) not found'
    );
  end if;

  -- Get first revenue account from original invoice lines
  select il.account_id into v_revenue_account_id
  from invoice_lines il
  join accounts a on a.id = il.account_id
  where il.invoice_id = p_invoice_id
    and a.type = 'Revenue'
  order by il.line_number
  limit 1;

  if v_revenue_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'No revenue account found on invoice'
    );
  end if;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from p_credit_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create credit note journal (Draft first)
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
    format('Credit note for invoice %s: %s', v_invoice.number, p_reason),
    'Draft',
    'manual',
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
    format('Credit note for %s', v_invoice.number)
  );

  -- Cr AR (1100)
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
    format('Credit note for %s', v_invoice.number)
  );

  -- Post the journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      return v_post_result;
    end if;
  end;

  -- Record credit note as receipt
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    notes,
    created_by
  ) values (
    v_organization_id,
    p_invoice_id,
    v_journal_id,
    p_credit_date,
    p_amount_cents,
    'credit_note',
    p_reason,
    v_current_user_id
  );

  -- Update invoice
  update invoices
  set received_cents = v_new_received_cents,
      status = case
        when v_new_received_cents >= total_cents then 'Paid'::invoice_status
        else 'Posted'::invoice_status
      end,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'credit_note_issued',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'credit_date', p_credit_date,
      'amount_cents', p_amount_cents,
      'reason', p_reason,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function issue_credit_note to authenticated;

comment on function issue_credit_note is 'Issues a credit note against an invoice: Dr Revenue / Cr AR';

-- ============================================================================
-- WRITE OFF INVOICE
-- ============================================================================

create or replace function write_off_invoice(
  p_invoice_id uuid,
  p_write_off_date date,
  p_amount_cents bigint,
  p_reason text
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
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_bad_debt_account_id uuid;
  v_new_received_cents bigint;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
  v_current_role := "current_role"();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Check role
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
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

  -- Check if invoice is posted
  if v_invoice.status != 'Posted' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only write off Posted or Paid invoices'
    );
  end if;

  -- Check amount
  if p_amount_cents <= 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Write-off amount must be greater than zero'
    );
  end if;

  v_new_received_cents := v_invoice.received_cents + p_amount_cents;

  if v_new_received_cents > v_invoice.total_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Write-off amount exceeds invoice balance'
    );
  end if;

  -- Check period
  v_can_post := can_post_to_period(
    v_organization_id,
    p_write_off_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_write_off_date);
    
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot write off with date %s: %s is %s.',
        to_char(p_write_off_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status'
      )
    );
  end if;

  -- Get AR account (1100)
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100';

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'AR account (1100) not found'
    );
  end if;

  -- Get or create Bad Debt expense account (5110)
  select id into v_bad_debt_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '5110'
    and is_active = true;

  if v_bad_debt_account_id is null then
    -- Create Bad Debt expense account
    insert into accounts (
      organization_id,
      code,
      name,
      type,
      category,
      is_active
    ) values (
      v_organization_id,
      '5110',
      'Bad Debt Expense',
      'Expense',
      'Expense',
      true
    )
    returning id into v_bad_debt_account_id;
  end if;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from p_write_off_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create write-off journal (Draft first)
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
    format('Write-off invoice %s: %s', v_invoice.number, p_reason),
    'Draft',
    'manual',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Bad Debt Expense
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
    format('Write-off %s', v_invoice.number)
  );

  -- Cr AR (1100)
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
    format('Write-off %s', v_invoice.number)
  );

  -- Post the journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      return v_post_result;
    end if;
  end;

  -- Record write-off as receipt
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    notes,
    created_by
  ) values (
    v_organization_id,
    p_invoice_id,
    v_journal_id,
    p_write_off_date,
    p_amount_cents,
    'write_off',
    p_reason,
    v_current_user_id
  );

  -- Update invoice
  update invoices
  set received_cents = v_new_received_cents,
      status = case
        when v_new_received_cents >= total_cents then 'Paid'::invoice_status
        else 'Posted'::invoice_status
      end,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'invoice_written_off',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'write_off_date', p_write_off_date,
      'amount_cents', p_amount_cents,
      'reason', p_reason,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function write_off_invoice to authenticated;

comment on function write_off_invoice is 'Writes off an uncollectible invoice: Dr Bad Debt Expense / Cr AR';

-- ============================================================================
-- GET AR AGING REPORT
-- ============================================================================

create or replace function get_ar_aging(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  invoice_id uuid,
  invoice_number text,
  customer_name text,
  invoice_date date,
  due_date date,
  amount_due_cents bigint,
  days_overdue int
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with invoice_receipts_as_of as (
    -- Sum receipts (payments, credits, write-offs) up to and including the as-of date
    select
      invoice_id,
      coalesce(sum(amount_cents), 0) as received_as_of_cents
    from invoice_receipts
    where organization_id = p_organization_id
      and receipt_date <= p_as_of_date
    group by invoice_id
  )
  select
    i.id as invoice_id,
    i.number as invoice_number,
    c.name as customer_name,
    i.invoice_date,
    i.due_date,
    (i.total_cents - coalesce(ir.received_as_of_cents, 0)) as amount_due_cents,
    case
      when i.due_date < p_as_of_date then (p_as_of_date - i.due_date)::int
      else 0
    end as days_overdue
  from invoices i
  join contacts c on c.id = i.customer_id
  left join invoice_receipts_as_of ir on ir.invoice_id = i.id
  where i.organization_id = p_organization_id
    and i.status in ('Posted', 'Paid')
    and i.invoice_date <= p_as_of_date
    -- Only show invoices with remaining balance as of the date
    and (i.total_cents - coalesce(ir.received_as_of_cents, 0)) > 0
  order by i.due_date nulls last, i.invoice_date;
$$;

grant execute on function get_ar_aging to authenticated;

comment on function get_ar_aging is 'Returns AR aging report as of a specific date: unpaid posted invoices with remaining balance computed as of p_as_of_date by summing receipts with receipt_date <= p_as_of_date. Days overdue calculated relative to p_as_of_date (picker is "today" for aging, not wall clock). Quotes and Drafts excluded.';

-- ============================================================================
-- SEND INVOICE REMINDER
-- ============================================================================

create or replace function send_invoice_reminder(p_invoice_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_customer contacts;
  v_current_role membership_role;
begin
  -- Get current role
  v_current_role := "current_role"();
  
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  -- Get invoice with customer
  select i.*, c.name, c.email
  into v_invoice
  from invoices i
  join contacts c on c.id = i.customer_id
  where i.id = p_invoice_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  -- Check invoice status (allow Posted and Paid)
  if v_invoice.status = 'Quote' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot send reminder for a quote'
    );
  end if;

  if v_invoice.status = 'Draft' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot send reminder for a draft invoice'
    );
  end if;

  if v_invoice.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot send reminder for a void invoice'
    );
  end if;

  -- Allow Posted and Paid
  if v_invoice.status != 'Posted' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only send reminders for posted or paid invoices'
    );
  end if;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'invoice_reminder_sent',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'customer_email', v_invoice.email,
      'amount_due_cents', v_invoice.total_cents - v_invoice.received_cents
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id
  );
end;
$$;

grant execute on function send_invoice_reminder to authenticated;

comment on function send_invoice_reminder is 'Logs an invoice reminder event in audit trail (no email sent)';
