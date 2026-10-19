-- ============================================================================
-- MIGRATION 000010: ATOMIC REFUSED POSTS + UNIFIED LOCK MESSAGES
-- ============================================================================
-- 1. Make refused posts atomic: check period lock BEFORE any number allocation
-- 2. Unified lock message everywhere: "This date is in a locked period. Choose a date after {Mon D, YYYY}."
-- 3. Have post_journal use format_period_lock_date for its lock error
-- 4. Apply to ALL posting paths: void, apply, refund
-- 5. Add check_period_open RPC for client-side posting paths

-- This migration is re-runnable: uses 'create or replace function' and conditional indexes/policies

-- CRITICAL: Postgres sequences don't roll back, and counter patterns (SELECT max)
-- should not waste time if post will fail. Check can_post_to_period BEFORE
-- any nextval or number allocation (sequence or counter), in every posting path.

-- ============================================================================
-- CLIENT-SIDE CHECK: check_period_open RPC
-- ============================================================================
-- Client posting paths (bills/new, invoices/new, journals/new, etc.) insert
-- Draft documents and journals BEFORE calling post_journal. To prevent orphan
-- drafts when period is locked, they must check BEFORE any inserts.

-- JOURNAL NUMBERING: Draft journals have NULL number. post_journal assigns
-- the number atomically after all checks pass.

-- Make journals.number nullable for drafts
alter table journals alter column number drop not null;

-- Replace unique constraint with partial unique index (only where number is not null)
alter table journals drop constraint if exists journals_organization_id_number_key;
drop index if exists journals_organization_id_number_key;
create unique index if not exists journals_organization_id_number_key 
  on journals (organization_id, number) 
  where number is not null;

create or replace function check_period_open(
  p_organization_id uuid,
  p_date date,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_user_role membership_role;
  v_can_post boolean;
  v_lock_date_formatted text;
begin
  -- Support API-key authentication via assume_request_user
  perform assume_request_user(p_user_id);

  v_user_id := auth.uid();

  if v_user_id is null then
    return jsonb_build_object(
      'ok', false,
      'error_code', 'NOT_AUTHENTICATED',
      'message', 'Not authenticated'
    );
  end if;

  -- Check membership
  select role into v_user_role
  from memberships
  where user_id = v_user_id
    and organization_id = p_organization_id;

  if v_user_role is null then
    return jsonb_build_object(
      'ok', false,
      'error_code', 'NOT_AUTHORIZED',
      'message', 'Not authorized for this organization'
    );
  end if;

  -- Check if user can post to this date/period
  v_can_post := can_post_to_period(
    p_organization_id,
    p_date,
    v_user_role
  );

  if not v_can_post then
    v_lock_date_formatted := format_period_lock_date(p_organization_id, p_date);
    return jsonb_build_object(
      'ok', false,
      'error_code', 'PERIOD_LOCKED',
      'message', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.'
    );
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function check_period_open(uuid, date, uuid) to authenticated;

-- ============================================================================
-- UNIFIED LOCK MESSAGE: UPDATE POST_JOURNAL
-- ============================================================================

create or replace function post_journal(
  p_journal_id uuid,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_journal journals;
  v_total_debit_cents bigint;
  v_total_credit_cents bigint;
  v_line_count int;
  v_has_header_accounts boolean;
  v_foreign_account boolean;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_can_post boolean;
  v_period_info jsonb;
  v_rows_updated integer;
  v_lock_date_formatted text;
  v_journal_number text;
  v_next_journal_number int;
  v_year int;
begin
  perform assume_request_user(p_user_id);

  v_current_user_id := auth.uid();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select * into v_journal
  from journals
  where id = p_journal_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal not found'
    );
  end if;

  v_organization_id := v_journal.organization_id;

  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  v_current_role := "current_role"();

  if v_journal.status = 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal already posted'
    );
  end if;

  if v_journal.status = 'Reversed' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a reversed journal'
    );
  end if;

  perform 1
  from journal_lines
  where journal_id = p_journal_id
  for update;

  select count(*) into v_line_count
  from journal_lines
  where journal_id = p_journal_id;

  if v_line_count < 2 then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal must have at least 2 lines'
    );
  end if;

  select
    coalesce(sum(debit_cents), 0),
    coalesce(sum(credit_cents), 0)
  into v_total_debit_cents, v_total_credit_cents
  from journal_lines
  where journal_id = p_journal_id;

  if v_total_debit_cents != v_total_credit_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal must balance: debits must equal credits'
    );
  end if;

  select exists(
    select 1
    from journal_lines jl
    join accounts a on a.id = jl.account_id
    where jl.journal_id = p_journal_id
      and a.is_header = true
  ) into v_has_header_accounts;

  if v_has_header_accounts then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post to header accounts'
    );
  end if;

  select exists(
    select 1
    from journal_lines jl
    join accounts a on a.id = jl.account_id
    where jl.journal_id = p_journal_id
      and a.organization_id is distinct from v_organization_id
  ) into v_foreign_account;

  if v_foreign_account then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal lines must use accounts from the same organization'
    );
  end if;

  v_can_post := can_post_to_period(
    v_organization_id,
    v_journal.entry_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, v_journal.entry_date);

    if v_period_info is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Cannot post to this date'
      );
    end if;

    v_lock_date_formatted := format_period_lock_date(v_organization_id, v_journal.entry_date);

    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.',
      'period_name', v_period_info->>'period_name',
      'period_status', v_period_info->>'status'
    );
  end if;

  -- ASSIGN JOURNAL NUMBER: Lock organization, generate JE-YYYY-NNNN number
  -- Only if journal doesn't already have a number (for drafts)
  if v_journal.number is null then
    v_journal_number := next_journal_number(v_organization_id, v_journal.entry_date);
  else
    -- Journal already has a number (pre-existing draft), keep it
    v_journal_number := v_journal.number;
  end if;

  update journals
  set
    number = v_journal_number,
    status = 'Posted',
    posted_at = now(),
    posted_by = v_current_user_id
  where id = p_journal_id
    and status = 'Draft';

  get diagnostics v_rows_updated = row_count;

  if v_rows_updated != 1 then
    return jsonb_build_object(
      'success', false,
      'error', 'Failed to post journal'
    );
  end if;

  perform log_audit_event(
    'journal',
    p_journal_id,
    'journal_posted',
    jsonb_build_object(
      'journal_number', v_journal_number,
      'entry_date', v_journal.entry_date,
      'amount_cents', v_total_debit_cents
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_id', p_journal_id,
    'journal_number', v_journal_number
  );
end;
$$;

-- ============================================================================
-- ATOMIC REFUSALS: CHECK PERIOD LOCK BEFORE CREATING DRAFTS
-- ============================================================================
-- For void_bill, void_invoice, apply_supplier_credit, apply_customer_credit,
-- refund_supplier_credit, refund_customer_credit: check can_post_to_period
-- BEFORE generating journal number or inserting draft journal/lines.
-- If check fails, return error JSON so entire RPC returns early with zero rows inserted.

-- Note: void_bill and void_invoice call reverse_journal which already checks
-- period locks and returns error without creating drafts. The credit journal
-- they create is where we need the up-front check.

-- ============================================================================
-- ATOMIC: VOID_BILL
-- ============================================================================

create or replace function void_bill(
  p_bill_id uuid,
  p_user_id uuid default null,
  p_void_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill bills;
  v_reversal_result jsonb;
  v_current_user_id uuid;
  v_user_role membership_role;
  v_supplier_credit_account_id uuid;
  v_ap_account_id uuid;
  v_credit_journal_id uuid;
  v_journal_number text;
  v_next_journal_number int;
  v_credit_id uuid;
  v_credit supplier_credits;
  v_org_timezone text;
  v_void_date date;
  v_recognition_date date;
  v_max_payment_date date;
  v_credit_created_date date;
  v_apply_date date;
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

  select role into v_user_role
  from memberships
  where user_id = v_current_user_id
    and organization_id = v_bill.organization_id;

  if v_user_role is null or v_user_role not in ('owner', 'admin', 'bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Insufficient permissions',
      'error_code', 'INSUFFICIENT_PERMISSIONS'
    );
  end if;

  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_bill.organization_id;

  if v_bill.recognition_journal_id is not null then
    select entry_date into v_recognition_date
    from journals
    where id = v_bill.recognition_journal_id;
  end if;

  select max(j.entry_date) into v_max_payment_date
  from bill_payments bp
  join journals j on j.id = bp.payment_journal_id
  where bp.bill_id = p_bill_id;

  v_void_date := greatest(
    coalesce(p_void_date, (now() at time zone v_org_timezone)::date),
    coalesce(v_recognition_date, '1900-01-01'::date),
    coalesce(v_max_payment_date, '1900-01-01'::date)
  );

  if v_bill.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill already void',
      'error_code', 'ALREADY_VOID'
    );
  end if;

  if v_bill.status not in ('Open', 'Paid') then
    raise exception 'INVALID_STATUS: Can only void Open or Paid bills';
  end if;

  if v_bill.recognition_journal_id is null then
    update bills
    set status = 'Void'::bill_status
    where id = p_bill_id;

    return jsonb_build_object(
      'success', true,
      'bill_id', p_bill_id,
      'void_date', v_void_date
    );
  end if;

  -- ATOMIC CHECK: verify period lock BEFORE calling reverse_journal
  v_can_post := can_post_to_period(
    v_bill.organization_id,
    v_void_date,
    v_user_role
  );

  if not v_can_post then
    v_lock_date_formatted := format_period_lock_date(v_bill.organization_id, v_void_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.',
      'error_code', 'PERIOD_LOCKED'
    );
  end if;

  v_reversal_result := reverse_journal(
    v_bill.recognition_journal_id,
    v_void_date,
    'Void bill: ' || v_bill.number,
    v_current_user_id
  );

  if not (v_reversal_result->>'success')::boolean then
    -- If reverse_journal somehow still fails with lock error, raise to rollback
    if (v_reversal_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_reversal_result->>'error')::text ~ 'locked period' then
      raise exception 'PERIOD_LOCKED: %', v_reversal_result->>'error';
    end if;
    return v_reversal_result;
  end if;

  if v_bill.paid_cents > 0 then
    -- ATOMIC CHECK: Compute apply date first, then check period lock
    -- BEFORE any account lookups or number allocation
    select coalesce(timezone, 'UTC') into v_org_timezone
    from organizations
    where id = v_bill.organization_id;
    
    v_credit_created_date := (v_credit.created_at at time zone v_org_timezone)::date;
    
    v_apply_date := greatest(
      (now() at time zone v_org_timezone)::date,
      v_bill.bill_date,
      v_credit_created_date
    );

    v_can_post := can_post_to_period(
      v_bill.organization_id,
      v_void_date,
      v_user_role
    );

    if not v_can_post then
      v_lock_date_formatted := format_period_lock_date(v_bill.organization_id, v_void_date);
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
      v_void_date,
      'Supplier credit $' || to_char(v_bill.paid_cents/100.0,'FM999,999,990.00') || ' from voided bill: ' || v_bill.number,
      'Draft',
      'bill_payment',
      v_current_user_id
    )
    returning id into v_credit_journal_id;

    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_bill.organization_id,
      v_credit_journal_id,
      v_supplier_credit_account_id,
      v_bill.paid_cents,
      0,
      'Credit from bill ' || v_bill.number
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
      v_credit_journal_id,
      v_ap_account_id,
      0,
      v_bill.paid_cents,
      'Credit from bill ' || v_bill.number
    );

    declare
      v_post_result jsonb;
    begin
      v_post_result := post_journal(v_credit_journal_id, v_current_user_id);
      
      if not (v_post_result->>'success')::boolean then
        if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_post_result->>'error')::text ~ 'locked period' then
          raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
        end if;
        raise exception '%', v_post_result->>'error';
      end if;
    end;

    insert into supplier_credits (
      organization_id,
      contact_id,
      source_bill_id,
      amount_cents,
      remaining_cents,
      status,
      journal_id
    ) values (
      v_bill.organization_id,
      v_bill.vendor_id,
      p_bill_id,
      v_bill.paid_cents,
      v_bill.paid_cents,
      'open',
      v_credit_journal_id
    )
    returning id into v_credit_id;

    perform log_audit_event(
      'bill',
      p_bill_id,
      'bill_voided_with_credit',
      jsonb_build_object(
        'bill_number', v_bill.number,
        'credit_amount_cents', v_bill.paid_cents,
        'credit_id', v_credit_id
      )
    );
  else
    perform log_audit_event(
      'bill',
      p_bill_id,
      'bill_voided',
      jsonb_build_object(
        'bill_number', v_bill.number
      )
    );
  end if;

  update bills
  set status = 'Void'::bill_status
  where id = p_bill_id;

  return jsonb_build_object(
    'success', true,
    'bill_id', p_bill_id,
    'reversal_result', v_reversal_result,
    'credit_id', v_credit_id,
    'credit_amount_cents', v_bill.paid_cents,
    'void_date', v_void_date
  );
end;
$$;

-- ============================================================================
-- ATOMIC: VOID_INVOICE (same pattern as void_bill)
-- ============================================================================

create or replace function void_invoice(
  p_invoice_id uuid,
  p_user_id uuid default null,
  p_void_date date default null
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
  v_journal_number text;
  v_next_journal_number int;
  v_credit_id uuid;
  v_org_timezone text;
  v_void_date date;
  v_recognition_date date;
  v_max_receipt_date date;
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

  select coalesce(timezone, 'UTC') into v_org_timezone
  from organizations
  where id = v_invoice.organization_id;

  if v_invoice.recognition_journal_id is not null then
    select entry_date into v_recognition_date
    from journals
    where id = v_invoice.recognition_journal_id;
  end if;

  select max(j.entry_date) into v_max_receipt_date
  from invoice_receipts ir
  join journals j on j.id = ir.receipt_journal_id
  where ir.invoice_id = p_invoice_id;

  v_void_date := greatest(
    coalesce(p_void_date, (now() at time zone v_org_timezone)::date),
    coalesce(v_recognition_date, '1900-01-01'::date),
    coalesce(v_max_receipt_date, '1900-01-01'::date)
  );

  if v_invoice.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice already void',
      'error_code', 'ALREADY_VOID'
    );
  end if;

  if v_invoice.status = 'Quote' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot void a quote',
      'error_code', 'INVALID_STATUS'
    );
  end if;

  if v_invoice.status not in ('Posted', 'Paid') then
    raise exception 'INVALID_STATUS: Can only void Posted or Paid invoices';
  end if;

  if v_invoice.recognition_journal_id is null then
    update invoices
    set status = 'Void'::invoice_status
    where id = p_invoice_id;

    return jsonb_build_object(
      'success', true,
      'invoice_id', p_invoice_id,
      'void_date', v_void_date
    );
  end if;

  -- ATOMIC CHECK: verify period lock BEFORE calling reverse_journal
  v_can_post := can_post_to_period(
    v_invoice.organization_id,
    v_void_date,
    v_user_role
  );

  if not v_can_post then
    v_lock_date_formatted := format_period_lock_date(v_invoice.organization_id, v_void_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.',
      'error_code', 'PERIOD_LOCKED'
    );
  end if;

  v_reversal_result := reverse_journal(
    v_invoice.recognition_journal_id,
    v_void_date,
    'Void invoice: ' || v_invoice.number,
    v_current_user_id
  );

  if not (v_reversal_result->>'success')::boolean then
    -- If reverse_journal somehow still fails with lock error, raise to rollback
    if (v_reversal_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_reversal_result->>'error')::text ~ 'locked period' then
      raise exception 'PERIOD_LOCKED: %', v_reversal_result->>'error';
    end if;
    return v_reversal_result;
  end if;

  if v_invoice.received_cents > 0 then
    -- ATOMIC CHECK: Compute timezone and check period lock
    -- BEFORE any account lookups or number allocation
    select coalesce(timezone, 'UTC') into v_org_timezone
    from organizations
    where id = v_invoice.organization_id;

    v_can_post := can_post_to_period(
      v_invoice.organization_id,
      v_void_date,
      v_user_role
    );

    if not v_can_post then
      v_lock_date_formatted := format_period_lock_date(v_invoice.organization_id, v_void_date);
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
      v_void_date,
      'Customer credit $' || to_char(v_invoice.received_cents/100.0,'FM999,999,990.00') || ' from voided invoice: ' || v_invoice.number,
      'Draft',
      'invoice',
      v_current_user_id
    )
    returning id into v_credit_journal_id;

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

    declare
      v_post_result jsonb;
    begin
      v_post_result := post_journal(v_credit_journal_id, v_current_user_id);
      
      if not (v_post_result->>'success')::boolean then
        if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' or (v_post_result->>'error')::text ~ 'locked period' then
          raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
        end if;
        raise exception '%', v_post_result->>'error';
      end if;
    end;

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
    perform log_audit_event(
      'invoice',
      p_invoice_id,
      'invoice_voided',
      jsonb_build_object(
        'invoice_number', v_invoice.number
      )
    );
  end if;

  update invoices
  set status = 'Void'::invoice_status
  where id = p_invoice_id;

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'reversal_result', v_reversal_result,
    'credit_id', v_credit_id,
    'credit_amount_cents', v_invoice.received_cents,
    'void_date', v_void_date
  );
end;
$$;

-- ============================================================================
-- NOTE: apply_supplier_credit, apply_customer_credit, refund_supplier_credit,
-- and refund_customer_credit already check period locks via post_journal,
-- and raise exceptions on failure (causing atomic rollback). For completeness
-- and consistency, we add early can_post_to_period checks BEFORE number
-- allocation in these functions below.
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
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', to_char(v_credit.remaining_cents/100.0,'FM999,999,990.00');
  end if;

  if p_amount_cents > v_bill_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% bill balance owed.', to_char(v_bill_open_balance/100.0,'FM999,999,990.00');
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
    'Applied supplier credit $' || to_char(v_apply_amount/100.0,'FM999,999,990.00') || ' to bill ' || v_bill.number,
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
-- ATOMIC: APPLY_CUSTOMER_CREDIT WITH EARLY LOCK CHECK
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
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', to_char(v_credit.remaining_cents/100.0,'FM999,999,990.00');
  end if;

  if p_amount_cents > v_invoice_open_balance then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% invoice balance owed.', to_char(v_invoice_open_balance/100.0,'FM999,999,990.00');
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
    'Applied customer credit $' || to_char(v_apply_amount/100.0,'FM999,999,990.00') || ' to invoice ' || v_invoice.number,
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

-- ============================================================================
-- ATOMIC: REFUND_SUPPLIER_CREDIT WITH EARLY LOCK CHECK
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
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', (v_credit.remaining_cents::decimal / 100);
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
    format('Refund supplier credit $%s', (v_refund_amount::decimal / 100)),
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
-- ATOMIC: REFUND_CUSTOMER_CREDIT WITH EARLY LOCK CHECK
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
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', (v_credit.remaining_cents::decimal / 100);
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
    format('Refund customer credit $%s', (v_refund_amount::decimal / 100)),
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

create or replace function next_journal_number(
  p_organization_id uuid,
  p_entry_date date
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int;
  v_next_number int;
  v_journal_number text;
begin
  -- Lock organization row to serialize number generation
  perform 1 from organizations where id = p_organization_id for update;
  
  v_year := extract(year from p_entry_date);
  
  select coalesce(max(cast(substring(number from 'JE-[0-9]+-([0-9]+)') as int)), 0) + 1
  into v_next_number
  from journals
  where organization_id = p_organization_id
    and number ~ ('^JE-' || v_year || '-[0-9]+$');
  
  v_journal_number := 'JE-' || v_year || '-' || lpad(v_next_number::text, 4, '0');
  
  return v_journal_number;
end;
$$;

-- Security: Only database functions can call this
revoke all on function next_journal_number(uuid, date) from public, anon, authenticated;

-- ============================================================================
-- REDEFINED: create_manual_journal (insert Draft, then post_journal)
-- ============================================================================

-- Drop older 5-param overload if it exists
do $$
begin
  if exists (
    select 1 from pg_proc
    where proname = 'create_manual_journal'
      and pronargs = 5
      and oidvectortypes(proargtypes) = 'uuid, text, date, text, jsonb'
  ) then
    drop function create_manual_journal(uuid, text, date, text, jsonb);
  end if;
end $$;

create or replace function create_manual_journal(
  p_organization_id uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb,
  p_should_post boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journal_id uuid;
  v_line jsonb;
  v_line_count int;
  v_duplicate_id uuid;
  v_duplicate_status text;
  v_current_org_id uuid;
  v_stripped_lines jsonb;
begin
  -- Auth checks: user must be authenticated and belong to org with owner/bookkeeper role
  if auth.uid() is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select current_org_id() into v_current_org_id;
  
  if v_current_org_id != p_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authorized for this organization'
    );
  end if;

  if not (has_role('owner') or has_role('bookkeeper')) then
    return jsonb_build_object(
      'success', false,
      'error', 'Insufficient permissions'
    );
  end if;

  -- Strip memo from lines for fingerprint comparison
  select jsonb_agg(
    jsonb_build_object(
      'account_id', line->>'account_id',
      'debit_cents', (line->>'debit_cents')::bigint,
      'credit_cents', (line->>'credit_cents')::bigint
    ) order by line->>'account_id', (line->>'debit_cents')::bigint, (line->>'credit_cents')::bigint
  ) into v_stripped_lines
  from jsonb_array_elements(p_lines) as line;

  -- Check for recent duplicate (same entry_date + description + line fingerprint in last 2 minutes)
  with line_fingerprints as (
    select
      j.id,
      j.status,
      j.created_at,
      jsonb_agg(
        jsonb_build_object(
          'account_id', jl.account_id,
          'debit_cents', jl.debit_cents,
          'credit_cents', jl.credit_cents
        ) order by jl.account_id, jl.debit_cents, jl.credit_cents
      ) as fingerprint
    from journals j
    join journal_lines jl on jl.journal_id = j.id
    where j.organization_id = p_organization_id
      and j.entry_date = p_entry_date
      and j.description = p_description
      and j.created_at > now() - interval '2 minutes'
    group by j.id, j.status, j.created_at
  )
  select lf.id, lf.status into v_duplicate_id, v_duplicate_status
  from line_fingerprints lf
  where lf.fingerprint = v_stripped_lines
  order by lf.created_at desc
  limit 1;

  -- If duplicate found, return existing journal
  if v_duplicate_id is not null then
    -- If user wanted to post and it's still Draft, post it now
    if p_should_post and v_duplicate_status = 'Draft' then
      perform post_journal(v_duplicate_id, auth.uid());
    end if;
    
    return jsonb_build_object(
      'success', true,
      'journal_id', v_duplicate_id,
      'is_duplicate', true
    );
  end if;

  -- Create journal with null number (assigned at post time)
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    p_organization_id,
    null,
    p_entry_date,
    p_description,
    'Draft',
    'manual',
    auth.uid()
  )
  returning id into v_journal_id;

  -- Create lines
  v_line_count := 0;
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      p_organization_id,
      v_journal_id,
      (v_line->>'account_id')::uuid,
      (v_line->>'debit_cents')::bigint,
      (v_line->>'credit_cents')::bigint,
      v_line->>'memo'
    );
    v_line_count := v_line_count + 1;
  end loop;

  -- Validate minimum lines
  if v_line_count < 2 then
    raise exception 'Journal must have at least 2 lines';
  end if;

  -- Post if requested (calls post_journal which assigns number, checks balance, logs audit)
  if p_should_post then
    declare
      v_post_result jsonb;
    begin
      v_post_result := post_journal(v_journal_id, auth.uid());
      if not (v_post_result->>'success')::boolean then
        raise exception 'Failed to post: %', v_post_result->>'error';
      end if;
    end;
  end if;

  return jsonb_build_object(
    'success', true,
    'journal_id', v_journal_id,
    'is_duplicate', false
  );
end;
$$;

-- Restrict access
revoke all on function create_manual_journal(uuid, date, text, jsonb, boolean) from public;
grant execute on function create_manual_journal(uuid, date, text, jsonb, boolean) to authenticated;

-- ============================================================================
-- INVOICE POSTING FUNCTIONS (with next_journal_number)
-- ============================================================================

create or replace function post_invoice(p_invoice_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assume_request_user(p_user_id);
  return post_invoice(p_invoice_id);
end;
$$;

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
  v_lock_date_formatted text;
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
      'error', 'Quote is status only — no journal. Save as Invoice to post.'
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
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(format_period_lock_date(v_organization_id, v_invoice.invoice_date), 'the lock date') || '.'
    );
  end if;

  -- Validate customer contact type
  declare
    v_contact_type contact_type;
  begin
    select type into v_contact_type
    from contacts
    where id = v_invoice.customer_id;

    if v_contact_type is distinct from 'Customer' then
      return jsonb_build_object(
        'success', false,
        'error', 'Invoice picker is Customer only. Parent cash-in is a journal Dr 1010 / Cr 3100, never an invoice.'
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
      'Accounts receivable',
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

  -- Create recognition journal (Draft with null number)
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
    null,
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
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Read back the assigned journal number
  select number into v_journal_number
  from journals
  where id = v_journal_id;

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
    'journal_id', v_journal_id,
    'journal_number', v_journal_number
  );
end;
$$;

grant execute on function post_invoice(uuid) to authenticated;

comment on function post_invoice(uuid) is 'Posts an invoice, creating Dr AR / Cr Revenue journal. Validates period locks and revenue account types.';

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
  v_lock_date_formatted text;
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
    v_lock_date_formatted := format_period_lock_date(v_organization_id, p_receipt_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.'
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

  -- Create receipt journal (Draft with null number)
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
    null,
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
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Read back the assigned journal number
  select number into v_journal_number
  from journals
  where id = v_journal_id;

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
      'journal_id', v_journal_id,
      'journal_number', v_journal_number
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id,
    'journal_number', v_journal_number
  );
end;
$$;

grant execute on function record_receipt(uuid, date, bigint, uuid, text) to authenticated;

comment on function record_receipt(uuid, date, bigint, uuid, text) is 'Records a cash receipt against an invoice: Dr Cash / Cr AR';

-- ============================================================================
-- ISSUE CREDIT NOTE

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
  v_lock_date_formatted text;
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
    v_lock_date_formatted := format_period_lock_date(v_organization_id, p_credit_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.'
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

  -- Create credit note journal (Draft with null number)
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
    null,
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
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Read back the assigned journal number
  select number into v_journal_number
  from journals
  where id = v_journal_id;

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
      'journal_id', v_journal_id,
      'journal_number', v_journal_number
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id,
    'journal_number', v_journal_number
  );
end;
$$;

grant execute on function issue_credit_note(uuid, date, bigint, text) to authenticated;

comment on function issue_credit_note(uuid, date, bigint, text) is 'Issues a credit note against an invoice: Dr Revenue / Cr AR';

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
  v_lock_date_formatted text;
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
    v_lock_date_formatted := format_period_lock_date(v_organization_id, p_write_off_date);
    return jsonb_build_object(
      'success', false,
      'error', 'This date is in a locked period. Choose a date after ' || coalesce(v_lock_date_formatted, 'the lock date') || '.'
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

  -- Get or create Bad debt expense account (5110)
  select id into v_bad_debt_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '5110'
    and is_active = true;

  if v_bad_debt_account_id is null then
    -- Create Bad debt expense account
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
      'Bad debt',
      'Expense',
      'Expense',
      true
    )
    returning id into v_bad_debt_account_id;
  end if;

  -- Create write-off journal (Draft with null number)
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
    null,
    p_write_off_date,
    format('Write-off invoice %s: %s', v_invoice.number, p_reason),
    'Draft',
    'manual',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Bad debt expense
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
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Read back the assigned journal number
  select number into v_journal_number
  from journals
  where id = v_journal_id;

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
      'journal_id', v_journal_id,
      'journal_number', v_journal_number
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id,
    'journal_number', v_journal_number
  );
end;
$$;

grant execute on function write_off_invoice(uuid, date, bigint, text) to authenticated;

comment on function write_off_invoice(uuid, date, bigint, text) is 'Writes off an unpaid invoice: Dr Bad debt (5110) / Cr AR (1100)';
