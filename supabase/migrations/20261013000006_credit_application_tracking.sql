-- ============================================================================
-- MIGRATION 000006: CREDIT APPLICATION TRACKING
-- ============================================================================
-- Fixes:
-- 1. apply_supplier_credit now creates bill_payments record so credit apps show in UI
-- 2. apply_customer_credit now creates invoice_receipts record for same reason
-- 3. Both functions are FULLY ATOMIC - all operations in ONE plpgsql transaction:
--    - Journal creation and posting (via post_journal, respects period locks)
--    - Bill/Invoice allocation (paid_cents, status updates)
--    - Applied-credit row insertion (bill_payments/invoice_receipts)
--    - Credit balance decrement (remaining_cents, status)
--    - Row locks (FOR UPDATE) prevent over-apply races
--    - Company-local date used for period lock check
--    - Any failure raises exception -> full rollback, no partial writes
-- 4. GL verification checks at end confirm 1460/2310 balances match credit sums

-- ============================================================================
-- FIX APPLY_SUPPLIER_CREDIT (add bill_payments record)
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
  v_org_timezone text;
  v_apply_date date;
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

  -- Get organization timezone (with coalesce for safety) and compute company-local date
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

  -- INSERT bill_payments record so credit application shows in UI
  insert into bill_payments (
    organization_id,
    bill_id,
    payment_journal_id,
    payment_date,
    amount_cents,
    created_by
  ) values (
    v_bill.organization_id,
    p_bill_id,
    v_journal_id,
    v_apply_date,
    v_apply_amount,
    v_current_user_id
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
-- FIX APPLY_CUSTOMER_CREDIT (add invoice_receipts record)
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
  v_org_timezone text;
  v_apply_date date;
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
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', (v_credit.remaining_cents::decimal / 100);
  end if;

  if p_amount_cents > v_invoice_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% invoice balance owed.', (v_invoice_open_balance::decimal / 100);
  end if;

  v_apply_amount := p_amount_cents;

  -- Get organization timezone (with coalesce for safety) and compute company-local date
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
    format('Applied customer credit $%s to invoice %s', (v_apply_amount::decimal / 100), v_invoice.number),
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

  -- INSERT invoice_receipts record so credit application shows in UI
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    created_by
  ) values (
    v_invoice.organization_id,
    p_invoice_id,
    v_journal_id,
    v_apply_date,
    v_apply_amount,
    'credit_note',
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
-- GL VERIFICATION: Supplier Credits (1460) must equal sum of supplier_credits.remaining_cents
-- ============================================================================

do $$
declare
  v_gl_1460_balance bigint;
  v_supplier_credits_total bigint;
  v_org_id uuid;
  v_org_name text;
  v_diff bigint;
begin
  -- Check each organization
  for v_org_id, v_org_name in 
    select id, name from organizations
  loop
    -- Get GL balance for 1460 Supplier credits
    select coalesce(sum(debit_cents) - sum(credit_cents), 0)
    into v_gl_1460_balance
    from journal_lines jl
    join accounts a on a.id = jl.account_id
    join journals j on j.id = jl.journal_id
    where a.organization_id = v_org_id
      and a.code = '1460'
      and j.status = 'Posted';

    -- Get sum of supplier_credits remaining_cents
    select coalesce(sum(remaining_cents), 0)
    into v_supplier_credits_total
    from supplier_credits
    where organization_id = v_org_id
      and status in ('open', 'applied');

    v_diff := v_gl_1460_balance - v_supplier_credits_total;

    if v_diff != 0 then
      raise warning 'Organization % (%) GL 1460 mismatch: GL balance = %, supplier_credits sum = %, diff = %',
        v_org_name, v_org_id, v_gl_1460_balance, v_supplier_credits_total, v_diff;
    else
      raise notice 'Organization % (%): GL 1460 balance matches supplier_credits (% cents)',
        v_org_name, v_org_id, v_gl_1460_balance;
    end if;
  end loop;
end;
$$;

-- ============================================================================
-- GL VERIFICATION: Customer Credits (2310) must equal sum of customer_credits.remaining_cents
-- ============================================================================

do $$
declare
  v_gl_2310_balance bigint;
  v_customer_credits_total bigint;
  v_org_id uuid;
  v_org_name text;
  v_diff bigint;
begin
  -- Check each organization
  for v_org_id, v_org_name in 
    select id, name from organizations
  loop
    -- Get GL balance for 2310 Customer credits (credit balance, so credit - debit)
    select coalesce(sum(credit_cents) - sum(debit_cents), 0)
    into v_gl_2310_balance
    from journal_lines jl
    join accounts a on a.id = jl.account_id
    join journals j on j.id = jl.journal_id
    where a.organization_id = v_org_id
      and a.code = '2310'
      and j.status = 'Posted';

    -- Get sum of customer_credits remaining_cents
    select coalesce(sum(remaining_cents), 0)
    into v_customer_credits_total
    from customer_credits
    where organization_id = v_org_id
      and status in ('open', 'applied');

    v_diff := v_gl_2310_balance - v_customer_credits_total;

    if v_diff != 0 then
      raise warning 'Organization % (%) GL 2310 mismatch: GL balance = %, customer_credits sum = %, diff = %',
        v_org_name, v_org_id, v_gl_2310_balance, v_customer_credits_total, v_diff;
    else
      raise notice 'Organization % (%): GL 2310 balance matches customer_credits (% cents)',
        v_org_name, v_org_id, v_gl_2310_balance;
    end if;
  end loop;
end;
$$;
