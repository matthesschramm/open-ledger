-- Supplier and Customer Credits for Void Bill/Invoice
-- Fixes void_bill orphaning payments when voiding paid/part-paid bills
-- Mirrors invoice behavior for customer credits

-- ============================================================================
-- HELPER: Ensure Account Exists
-- ============================================================================

create or replace function ensure_account(
  p_organization_id uuid,
  p_code text,
  p_name text,
  p_type account_type,
  p_category account_category
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account_id uuid;
begin
  -- Try to find existing account
  select id into v_account_id
  from accounts
  where organization_id = p_organization_id
    and code = p_code;

  if found then
    return v_account_id;
  end if;

  -- Create new account
  insert into accounts (
    organization_id,
    code,
    name,
    type,
    category,
    is_system,
    is_active
  ) values (
    p_organization_id,
    p_code,
    p_name,
    p_type,
    p_category,
    true,
    true
  )
  on conflict (organization_id, code) do nothing
  returning id into v_account_id;

  -- If conflict occurred, fetch the id
  if v_account_id is null then
    select id into v_account_id
    from accounts
    where organization_id = p_organization_id
      and code = p_code;
  end if;

  return v_account_id;
end;
$$;

grant execute on function ensure_account(uuid, text, text, account_type, account_category) to authenticated, service_role;

comment on function ensure_account is 'Ensures an account exists; creates if missing using ON CONFLICT DO NOTHING pattern';

-- ============================================================================
-- SUPPLIER CREDITS TABLE
-- ============================================================================

create table if not exists supplier_credits (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid not null references contacts(id),
  source_bill_id uuid not null references bills(id),
  amount_cents bigint not null check (amount_cents > 0),
  remaining_cents bigint not null check (remaining_cents >= 0 and remaining_cents <= amount_cents),
  status text not null check (status in ('open', 'applied', 'refunded')),
  journal_id uuid not null references journals(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (remaining_cents <= amount_cents)
);

create index if not exists supplier_credits_organization_id_idx on supplier_credits(organization_id);
create index if not exists supplier_credits_contact_id_idx on supplier_credits(contact_id);
create index if not exists supplier_credits_source_bill_id_idx on supplier_credits(source_bill_id);
create index if not exists supplier_credits_status_idx on supplier_credits(organization_id, status);

comment on table supplier_credits is 'Tracks supplier credits created when voiding paid/part-paid bills';
comment on column supplier_credits.remaining_cents is 'Amount available to apply to future bills or refund';
comment on column supplier_credits.status is 'open = has remaining balance, applied = fully used, refunded = refunded to cash';

-- RLS for supplier_credits (SELECT only for members, writes via RPCs only)
alter table supplier_credits enable row level security;

drop policy if exists "Users can view supplier_credits in their organization" on supplier_credits;
create policy "Users can view supplier_credits in their organization"
  on supplier_credits for select
  using (organization_id = current_org_id());

-- No insert/update/delete policies - writes only via RPCs

-- ============================================================================
-- CUSTOMER CREDITS TABLE
-- ============================================================================

create table if not exists customer_credits (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid not null references contacts(id),
  source_invoice_id uuid not null references invoices(id),
  amount_cents bigint not null check (amount_cents > 0),
  remaining_cents bigint not null check (remaining_cents >= 0 and remaining_cents <= amount_cents),
  status text not null check (status in ('open', 'applied', 'refunded')),
  journal_id uuid not null references journals(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (remaining_cents <= amount_cents)
);

create index if not exists customer_credits_organization_id_idx on customer_credits(organization_id);
create index if not exists customer_credits_contact_id_idx on customer_credits(contact_id);
create index if not exists customer_credits_source_invoice_id_idx on customer_credits(source_invoice_id);
create index if not exists customer_credits_status_idx on customer_credits(organization_id, status);

comment on table customer_credits is 'Tracks customer credits created when voiding paid/part-paid invoices';
comment on column customer_credits.remaining_cents is 'Amount available to apply to future invoices or refund';
comment on column customer_credits.status is 'open = has remaining balance, applied = fully used, refunded = refunded to cash';

-- RLS for customer_credits (SELECT only for members, writes via RPCs only)
alter table customer_credits enable row level security;

drop policy if exists "Users can view customer_credits in their organization" on customer_credits;
create policy "Users can view customer_credits in their organization"
  on customer_credits for select
  using (organization_id = current_org_id());

-- No insert/update/delete policies - writes only via RPCs

-- ============================================================================
-- UPDATE VOID_BILL (fix orphaned payments)
-- ============================================================================

-- Drop old void_bill(uuid) to avoid ambiguous overload
drop function if exists void_bill(uuid);

create or replace function void_bill(
  p_bill_id uuid,
  p_user_id uuid default null
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

  -- Get bill with lock
  select * into v_bill
  from bills
  where id = p_bill_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill not found'
    );
  end if;

  -- Check user's role in the bill's organization (must be owner/admin/bookkeeper)
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

  -- Check if already void
  if v_bill.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill already void',
      'error_code', 'ALREADY_VOID'
    );
  end if;

  -- Check if bill has recognition journal
  if v_bill.recognition_journal_id is null then
    -- Just mark as void if no journal yet
    update bills
    set status = 'Void'
    where id = p_bill_id;

    return jsonb_build_object(
      'success', true,
      'bill_id', p_bill_id
    );
  end if;

  -- Reverse the recognition journal (Dr 2000 AP / Cr expense)
  v_reversal_result := reverse_journal(
    v_bill.recognition_journal_id,
    current_date,
    'Void bill: ' || v_bill.number,
    v_current_user_id
  );

  if not (v_reversal_result->>'success')::boolean then
    -- Check if it's a period lock error
    if (v_reversal_result->>'error')::text ~ '(Locked|Soft-closed)' then
      return jsonb_build_object(
        'success', false,
        'error', v_reversal_result->>'error',
        'error_code', 'PERIOD_LOCKED',
        'period_name', v_reversal_result->>'period_name',
        'period_status', v_reversal_result->>'period_status'
      );
    end if;
    -- Reversal failed - return error without changing bill status
    return v_reversal_result;
  end if;

  -- If bill was paid (full or partial), create supplier credit
  -- Payment journals (Dr 2000 / Cr cash) stay Posted; never auto-reverse
  -- Credit: Dr 1460 Supplier credits / Cr 2000 AP for paid_cents
  if v_bill.paid_cents > 0 then
    -- Ensure 1460 Supplier credits account exists
    v_supplier_credit_account_id := ensure_account(
      v_bill.organization_id,
      '1460',
      'Supplier credits',
      'Asset',
      'Other'
    );

    -- Get 2000 AP account
    select id into v_ap_account_id
    from accounts
    where organization_id = v_bill.organization_id
      and code = '2000';

    if v_ap_account_id is null then
      raise exception 'AP account (2000) not found';
    end if;

    -- Generate journal number (use same pattern as bill posting)
    select coalesce(max(cast(substring(number from '[0-9]+') as int)), 0) + 1
    into v_next_journal_number
    from journals
    where organization_id = v_bill.organization_id
      and number ~ '^J[0-9]+$';

    v_journal_number := 'J' || lpad(v_next_journal_number::text, 4, '0');

    -- Create credit journal: Dr 1460 / Cr 2000 (Draft first)
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
      'Supplier credit from voided bill: ' || v_bill.number,
      'Draft',
      'bill',
      v_current_user_id
    )
    returning id into v_credit_journal_id;

    -- Dr 1460 Supplier credits
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

    -- Cr 2000 AP
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

    -- Create supplier credit record
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

    -- Log audit event
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
    -- Log audit event (no credit)
    perform log_audit_event(
      'bill',
      p_bill_id,
      'bill_voided',
      jsonb_build_object(
        'bill_number', v_bill.number
      )
    );
  end if;

  -- Mark bill as void
  update bills
  set status = 'Void'
  where id = p_bill_id;

  return jsonb_build_object(
    'success', true,
    'bill_id', p_bill_id,
    'reversal_result', v_reversal_result,
    'credit_id', v_credit_id,
    'credit_amount_cents', v_bill.paid_cents
  );
end;
$$;

grant execute on function void_bill(uuid, uuid) to authenticated, service_role;

comment on function void_bill is 'Voids a bill by reversing its recognition journal. For paid/part-paid bills, creates supplier credit. Payment journals stay Posted. Supports both browser (JWT) and API-key (service_role + p_user_id) authentication.';

-- ============================================================================
-- VOID_INVOICE (mirror of void_bill)
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
      'error', 'Invoice not found'
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
    set status = 'Void'
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
      'invoice',
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
  set status = 'Void'
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

grant execute on function void_invoice(uuid, uuid) to authenticated, service_role;

comment on function void_invoice is 'Voids an invoice by reversing its recognition journal. For paid/part-paid invoices, creates customer credit. Receipt journals stay Posted. Supports both browser (JWT) and API-key (service_role + p_user_id) authentication.';

-- ============================================================================
-- APPLY SUPPLIER CREDIT
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

  -- Get bill with lock
  select * into v_bill
  from bills
  where id = p_bill_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill not found'
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

  -- Update bill
  update bills
  set
    paid_cents = paid_cents + v_apply_amount,
    status = case
      when paid_cents + v_apply_amount >= total_cents then 'Paid'
      else 'Open'
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

grant execute on function apply_supplier_credit(uuid, uuid, bigint, uuid) to authenticated, service_role;

comment on function apply_supplier_credit is 'Applies supplier credit to a bill. Same supplier required. Amount <= min(remaining, bill open balance). Dr 2000 / Cr 1460. Reduces remaining and bill open balance. Supports both browser (JWT) and API-key (service_role + p_user_id) authentication.';

-- ============================================================================
-- REFUND SUPPLIER CREDIT
-- ============================================================================

create or replace function refund_supplier_credit(
  p_credit_id uuid,
  p_amount_cents bigint,
  p_cash_account_id uuid default null,
  p_refund_date date default null,
  p_user_id uuid default null
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

  -- Validate amount (row lock held - prevents concurrent overdraw)
  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', (v_credit.remaining_cents::decimal / 100);
  end if;

  v_refund_amount := p_amount_cents;
  v_refund_date := coalesce(p_refund_date, current_date);

  -- Get cash account (default to 1010)
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
      raise exception 'Default cash account (1010) not found';
    end if;
  end if;

  -- Get supplier credit account
  v_supplier_credit_account_id := ensure_account(
    v_credit.organization_id,
    '1460',
    'Supplier credits',
    'Asset',
    'Other'
  );

  -- Generate journal number
  select coalesce(max(cast(substring(number from '[0-9]+') as int)), 0) + 1
  into v_next_journal_number
  from journals
  where organization_id = v_credit.organization_id
    and number ~ '^J[0-9]+$';

  v_journal_number := 'J' || lpad(v_next_journal_number::text, 4, '0');

  -- Create journal: Dr cash / Cr 1460 Supplier credits (Draft first)
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
    v_journal_number,
    v_refund_date,
    format('Refunded supplier credit $%s (books only)', (v_refund_amount::decimal / 100)),
    'Draft',
    'cash',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr cash
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
    'Supplier credit refund (books only)'
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
    v_credit.organization_id,
    v_journal_id,
    v_supplier_credit_account_id,
    0,
    v_refund_amount,
    'Refunded to supplier (books only)'
  );

  -- Post the journal via post_journal RPC (respects period locks)
  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    -- Check if it's a period lock error
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception 'Failed to post refund journal: %', v_post_result->>'error';
  end if;

  -- Update supplier credit
  update supplier_credits
  set
    remaining_cents = remaining_cents - v_refund_amount,
    status = case
      when remaining_cents - v_refund_amount = 0 then 'refunded'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  -- Log audit event
  perform log_audit_event(
    'supplier_credit',
    p_credit_id,
    'supplier_credit_refunded',
    jsonb_build_object(
      'credit_id', p_credit_id,
      'amount_cents', v_refund_amount
    )
  );

  return jsonb_build_object(
    'success', true,
    'credit_id', p_credit_id,
    'refunded_amount_cents', v_refund_amount,
    'credit_remaining_cents', v_credit.remaining_cents - v_refund_amount,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function refund_supplier_credit(uuid, bigint, uuid, date, uuid) to authenticated, service_role;

comment on function refund_supplier_credit is 'Refunds supplier credit to cash. Books only, no actual money movement. Dr cash / Cr 1460. Default cash account 1010. Supports both browser (JWT) and API-key (service_role + p_user_id) authentication.';

-- ============================================================================
-- APPLY CUSTOMER CREDIT
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

  -- Update invoice
  update invoices
  set
    received_cents = received_cents + v_apply_amount,
    status = case
      when received_cents + v_apply_amount >= total_cents then 'Paid'
      else 'Posted'
    end,
    updated_at = now()
  where id = p_invoice_id;

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

grant execute on function apply_customer_credit(uuid, uuid, bigint, uuid) to authenticated, service_role;

comment on function apply_customer_credit is 'Applies customer credit to an invoice. Same customer required. Amount <= min(remaining, invoice open balance). Dr 2310 / Cr 1100. Reduces remaining and invoice open balance. Supports both browser (JWT) and API-key (service_role + p_user_id) authentication.';

-- ============================================================================
-- REFUND CUSTOMER CREDIT
-- ============================================================================

create or replace function refund_customer_credit(
  p_credit_id uuid,
  p_amount_cents bigint,
  p_cash_account_id uuid default null,
  p_refund_date date default null,
  p_user_id uuid default null
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

  -- Validate amount (row lock held - prevents concurrent overdraw)
  if p_amount_cents <= 0 then
    raise exception 'VALIDATION_ERROR: Amount must be positive';
  end if;

  if p_amount_cents > v_credit.remaining_cents then
    raise exception 'INSUFFICIENT_BALANCE: That''s more than the $% credit available.', (v_credit.remaining_cents::decimal / 100);
  end if;

  v_refund_amount := p_amount_cents;
  v_refund_date := coalesce(p_refund_date, current_date);

  -- Get cash account (default to 1010)
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
      raise exception 'Default cash account (1010) not found';
    end if;
  end if;

  -- Get customer credit account
  v_customer_credit_account_id := ensure_account(
    v_credit.organization_id,
    '2310',
    'Customer credits',
    'Liability',
    'Other'
  );

  -- Generate journal number
  select coalesce(max(cast(substring(number from '[0-9]+') as int)), 0) + 1
  into v_next_journal_number
  from journals
  where organization_id = v_credit.organization_id
    and number ~ '^J[0-9]+$';

  v_journal_number := 'J' || lpad(v_next_journal_number::text, 4, '0');

  -- Create journal: Dr 2310 Customer credits / Cr cash (Draft first)
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
    v_journal_number,
    v_refund_date,
    format('Refunded customer credit $%s (books only)', (v_refund_amount::decimal / 100)),
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
    v_credit.organization_id,
    v_journal_id,
    v_customer_credit_account_id,
    v_refund_amount,
    0,
    'Customer credit refund (books only)'
  );

  -- Cr cash
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
    'Refunded to customer (books only)'
  );

  -- Post the journal via post_journal RPC (respects period locks)
  v_post_result := post_journal(v_journal_id, v_current_user_id);
  
  if not (v_post_result->>'success')::boolean then
    -- Check if it's a period lock error
    if (v_post_result->>'error')::text ~ '(Locked|Soft-closed)' then
      raise exception 'PERIOD_LOCKED: %', v_post_result->>'error';
    end if;
    raise exception 'Failed to post refund journal: %', v_post_result->>'error';
  end if;

  -- Update customer credit
  update customer_credits
  set
    remaining_cents = remaining_cents - v_refund_amount,
    status = case
      when remaining_cents - v_refund_amount = 0 then 'refunded'
      else 'open'
    end,
    updated_at = now()
  where id = p_credit_id;

  -- Log audit event
  perform log_audit_event(
    'customer_credit',
    p_credit_id,
    'customer_credit_refunded',
    jsonb_build_object(
      'credit_id', p_credit_id,
      'amount_cents', v_refund_amount
    )
  );

  return jsonb_build_object(
    'success', true,
    'credit_id', p_credit_id,
    'refunded_amount_cents', v_refund_amount,
    'credit_remaining_cents', v_credit.remaining_cents - v_refund_amount,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function refund_customer_credit(uuid, bigint, uuid, date, uuid) to authenticated, service_role;

comment on function refund_customer_credit is 'Refunds customer credit to cash. Books only, no actual money movement. Dr 2310 / Cr cash. Default cash account 1010. Supports both browser (JWT) and API-key (service_role + p_user_id) authentication.';

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';
