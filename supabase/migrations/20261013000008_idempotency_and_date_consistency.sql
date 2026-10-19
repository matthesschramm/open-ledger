-- ============================================================================
-- MIGRATION 000008: IDEMPOTENCY AND DATE CONSISTENCY
-- ============================================================================
-- A. Add idempotency support to apply_supplier_credit and apply_customer_credit
-- B. Ensure stored document dates match journal entry_date (company-local)

-- ============================================================================
-- IDEMPOTENCY: ADD COLUMNS
-- ============================================================================

alter table bill_payments add column if not exists idempotency_key uuid;
create unique index if not exists bill_payments_idempotency_key_idx on bill_payments(organization_id, idempotency_key) where idempotency_key is not null;

alter table invoice_receipts add column if not exists idempotency_key uuid;
create unique index if not exists invoice_receipts_idempotency_key_idx on invoice_receipts(organization_id, idempotency_key) where idempotency_key is not null;

comment on column bill_payments.idempotency_key is 'Optional UUID for idempotent apply_supplier_credit calls; prevents duplicate applications';
comment on column invoice_receipts.idempotency_key is 'Optional UUID for idempotent apply_customer_credit calls; prevents duplicate applications';

-- ============================================================================
-- IDEMPOTENCY: APPLY_SUPPLIER_CREDIT
-- ============================================================================

-- Drop old 4-arg overload to avoid ambiguous calls
drop function if exists apply_supplier_credit(uuid, uuid, bigint, uuid);

create or replace function apply_supplier_credit(
  p_credit_id uuid,
  p_bill_id uuid,
  p_amount_cents bigint,
  p_user_id uuid default null,
  p_idempotency_key uuid default null
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
  v_org_timezone text;
  v_apply_date date;
  v_existing_payment bill_payments;
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

  -- IDEMPOTENCY: Check if this key was already processed (after auth & lock)
  if p_idempotency_key is not null then
    begin
      select * into v_existing_payment
      from bill_payments
      where organization_id = v_credit.organization_id
        and idempotency_key = p_idempotency_key;

      if found then
        -- Return the original result
        select * into v_bill from bills where id = v_existing_payment.bill_id;
        select * into v_credit from supplier_credits where id = p_credit_id;
        
        return jsonb_build_object(
          'success', true,
          'credit_id', p_credit_id,
          'bill_id', v_existing_payment.bill_id,
          'applied_amount_cents', v_existing_payment.amount_cents,
          'credit_remaining_cents', v_credit.remaining_cents,
          'bill_status', v_bill.status,
          'idempotent', true
        );
      end if;
    exception
      when unique_violation then
        -- Concurrent call with same key; re-select to return original result
        select * into v_existing_payment
        from bill_payments
        where organization_id = v_credit.organization_id
          and idempotency_key = p_idempotency_key;

        if found then
          select * into v_bill from bills where id = v_existing_payment.bill_id;
          select * into v_credit from supplier_credits where id = p_credit_id;
          
          return jsonb_build_object(
            'success', true,
            'credit_id', p_credit_id,
            'bill_id', v_existing_payment.bill_id,
            'applied_amount_cents', v_existing_payment.amount_cents,
            'credit_remaining_cents', v_credit.remaining_cents,
            'bill_status', v_bill.status,
            'idempotent', true
          );
        end if;
        raise;
    end;
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
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', to_char(v_credit.remaining_cents/100.0,'FM999,999,990.00');
  end if;

  if p_amount_cents > v_bill_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% bill balance owed.', to_char(v_bill_open_balance/100.0,'FM999,999,990.00');
  end if;

  v_apply_amount := p_amount_cents;

  -- DATE CONSISTENCY: Get organization timezone and compute company-local date
  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_bill.organization_id;
  
  v_apply_date := (now() at time zone v_org_timezone)::date;

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
  -- DATE CONSISTENCY: Use v_apply_date for entry_date
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
    v_apply_date,
    'Applied supplier credit $' || to_char(v_apply_amount/100.0,'FM999,999,990.00') || ' to bill ' || v_bill.number,
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

  -- DATE CONSISTENCY: Use v_apply_date for payment_date (matches journal entry_date)
  -- IDEMPOTENCY: Store idempotency_key if provided
  insert into bill_payments (
    organization_id,
    bill_id,
    payment_journal_id,
    payment_date,
    amount_cents,
    source,
    created_by,
    idempotency_key
  ) values (
    v_bill.organization_id,
    p_bill_id,
    v_journal_id,
    v_apply_date,
    v_apply_amount,
    'supplier_credit',
    v_current_user_id,
    p_idempotency_key
  );

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
-- IDEMPOTENCY: APPLY_CUSTOMER_CREDIT
-- ============================================================================

-- Drop old 4-arg overload to avoid ambiguous calls
drop function if exists apply_customer_credit(uuid, uuid, bigint, uuid);

create or replace function apply_customer_credit(
  p_credit_id uuid,
  p_invoice_id uuid,
  p_amount_cents bigint,
  p_user_id uuid default null,
  p_idempotency_key uuid default null
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
  v_org_timezone text;
  v_apply_date date;
  v_existing_receipt invoice_receipts;
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

  -- IDEMPOTENCY: Check if this key was already processed (after auth & lock)
  if p_idempotency_key is not null then
    begin
      select * into v_existing_receipt
      from invoice_receipts
      where organization_id = v_credit.organization_id
        and idempotency_key = p_idempotency_key;

      if found then
        -- Return the original result
        select * into v_invoice from invoices where id = v_existing_receipt.invoice_id;
        select * into v_credit from customer_credits where id = p_credit_id;
        
        return jsonb_build_object(
          'success', true,
          'credit_id', p_credit_id,
          'invoice_id', v_existing_receipt.invoice_id,
          'applied_amount_cents', v_existing_receipt.amount_cents,
          'credit_remaining_cents', v_credit.remaining_cents,
          'invoice_status', v_invoice.status,
          'idempotent', true
        );
      end if;
    exception
      when unique_violation then
        -- Concurrent call with same key; re-select to return original result
        select * into v_existing_receipt
        from invoice_receipts
        where organization_id = v_credit.organization_id
          and idempotency_key = p_idempotency_key;

        if found then
          select * into v_invoice from invoices where id = v_existing_receipt.invoice_id;
          select * into v_credit from customer_credits where id = p_credit_id;
          
          return jsonb_build_object(
            'success', true,
            'credit_id', p_credit_id,
            'invoice_id', v_existing_receipt.invoice_id,
            'applied_amount_cents', v_existing_receipt.amount_cents,
            'credit_remaining_cents', v_credit.remaining_cents,
            'invoice_status', v_invoice.status,
            'idempotent', true
          );
        end if;
        raise;
    end;
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

  -- Validate invoice is Posted or Paid
  if v_invoice.status not in ('Posted', 'Paid') then
    raise exception 'INVALID_STATUS: Can only apply credit to Posted or Paid invoices';
  end if;

  -- Calculate invoice open balance
  v_invoice_open_balance := v_invoice.total_cents - v_invoice.received_cents;

  -- Validate amount (row locks held - prevents concurrent overdraw)
  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', to_char(v_credit.remaining_cents/100.0,'FM999,999,990.00');
  end if;

  if p_amount_cents > v_invoice_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% invoice balance owed.', to_char(v_invoice_open_balance/100.0,'FM999,999,990.00');
  end if;

  v_apply_amount := p_amount_cents;

  -- DATE CONSISTENCY: Get organization timezone and compute company-local date
  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_invoice.organization_id;
  
  v_apply_date := (now() at time zone v_org_timezone)::date;

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
  -- DATE CONSISTENCY: Use v_apply_date for entry_date
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
    v_apply_date,
    'Applied customer credit $' || to_char(v_apply_amount/100.0,'FM999,999,990.00') || ' to invoice ' || v_invoice.number,
    'Draft',
    'invoice',
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
    'Applied to invoice ' || v_invoice.number
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

  -- DATE CONSISTENCY: Use v_apply_date for receipt_date (matches journal entry_date)
  -- IDEMPOTENCY: Store idempotency_key if provided
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    created_by,
    idempotency_key
  ) values (
    v_invoice.organization_id,
    p_invoice_id,
    v_journal_id,
    v_apply_date,
    v_apply_amount,
    'credit_note',
    v_current_user_id,
    p_idempotency_key
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
