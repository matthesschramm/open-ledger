-- Open Ledger RPC Functions with Role Enforcement
-- Phase 4: Updated RPCs to respect role hierarchy and permissions

-- ============================================================================
-- POST JOURNAL (Bookkeeper+, Open Period)
-- ============================================================================

create or replace function post_journal(p_journal_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_journal journals;
  v_total_debit_cents bigint;
  v_total_credit_cents bigint;
  v_line_count int;
  v_has_header_accounts boolean;
  v_period_locked boolean;
  v_organization_id uuid;
  v_current_user_id text;
begin
  -- Get current user
  v_current_user_id := auth.uid()::text;
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Get journal with lock
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

  -- Check membership and role (must be bookkeeper+)
  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  -- Check if already posted
  if v_journal.status = 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal already posted'
    );
  end if;

  -- Check if reversed
  if v_journal.status = 'Reversed' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a reversed journal'
    );
  end if;

  -- Count lines
  select count(*) into v_line_count
  from journal_lines
  where journal_id = p_journal_id;

  if v_line_count < 2 then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal must have at least 2 lines'
    );
  end if;

  -- Calculate totals
  select
    coalesce(sum(debit_cents), 0),
    coalesce(sum(credit_cents), 0)
  into v_total_debit_cents, v_total_credit_cents
  from journal_lines
  where journal_id = p_journal_id;

  -- Check if balanced
  if v_total_debit_cents != v_total_credit_cents then
    return jsonb_build_object(
      'success', false,
      'error', format('Journal not balanced: debit %s != credit %s', v_total_debit_cents, v_total_credit_cents)
    );
  end if;

  -- Check for header accounts
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

  -- Check if period is locked
  v_period_locked := is_period_locked(v_organization_id, v_journal.entry_date);

  if v_period_locked then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post to a locked period'
    );
  end if;

  -- Post the journal
  update journals
  set
    status = 'Posted',
    posted_at = now(),
    posted_by = v_current_user_id::uuid
  where id = p_journal_id;

  return jsonb_build_object(
    'success', true,
    'journal_id', p_journal_id
  );
end;
$$;

-- ============================================================================
-- REVERSE JOURNAL (Bookkeeper+, Open Period for Reversal)
-- ============================================================================

create or replace function reverse_journal(
  p_journal_id uuid,
  p_reversal_date date,
  p_reversal_description text default null
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_journal journals;
  v_reversal_journal_id uuid;
  v_reversal_number text;
  v_reversal_description text;
  v_line record;
  v_period_locked boolean;
  v_organization_id uuid;
  v_current_user_id text;
begin
  -- Get current user
  v_current_user_id := auth.uid()::text;

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Get journal with lock
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

  -- Check membership and role (must be bookkeeper+)
  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  -- Check if already reversed
  if v_journal.reversed_by_journal_id is not null then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal already reversed'
    );
  end if;

  -- Can only reverse posted journals
  if v_journal.status != 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only reverse posted journals'
    );
  end if;

  -- Check if reversal period is locked
  v_period_locked := is_period_locked(v_organization_id, p_reversal_date);

  if v_period_locked then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post reversal to a locked period'
    );
  end if;

  -- Generate reversal number and description
  v_reversal_number := 'REV-' || v_journal.number;
  v_reversal_description := coalesce(p_reversal_description, 'REVERSAL: ' || v_journal.description);

  -- Create reversal journal
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    reverses_journal_id,
    created_by
  ) values (
    v_organization_id,
    v_reversal_number,
    p_reversal_date,
    v_reversal_description,
    'Draft',
    'reversal',
    p_journal_id,
    v_current_user_id::uuid
  )
  returning id into v_reversal_journal_id;

  -- Copy lines with swapped debits and credits
  for v_line in
    select account_id, debit_cents, credit_cents, memo
    from journal_lines
    where journal_id = p_journal_id
  loop
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_organization_id,
      v_reversal_journal_id,
      v_line.account_id,
      v_line.credit_cents,  -- swap
      v_line.debit_cents,   -- swap
      case
        when v_line.memo is not null then 'Reversing: ' || v_line.memo
        else 'Reversal'
      end
    );
  end loop;

  -- Post the reversal journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_reversal_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      -- Rollback will happen automatically
      return v_post_result;
    end if;
  end;

  -- Update original journal status to Reversed
  update journals
  set
    status = 'Reversed',
    reversed_by_journal_id = v_reversal_journal_id
  where id = p_journal_id;

  return jsonb_build_object(
    'success', true,
    'original_journal_id', p_journal_id,
    'reversal_journal_id', v_reversal_journal_id
  );
end;
$$;

-- ============================================================================
-- LOCK PERIOD (Admin+)
-- ============================================================================

create or replace function lock_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_period accounting_periods;
  v_current_user_id text;
begin
  -- Get current user
  v_current_user_id := auth.uid()::text;

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Get period with lock
  select * into v_period
  from accounting_periods
  where id = p_period_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Period not found'
    );
  end if;

  -- Check membership and role (must be admin+)
  if not has_role('admin') or current_org_id() != v_period.organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: admin role or higher required'
    );
  end if;

  -- Check if already locked
  if v_period.is_locked then
    return jsonb_build_object(
      'success', false,
      'error', 'Period already locked'
    );
  end if;

  -- Lock the period
  update accounting_periods
  set
    is_locked = true,
    locked_at = now(),
    locked_by = v_current_user_id::uuid
  where id = p_period_id;

  return jsonb_build_object(
    'success', true,
    'period_id', p_period_id
  );
end;
$$;

-- ============================================================================
-- UNLOCK PERIOD (Owner only)
-- ============================================================================

create or replace function unlock_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_period accounting_periods;
begin
  -- Get current user
  if auth.uid() is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Get period with lock
  select * into v_period
  from accounting_periods
  where id = p_period_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Period not found'
    );
  end if;

  -- Check membership and role (must be owner)
  if "current_role"() != 'owner' or current_org_id() != v_period.organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required to unlock periods'
    );
  end if;

  -- Check if already unlocked
  if not v_period.is_locked then
    return jsonb_build_object(
      'success', false,
      'error', 'Period already unlocked'
    );
  end if;

  -- Unlock the period
  update accounting_periods
  set
    is_locked = false,
    locked_at = null,
    locked_by = null
  where id = p_period_id;

  return jsonb_build_object(
    'success', true,
    'period_id', p_period_id
  );
end;
$$;

comment on function unlock_period is 'Unlocks an accounting period (owner only)';

-- ============================================================================
-- VOID BILL (Bookkeeper+, through journal reversal)
-- ============================================================================

create or replace function void_bill(p_bill_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_bill bills;
  v_reversal_result jsonb;
begin
  -- Auth check happens in reverse_journal

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

  -- Check membership
  if current_org_id() != v_bill.organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied'
    );
  end if;

  -- Check role (must be bookkeeper+)
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  -- Check if already void
  if v_bill.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill already void'
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

  -- Reverse the recognition journal
  v_reversal_result := reverse_journal(
    v_bill.recognition_journal_id,
    current_date,
    'Void bill: ' || v_bill.number
  );

  if not (v_reversal_result->>'success')::boolean then
    return v_reversal_result;
  end if;

  -- Mark bill as void
  update bills
  set status = 'Void'
  where id = p_bill_id;

  return jsonb_build_object(
    'success', true,
    'bill_id', p_bill_id,
    'reversal_result', v_reversal_result
  );
end;
$$;

-- ============================================================================
-- FIRST USER SETUP
-- ============================================================================

-- When the first user signs up, create an org and make them owner
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
as $$
declare
  v_org_id uuid;
  v_org_name text;
begin
  -- Check if user already has a membership
  if exists(select 1 from memberships where user_id = new.id) then
    return new;
  end if;

  -- Extract name from email or metadata
  v_org_name := coalesce(
    new.raw_user_meta_data->>'company_name',
    split_part(new.email, '@', 1) || '''s Organization'
  );

  -- Create organization
  insert into organizations (name, currency_code, timezone)
  values (v_org_name, 'USD', 'America/New_York')
  returning id into v_org_id;

  -- Add user as owner
  insert into memberships (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  return new;
end;
$$;

-- Trigger on auth.users insert
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

comment on function handle_new_user is 'Creates an organization and owner membership for the first user to sign up';
