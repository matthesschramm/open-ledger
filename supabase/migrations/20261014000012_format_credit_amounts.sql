-- ============================================================================
-- MIGRATION 000012: FORMAT CREDIT AMOUNTS
-- ============================================================================
-- Fix refund and credit application amount formatting in descriptions and error messages.
-- Use to_char(amount, 'FM999,999,999,990.00') to format as "$20.00" instead of "$20.0000000000000000"

-- ============================================================================
-- REFUND SUPPLIER CREDIT
-- ============================================================================

create or replace function refund_supplier_credit(
  p_credit_id uuid,
  p_amount_cents bigint,
  p_cash_account_id uuid default null,
  p_refund_date date default null,
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
  v_current_user_id uuid;
  v_user_role membership_role;
  v_supplier_credit_account_id uuid;
  v_cash_account_id uuid;
  v_cash_account accounts;
  v_journal_id uuid;
  v_journal_number text;
  v_next_journal_number int;
  v_refund_date date;
  v_refund_amount bigint;
  v_post_result jsonb;
  v_org_timezone text;
  v_existing_refund credit_refunds;
  v_credit_created_date date;
  v_can_post boolean;
  v_lock_date_formatted text;
begin
  perform assume_request_user(p_user_id);

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated',
      'error_code', 'NOT_AUTHENTICATED'
    );
  end if;

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

  if p_idempotency_key is not null then
    select * into v_existing_refund
    from credit_refunds
    where organization_id = v_credit.organization_id
      and idempotency_key = p_idempotency_key;

    if found then
      return jsonb_build_object(
        'success', true,
        'credit_id', p_credit_id,
        'refund_amount_cents', v_existing_refund.amount_cents,
        'credit_remaining_cents', v_credit.remaining_cents,
        'journal_id', v_existing_refund.journal_id,
        'refund_date', v_existing_refund.refund_date,
        'idempotent', true
      );
    end if;
  end if;

  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    if v_credit.remaining_cents = 0 then
      raise exception 'INSUFFICIENT_BALANCE: No credit left to refund.';
    end if;
    raise exception '%', 'INSUFFICIENT_BALANCE: You can refund up to $' || to_char(v_credit.remaining_cents/100.0,'FM999,999,999,990.00') || '.';
  end if;

  v_refund_amount := p_amount_cents;
  
  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_credit.organization_id;

  v_credit_created_date := (v_credit.created_at at time zone v_org_timezone)::date;
  
  v_refund_date := greatest(
    coalesce(p_refund_date, (now() at time zone v_org_timezone)::date),
    v_credit_created_date
  );

  -- ATOMIC CHECK: Period lock BEFORE any account lookup or number allocation
  v_can_post := can_post_to_period(
    v_credit.organization_id,
    v_refund_date,
    v_user_role
  );

  if not v_can_post then
    v_lock_date_formatted := format_period_lock_date(v_credit.organization_id, v_refund_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.',
      'error_code', 'PERIOD_LOCKED'
    );
  end if;

  if p_cash_account_id is not null then
    select * into v_cash_account
    from accounts
    where id = p_cash_account_id
      and organization_id = v_credit.organization_id;
    
    if not found then
      return jsonb_build_object(
        'success', false,
        'error', 'Cash account not found or does not belong to organization',
        'error_code', 'NOT_FOUND'
      );
    end if;

    if not v_cash_account.is_cash or v_cash_account.type != 'Asset' then
      return jsonb_build_object(
        'success', false,
        'error', 'Account must be a cash asset account',
        'error_code', 'VALIDATION_ERROR'
      );
    end if;
    
    v_cash_account_id := p_cash_account_id;
  else
    select id into v_cash_account_id
    from accounts
    where organization_id = v_credit.organization_id
      and code = '1010';
      
    if v_cash_account_id is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Default cash account (1010) not found',
        'error_code', 'NOT_FOUND'
      );
    end if;
  end if;

  v_supplier_credit_account_id := ensure_account(
    v_credit.organization_id,
    '1460',
    'Supplier credits',
    'Asset',
    'Other'
  );

  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_credit.organization_id,
    null,
    v_refund_date,
    format('Refund supplier credit $%s', to_char(v_refund_amount/100.0,'FM999,999,999,990.00')),
    'Draft',
    'bill_payment',
    v_current_user_id
  )
  returning id into v_journal_id;

  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_credit.organization_id,
    v_journal_id,
    v_cash_account_id,
    v_refund_amount,
    0,
    'Refund supplier credit'
  );

  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_credit.organization_id,
    v_journal_id,
    v_supplier_credit_account_id,
    0,
    v_refund_amount,
    'Refund supplier credit'
  );

  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_post_result->>'error')::text ~ 'locked period' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception '%', v_post_result->>'error';
  end if;

  update supplier_credits
  set
    remaining_cents = remaining_cents - v_refund_amount,
    status = case
      when remaining_cents - v_refund_amount = 0 then 'refunded'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  if p_idempotency_key is not null then
    insert into credit_refunds (
      organization_id,
      credit_type,
      credit_id,
      journal_id,
      amount_cents,
      refund_date,
      idempotency_key
    ) values (
      v_credit.organization_id,
      'supplier',
      p_credit_id,
      v_journal_id,
      v_refund_amount,
      v_refund_date,
      p_idempotency_key
    );
  end if;

  perform log_audit_event(
    'supplier_credit',
    p_credit_id,
    'supplier_credit_refunded',
    jsonb_build_object(
      'credit_id', p_credit_id,
      'amount_cents', v_refund_amount,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'credit_id', p_credit_id,
    'refund_amount_cents', v_refund_amount,
    'credit_remaining_cents', v_credit.remaining_cents - v_refund_amount,
    'journal_id', v_journal_id
  );
end;
$$;

-- ============================================================================
-- REFUND CUSTOMER CREDIT
-- ============================================================================

create or replace function refund_customer_credit(
  p_credit_id uuid,
  p_amount_cents bigint,
  p_cash_account_id uuid default null,
  p_refund_date date default null,
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
  v_current_user_id uuid;
  v_user_role membership_role;
  v_customer_credit_account_id uuid;
  v_cash_account_id uuid;
  v_cash_account accounts;
  v_journal_id uuid;
  v_journal_number text;
  v_next_journal_number int;
  v_refund_date date;
  v_refund_amount bigint;
  v_post_result jsonb;
  v_org_timezone text;
  v_existing_refund credit_refunds;
  v_credit_created_date date;
  v_can_post boolean;
  v_lock_date_formatted text;
begin
  perform assume_request_user(p_user_id);

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated',
      'error_code', 'NOT_AUTHENTICATED'
    );
  end if;

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

  if p_idempotency_key is not null then
    select * into v_existing_refund
    from credit_refunds
    where organization_id = v_credit.organization_id
      and idempotency_key = p_idempotency_key;

    if found then
      return jsonb_build_object(
        'success', true,
        'credit_id', p_credit_id,
        'refund_amount_cents', v_existing_refund.amount_cents,
        'credit_remaining_cents', v_credit.remaining_cents,
        'journal_id', v_existing_refund.journal_id,
        'refund_date', v_existing_refund.refund_date,
        'idempotent', true
      );
    end if;
  end if;

  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    if v_credit.remaining_cents = 0 then
      raise exception 'INSUFFICIENT_BALANCE: No credit left to refund.';
    end if;
    raise exception '%', 'INSUFFICIENT_BALANCE: You can refund up to $' || to_char(v_credit.remaining_cents/100.0,'FM999,999,999,990.00') || '.';
  end if;

  v_refund_amount := p_amount_cents;
  
  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_credit.organization_id;

  v_credit_created_date := (v_credit.created_at at time zone v_org_timezone)::date;
  
  v_refund_date := greatest(
    coalesce(p_refund_date, (now() at time zone v_org_timezone)::date),
    v_credit_created_date
  );

  -- ATOMIC CHECK: Period lock BEFORE any account lookup or number allocation
  v_can_post := can_post_to_period(
    v_credit.organization_id,
    v_refund_date,
    v_user_role
  );

  if not v_can_post then
    v_lock_date_formatted := format_period_lock_date(v_credit.organization_id, v_refund_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.',
      'error_code', 'PERIOD_LOCKED'
    );
  end if;

  if p_cash_account_id is not null then
    select * into v_cash_account
    from accounts
    where id = p_cash_account_id
      and organization_id = v_credit.organization_id;
    
    if not found then
      return jsonb_build_object(
        'success', false,
        'error', 'Cash account not found or does not belong to organization',
        'error_code', 'NOT_FOUND'
      );
    end if;

    if not v_cash_account.is_cash or v_cash_account.type != 'Asset' then
      return jsonb_build_object(
        'success', false,
        'error', 'Account must be a cash asset account',
        'error_code', 'VALIDATION_ERROR'
      );
    end if;
    
    v_cash_account_id := p_cash_account_id;
  else
    select id into v_cash_account_id
    from accounts
    where organization_id = v_credit.organization_id
      and code = '1010';
      
    if v_cash_account_id is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Default cash account (1010) not found',
        'error_code', 'NOT_FOUND'
      );
    end if;
  end if;

  v_customer_credit_account_id := ensure_account(
    v_credit.organization_id,
    '2310',
    'Customer credits',
    'Liability',
    'Other'
  );

  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_credit.organization_id,
    null,
    v_refund_date,
    format('Refund customer credit $%s', to_char(v_refund_amount/100.0,'FM999,999,999,990.00')),
    'Draft',
    'invoice',
    v_current_user_id
  )
  returning id into v_journal_id;

  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_credit.organization_id,
    v_journal_id,
    v_customer_credit_account_id,
    v_refund_amount,
    0,
    'Refund customer credit'
  );

  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_credit.organization_id,
    v_journal_id,
    v_cash_account_id,
    0,
    v_refund_amount,
    'Refund customer credit'
  );

  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_post_result->>'error')::text ~ 'locked period' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception '%', v_post_result->>'error';
  end if;

  update customer_credits
  set
    remaining_cents = remaining_cents - v_refund_amount,
    status = case
      when remaining_cents - v_refund_amount = 0 then 'refunded'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  if p_idempotency_key is not null then
    insert into credit_refunds (
      organization_id,
      credit_type,
      credit_id,
      journal_id,
      amount_cents,
      refund_date,
      idempotency_key
    ) values (
      v_credit.organization_id,
      'customer',
      p_credit_id,
      v_journal_id,
      v_refund_amount,
      v_refund_date,
      p_idempotency_key
    );
  end if;

  perform log_audit_event(
    'customer_credit',
    p_credit_id,
    'customer_credit_refunded',
    jsonb_build_object(
      'credit_id', p_credit_id,
      'amount_cents', v_refund_amount,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'credit_id', p_credit_id,
    'refund_amount_cents', v_refund_amount,
    'credit_remaining_cents', v_credit.remaining_cents - v_refund_amount,
    'journal_id', v_journal_id
  );
end;
$$;

-- ============================================================================
-- SHARED NUMBER ALLOCATION HELPER
-- ============================================================================


-- ============================================================================
-- APPLY SUPPLIER CREDIT
-- ============================================================================

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
  v_credit_created_date date;
  v_can_post boolean;
  v_lock_date_formatted text;
begin
  perform assume_request_user(p_user_id);

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated',
      'error_code', 'NOT_AUTHENTICATED'
    );
  end if;

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

  if p_idempotency_key is not null then
    begin
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
    exception
      when unique_violation then
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

  if v_credit.contact_id != v_bill.vendor_id then
    raise exception 'VALIDATION_ERROR: Credit and bill must be for the same supplier';
  end if;

  if v_credit.organization_id != v_bill.organization_id then
    raise exception 'VALIDATION_ERROR: Credit and bill must be in the same organization';
  end if;

  if v_bill.status != 'Open' then
    raise exception 'INVALID_STATUS: Can only apply credit to Open bills';
  end if;

  v_bill_open_balance := v_bill.total_cents - v_bill.paid_cents;

  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    if v_credit.remaining_cents = 0 then
      raise exception 'INSUFFICIENT_BALANCE: No credit left to apply.';
    end if;
    raise exception '%', 'INSUFFICIENT_BALANCE: You can apply up to $' || to_char(v_credit.remaining_cents/100.0,'FM999,999,999,990.00') || '.';
  end if;

  if p_amount_cents > v_bill_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% bill balance owed.', to_char(v_bill_open_balance/100.0,'FM999,999,999,990.00');
  end if;

  v_apply_amount := p_amount_cents;

  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_bill.organization_id;
  
  v_credit_created_date := (v_credit.created_at at time zone v_org_timezone)::date;
  
  v_apply_date := greatest(
    (now() at time zone v_org_timezone)::date,
    v_bill.bill_date,
    v_credit_created_date
  );

  -- ATOMIC CHECK: Period lock BEFORE any account lookup or number allocation
  v_can_post := can_post_to_period(
    v_bill.organization_id,
    v_apply_date,
    v_user_role
  );

  if not v_can_post then
    v_lock_date_formatted := format_period_lock_date(v_bill.organization_id, v_apply_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.',
      'error_code', 'PERIOD_LOCKED'
    );
  end if;

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
    null,
    v_apply_date,
    'Applied supplier credit $' || to_char(v_apply_amount/100.0,'FM999,999,999,990.00') || ' to bill ' || v_bill.number,
    'Draft',
    'bill_payment',
    v_current_user_id
  )
  returning id into v_journal_id;

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

  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_post_result->>'error')::text ~ 'locked period' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception '%', v_post_result->>'error';
  end if;

  update supplier_credits
  set
    remaining_cents = remaining_cents - v_apply_amount,
    status = case
      when remaining_cents - v_apply_amount = 0 then 'applied'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  update bills
  set
    paid_cents = paid_cents + v_apply_amount,
    status = case
      when paid_cents + v_apply_amount >= total_cents then 'Paid'::bill_status
      else 'Open'::bill_status
    end,
    updated_at = now()
  where id = p_bill_id;

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
-- APPLY CUSTOMER CREDIT
-- ============================================================================

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
  v_credit_created_date date;
  v_can_post boolean;
  v_lock_date_formatted text;
begin
  perform assume_request_user(p_user_id);

  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated',
      'error_code', 'NOT_AUTHENTICATED'
    );
  end if;

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

  if p_idempotency_key is not null then
    begin
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
    exception
      when unique_violation then
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

  if v_credit.contact_id != v_invoice.customer_id then
    raise exception 'VALIDATION_ERROR: Credit and invoice must be for the same customer';
  end if;

  if v_credit.organization_id != v_invoice.organization_id then
    raise exception 'VALIDATION_ERROR: Credit and invoice must be in the same organization';
  end if;

  if v_invoice.status not in ('Posted', 'Paid') then
    raise exception 'INVALID_STATUS: Can only apply credit to Posted or Paid invoices';
  end if;

  v_invoice_open_balance := v_invoice.total_cents - v_invoice.received_cents;

  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    if v_credit.remaining_cents = 0 then
      raise exception 'INSUFFICIENT_BALANCE: No credit left to apply.';
    end if;
    raise exception '%', 'INSUFFICIENT_BALANCE: You can apply up to $' || to_char(v_credit.remaining_cents/100.0,'FM999,999,999,990.00') || '.';
  end if;

  if p_amount_cents > v_invoice_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% invoice balance owed.', to_char(v_invoice_open_balance/100.0,'FM999,999,999,990.00');
  end if;

  v_apply_amount := p_amount_cents;

  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_invoice.organization_id;
  
  v_credit_created_date := (v_credit.created_at at time zone v_org_timezone)::date;
  
  v_apply_date := greatest(
    (now() at time zone v_org_timezone)::date,
    v_invoice.invoice_date,
    v_credit_created_date
  );

  -- ATOMIC CHECK: Period lock BEFORE any account lookup or number allocation
  v_can_post := can_post_to_period(
    v_invoice.organization_id,
    v_apply_date,
    v_user_role
  );

  if not v_can_post then
    v_lock_date_formatted := format_period_lock_date(v_invoice.organization_id, v_apply_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.',
      'error_code', 'PERIOD_LOCKED'
    );
  end if;

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
    null,
    v_apply_date,
    'Applied customer credit $' || to_char(v_apply_amount/100.0,'FM999,999,999,990.00') || ' to invoice ' || v_invoice.number,
    'Draft',
    'invoice',
    v_current_user_id
  )
  returning id into v_journal_id;

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

  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_post_result->>'error')::text ~ 'locked period' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception '%', v_post_result->>'error';
  end if;

  update customer_credits
  set
    remaining_cents = remaining_cents - v_apply_amount,
    status = case
      when remaining_cents - v_apply_amount = 0 then 'applied'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  update invoices
  set
    received_cents = received_cents + v_apply_amount,
    status = case
      when received_cents + v_apply_amount >= total_cents then 'Paid'::invoice_status
      else 'Posted'::invoice_status
    end,
    updated_at = now()
  where id = p_invoice_id;

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

