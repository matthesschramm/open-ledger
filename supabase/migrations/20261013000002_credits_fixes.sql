-- Credits Fixes
-- Fixes enum casting, date handling, and voided bill/invoice display issues

-- ============================================================================
-- ADD MISSING JOURNAL SOURCE VALUES
-- ============================================================================

-- Add 'invoice' source for invoice-related journals
alter type journal_source add value if not exists 'invoice';

-- Add 'receipt' source for invoice receipts (if not using 'cash')
-- alter type journal_source add value if not exists 'receipt';

-- ============================================================================
-- FIX APPLY_SUPPLIER_CREDIT (enum casting)
-- ============================================================================

create or replace function apply_supplier_credit(
  p_credit_id uuid,
  p_bill_id uuid,
  p_amount_cents bigint,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_credit supplier_credits;
  v_bill bills;
  v_current_user_id uuid;
  v_user_role membership_role;
  v_supplier_credit_account_id uuid;
  v_ap_account_id uuid;
  v_journal_id uuid;
  v_journal_number text;
  v_next_journal_number int;
  v_bill_open_balance bigint;
  v_apply_amount bigint;
  v_post_result jsonb;
begin
  -- Support API-key authentication via assume_request_user
  perform assume_request_user(p_user_id);

  -- Get current user
  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated',
      'error_code', 'NOT_AUTHENTICATED'
    );
  end if;

  -- Get credit with lock (prevents concurrent overdraw)
  select * into v_credit
  from supplier_credits
  where id = p_credit_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Supplier credit not found',
      'error_code', 'NOT_FOUND'
    );
  end if;

  -- Check user's role in the credit's organization (must be owner/admin/bookkeeper)
  select role into v_user_role
  from memberships
  where user_id = v_current_user_id
    and organization_id = v_credit.organization_id;

  if v_user_role is null or v_user_role not in ('owner', 'admin', 'bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Insufficient permissions',
      'error_code', 'INSUFFICIENT_PERMISSIONS'
    );
  end if;

  -- Get bill with lock (prevents concurrent applies to same bill)
  select * into v_bill
  from bills
  where id = p_bill_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill not found',
      'error_code', 'NOT_FOUND'
    );
  end if;

  -- Validate same supplier
  if v_credit.contact_id != v_bill.vendor_id then
    raise exception 'VALIDATION_ERROR: Credit and bill must be for the same supplier';
  end if;

  -- Validate same organization
  if v_credit.organization_id != v_bill.organization_id then
    raise exception 'VALIDATION_ERROR: Credit and bill must be in the same organization';
  end if;

  -- Validate bill is Open
  if v_bill.status != 'Open' then
    raise exception 'INVALID_STATUS: Can only apply credit to Open bills';
  end if;

  -- Calculate bill open balance
  v_bill_open_balance := v_bill.total_cents - v_bill.paid_cents;

  -- Validate amount (row locks held - prevents concurrent overdraw)
  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', (v_credit.remaining_cents::decimal / 100);
  end if;

  if p_amount_cents > v_bill_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% bill balance owed.', (v_bill_open_balance::decimal / 100);
  end if;

  v_apply_amount := p_amount_cents;

  -- Get account IDs
  v_supplier_credit_account_id := ensure_account(
    v_bill.organization_id,
    '1460',
    'Supplier credits',
    'Asset',
    'Other'
  );

  select id into v_ap_account_id
  from accounts
  where organization_id = v_bill.organization_id
    and code = '2000';

  if v_ap_account_id is null then
    raise exception 'AP account (2000) not found';
  end if;

  -- Generate journal number
  select coalesce(max(cast(substring(number from '[0-9]+') as int)), 0) + 1
  into v_next_journal_number
  from journals
  where organization_id = v_bill.organization_id
    and number ~ '^J[0-9]+$';

  v_journal_number := 'J' || lpad(v_next_journal_number::text, 4, '0');

  -- Create journal: Dr 2000 AP / Cr 1460 Supplier credits (Draft first)
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_bill.organization_id,
    v_journal_number,
    current_date,
    format('Applied supplier credit $%s to bill %s', (v_apply_amount::decimal / 100), v_bill.number),
    'Draft',
    'bill_payment',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr 2000 AP
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_bill.organization_id,
    v_journal_id,
    v_ap_account_id,
    v_apply_amount,
    0,
    'Applied credit to bill ' || v_bill.number
  );

  -- Cr 1460 Supplier credits
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_bill.organization_id,
    v_journal_id,
    v_supplier_credit_account_id,
    0,
    v_apply_amount,
    'Applied to bill ' || v_bill.number
  );

  -- Post the journal via post_journal RPC (respects period locks)
  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    -- Check if it's a period lock error
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception 'Failed to post application journal: %', v_post_result->>'error';
  end if;

  -- Update supplier credit
  update supplier_credits
  set
    remaining_cents = remaining_cents - v_apply_amount,
    status = case
      when remaining_cents - v_apply_amount = 0 then 'applied'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  -- Update bill with proper enum casting
  update bills
  set
    paid_cents = paid_cents + v_apply_amount,
    status = case
      when paid_cents + v_apply_amount >= total_cents then 'Paid'::bill_status
      else 'Open'::bill_status
    end,
    updated_at = now()
  where id = p_bill_id;

  -- Log audit event
  perform log_audit_event(
    'bill',
    p_bill_id,
    'supplier_credit_applied',
    jsonb_build_object(
      'bill_number', v_bill.number,
      'credit_id', p_credit_id,
      'amount_cents', v_apply_amount
    )
  );

  return jsonb_build_object(
    'success', true,
    'credit_id', p_credit_id,
    'bill_id', p_bill_id,
    'applied_amount_cents', v_apply_amount,
    'credit_remaining_cents', v_credit.remaining_cents - v_apply_amount,
    'bill_status', case
      when v_bill.paid_cents + v_apply_amount >= v_bill.total_cents then 'Paid'
      else 'Open'
    end
  );
end;
$$;

-- ============================================================================
-- FIX APPLY_CUSTOMER_CREDIT (enum casting)
-- ============================================================================

create or replace function apply_customer_credit(
  p_credit_id uuid,
  p_invoice_id uuid,
  p_amount_cents bigint,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_credit customer_credits;
  v_invoice invoices;
  v_current_user_id uuid;
  v_user_role membership_role;
  v_customer_credit_account_id uuid;
  v_ar_account_id uuid;
  v_journal_id uuid;
  v_journal_number text;
  v_next_journal_number int;
  v_invoice_open_balance bigint;
  v_apply_amount bigint;
  v_post_result jsonb;
begin
  -- Support API-key authentication via assume_request_user
  perform assume_request_user(p_user_id);

  -- Get current user
  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated',
      'error_code', 'NOT_AUTHENTICATED'
    );
  end if;

  -- Get credit with lock (prevents concurrent overdraw)
  select * into v_credit
  from customer_credits
  where id = p_credit_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Customer credit not found',
      'error_code', 'NOT_FOUND'
    );
  end if;

  -- Check user's role in the credit's organization (must be owner/admin/bookkeeper)
  select role into v_user_role
  from memberships
  where user_id = v_current_user_id
    and organization_id = v_credit.organization_id;

  if v_user_role is null or v_user_role not in ('owner', 'admin', 'bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Insufficient permissions',
      'error_code', 'INSUFFICIENT_PERMISSIONS'
    );
  end if;

  -- Get invoice with lock (prevents concurrent applies to same invoice)
  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found',
      'error_code', 'NOT_FOUND'
    );
  end if;

  -- Validate same customer
  if v_credit.contact_id != v_invoice.customer_id then
    raise exception 'VALIDATION_ERROR: Credit and invoice must be for the same customer';
  end if;

  -- Validate same organization
  if v_credit.organization_id != v_invoice.organization_id then
    raise exception 'VALIDATION_ERROR: Credit and invoice must be in the same organization';
  end if;

  -- Validate invoice is Posted
  if v_invoice.status != 'Posted' then
    raise exception 'INVALID_STATUS: Can only apply credit to Posted invoices';
  end if;

  -- Calculate invoice open balance
  v_invoice_open_balance := v_invoice.total_cents - v_invoice.received_cents;

  -- Validate amount (row locks held - prevents concurrent overdraw)
  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', (v_credit.remaining_cents::decimal / 100);
  end if;

  if p_amount_cents > v_invoice_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% invoice balance owed.', (v_invoice_open_balance::decimal / 100);
  end if;

  v_apply_amount := p_amount_cents;

  -- Get account IDs
  v_customer_credit_account_id := ensure_account(
    v_invoice.organization_id,
    '2310',
    'Customer credits',
    'Liability',
    'Other'
  );

  select id into v_ar_account_id
  from accounts
  where organization_id = v_invoice.organization_id
    and code = '1100';

  if v_ar_account_id is null then
    raise exception 'AR account (1100) not found';
  end if;

  -- Generate journal number
  select coalesce(max(cast(substring(number from '[0-9]+') as int)), 0) + 1
  into v_next_journal_number
  from journals
  where organization_id = v_invoice.organization_id
    and number ~ '^J[0-9]+$';

  v_journal_number := 'J' || lpad(v_next_journal_number::text, 4, '0');

  -- Create journal: Dr 2310 Customer credits / Cr 1100 AR (Draft first)
  -- Use 'cash' source (same as receipts) since 'invoice' may not exist yet
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_invoice.organization_id,
    v_journal_number,
    current_date,
    format('Applied customer credit $%s to invoice %s', (v_apply_amount::decimal / 100), v_invoice.number),
    'Draft',
    'cash',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr 2310 Customer credits
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_invoice.organization_id,
    v_journal_id,
    v_customer_credit_account_id,
    v_apply_amount,
    0,
    'Applied credit to invoice ' || v_invoice.number
  );

  -- Cr 1100 AR
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_invoice.organization_id,
    v_journal_id,
    v_ar_account_id,
    0,
    v_apply_amount,
    'Applied credit to invoice ' || v_invoice.number
  );

  -- Post the journal via post_journal RPC (respects period locks)
  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    -- Check if it's a period lock error
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception 'Failed to post application journal: %', v_post_result->>'error';
  end if;

  -- Update customer credit
  update customer_credits
  set
    remaining_cents = remaining_cents - v_apply_amount,
    status = case
      when remaining_cents - v_apply_amount = 0 then 'applied'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  -- Update invoice with proper enum casting
  update invoices
  set
    received_cents = received_cents + v_apply_amount,
    status = case
      when received_cents + v_apply_amount >= total_cents then 'Paid'::invoice_status
      else 'Posted'::invoice_status
    end,
    updated_at = now()
  where id = p_invoice_id;

  -- Create invoice_receipt record so AR aging reflects the credit application
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
    v_invoice.organization_id,
    p_invoice_id,
    v_journal_id,
    current_date,
    v_apply_amount,
    'credit_note',
    format('Customer credit applied: $%s', (v_apply_amount::decimal / 100)),
    v_current_user_id
  );

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'customer_credit_applied',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'credit_id', p_credit_id,
      'amount_cents', v_apply_amount
    )
  );

  return jsonb_build_object(
    'success', true,
    'credit_id', p_credit_id,
    'invoice_id', p_invoice_id,
    'applied_amount_cents', v_apply_amount,
    'credit_remaining_cents', v_credit.remaining_cents - v_apply_amount,
    'invoice_status', case
      when v_invoice.received_cents + v_apply_amount >= v_invoice.total_cents then 'Paid'
      else 'Posted'
    end
  );
end;
$$;

-- ============================================================================
-- FIX VOID_INVOICE (journal source and PERIOD_LOCKED tagging)
-- ============================================================================

create or replace function void_invoice(
  p_invoice_id uuid,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice invoices;
  v_reversal_result jsonb;
  v_current_user_id uuid;
  v_user_role membership_role;
  v_customer_credit_account_id uuid;
  v_ar_account_id uuid;
  v_credit_journal_id uuid;
  v_credit_id uuid;
  v_journal_number text;
  v_next_journal_number int;
begin
  -- Support API-key authentication via assume_request_user
  perform assume_request_user(p_user_id);

  -- Get current user
  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated',
      'error_code', 'NOT_AUTHENTICATED'
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
      'error', 'Invoice not found',
      'error_code', 'NOT_FOUND'
    );
  end if;

  -- Check user's role in the invoice's organization (must be owner/admin/bookkeeper)
  select role into v_user_role
  from memberships
  where user_id = v_current_user_id
    and organization_id = v_invoice.organization_id;

  if v_user_role is null or v_user_role not in ('owner', 'admin', 'bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Insufficient permissions',
      'error_code', 'INSUFFICIENT_PERMISSIONS'
    );
  end if;

  -- Check if already void
  if v_invoice.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice already void',
      'error_code', 'ALREADY_VOID'
    );
  end if;

  -- Cannot void quotes
  if v_invoice.status = 'Quote' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot void a quote',
      'error_code', 'INVALID_STATUS'
    );
  end if;

  -- Must be Posted or Paid to void
  if v_invoice.status not in ('Posted', 'Paid') then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only void Posted or Paid invoices',
      'error_code', 'INVALID_STATUS'
    );
  end if;

  -- Check if invoice has recognition journal
  if v_invoice.recognition_journal_id is null then
    -- Just mark as void if no journal yet
    update invoices
    set status = 'Void'::invoice_status
    where id = p_invoice_id;

    return jsonb_build_object(
      'success', true,
      'invoice_id', p_invoice_id
    );
  end if;

  -- Reverse the recognition journal (Dr revenue / Cr 1100 AR)
  v_reversal_result := reverse_journal(
    v_invoice.recognition_journal_id,
    current_date,
    'Void invoice: ' || v_invoice.number,
    v_current_user_id
  );

  if not (v_reversal_result->>'success')::boolean then
    -- Check if it's a period lock error and tag as PERIOD_LOCKED
    if (v_reversal_result->>'error')::text ~ '(Locked|Soft-closed)' then
      return jsonb_build_object(
        'success', false,
        'error', v_reversal_result->>'error',
        'error_code', 'PERIOD_LOCKED',
        'period_name', v_reversal_result->>'period_name',
        'period_status', v_reversal_result->>'period_status'
      );
    end if;
    -- Reversal failed - return error without changing invoice status
    return v_reversal_result;
  end if;

  -- If invoice was paid (full or partial), create customer credit
  -- Receipt journals (Dr cash / Cr 1100) stay Posted; never auto-reverse
  -- Credit: Dr 1100 AR / Cr 2310 Customer credits for received_cents
  if v_invoice.received_cents > 0 then
    -- Ensure 2310 Customer credits account exists
    v_customer_credit_account_id := ensure_account(
      v_invoice.organization_id,
      '2310',
      'Customer credits',
      'Liability',
      'Other'
    );

    -- Get 1100 AR account
    select id into v_ar_account_id
    from accounts
    where organization_id = v_invoice.organization_id
      and code = '1100';

    if v_ar_account_id is null then
      raise exception 'AR account (1100) not found';
    end if;

    -- Generate journal number
    select coalesce(max(cast(substring(number from '[0-9]+') as int)), 0) + 1
    into v_next_journal_number
    from journals
    where organization_id = v_invoice.organization_id
      and number ~ '^J[0-9]+$';

    v_journal_number := 'J' || lpad(v_next_journal_number::text, 4, '0');

    -- Create credit journal: Dr 1100 / Cr 2310 (Draft first)
    -- Use 'cash' source (same as receipts) since 'invoice' may not exist
    insert into journals (
      organization_id,
      number,
      entry_date,
      description,
      status,
      source,
      created_by
    ) values (
      v_invoice.organization_id,
      v_journal_number,
      current_date,
      'Customer credit from voided invoice: ' || v_invoice.number,
      'Draft',
      'cash',
      v_current_user_id
    )
    returning id into v_credit_journal_id;

    -- Dr 1100 AR
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_invoice.organization_id,
      v_credit_journal_id,
      v_ar_account_id,
      v_invoice.received_cents,
      0,
      'Credit from invoice ' || v_invoice.number
    );

    -- Cr 2310 Customer credits
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_invoice.organization_id,
      v_credit_journal_id,
      v_customer_credit_account_id,
      0,
      v_invoice.received_cents,
      'Credit from invoice ' || v_invoice.number
    );

    -- Post the journal via post_journal RPC (respects period locks)
    declare
      v_post_result jsonb;
    begin
      v_post_result := post_journal(v_credit_journal_id, v_current_user_id);
      
      if not (v_post_result->>'success')::boolean then
        -- Check if it's a period lock error
        if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' then
          raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
        end if;
        raise exception 'Failed to post credit journal: %', v_post_result->>'error';
      end if;
    end;

    -- Create customer credit record
    insert into customer_credits (
      organization_id,
      contact_id,
      source_invoice_id,
      amount_cents,
      remaining_cents,
      status,
      journal_id
    ) values (
      v_invoice.organization_id,
      v_invoice.customer_id,
      p_invoice_id,
      v_invoice.received_cents,
      v_invoice.received_cents,
      'open',
      v_credit_journal_id
    )
    returning id into v_credit_id;

    -- Log audit event
    perform log_audit_event(
      'invoice',
      p_invoice_id,
      'invoice_voided_with_credit',
      jsonb_build_object(
        'invoice_number', v_invoice.number,
        'credit_amount_cents', v_invoice.received_cents,
        'credit_id', v_credit_id
      )
    );
  else
    -- Log audit event (no credit)
    perform log_audit_event(
      'invoice',
      p_invoice_id,
      'invoice_voided',
      jsonb_build_object(
        'invoice_number', v_invoice.number
      )
    );
  end if;

  -- Mark invoice as void
  update invoices
  set status = 'Void'::invoice_status
  where id = p_invoice_id;

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'reversal_result', v_reversal_result,
    'credit_id', v_credit_id,
    'credit_amount_cents', v_invoice.received_cents
  );
end;
$$;

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';
