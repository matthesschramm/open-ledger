-- Open Ledger S2-1: Accounting Periods and Close Controls
-- Extends accounting_periods with soft-close state and sequential lock/reopen

-- ============================================================================
-- SCHEMA EXTENSION
-- ============================================================================

-- Add period status enum
create type period_status as enum ('Open', 'Soft-closed', 'Locked');

-- Add new columns to accounting_periods
alter table accounting_periods
  add column status period_status not null default 'Open',
  add column reopen_reason text,
  add column reopened_at timestamptz,
  add column reopened_by uuid;

-- Migrate existing data: is_locked true → 'Locked', false → 'Open'
update accounting_periods
set status = case
  when is_locked then 'Locked'::period_status
  else 'Open'::period_status
end;

-- We keep is_locked for backward compatibility but will use status going forward
comment on column accounting_periods.is_locked is 'Deprecated: use status column instead';

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Check if user can post to a period (considering role and period status)
create or replace function can_post_to_period(
  p_organization_id uuid,
  p_date date,
  p_user_role membership_role
)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when not exists (
      select 1 from accounting_periods
      where organization_id = p_organization_id
        and p_date between start_date and end_date
    ) then true  -- No period defined = allow
    when exists (
      select 1 from accounting_periods
      where organization_id = p_organization_id
        and p_date between start_date and end_date
        and status = 'Open'
    ) then true  -- Open period = allow for bookkeeper+
    when exists (
      select 1 from accounting_periods
      where organization_id = p_organization_id
        and p_date between start_date and end_date
        and status = 'Soft-closed'
    ) then p_user_role = 'owner'  -- Soft-closed = owner only
    else false  -- Locked = nobody
  end;
$$;

grant execute on function can_post_to_period to authenticated, service_role;

-- Get period status details for error messages
create or replace function get_period_status_info(
  p_organization_id uuid,
  p_date date
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'period_name', name,
    'status', status::text,
    'start_date', start_date,
    'end_date', end_date
  )
  from accounting_periods
  where organization_id = p_organization_id
    and p_date between start_date and end_date
  limit 1;
$$;

grant execute on function get_period_status_info to authenticated, service_role;

-- ============================================================================
-- PERIOD MANAGEMENT RPCs
-- ============================================================================

-- Open a new period (owner only)
create or replace function open_period(
  p_year int,
  p_month int
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_start_date date;
  v_end_date date;
  v_period_name text;
  v_period_id uuid;
  v_month_name text;
begin
  -- Check role
  if not has_role('owner') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required'
    );
  end if;

  v_organization_id := current_org_id();
  
  -- Calculate dates
  v_start_date := make_date(p_year, p_month, 1);
  v_end_date := (v_start_date + interval '1 month' - interval '1 day')::date;
  
  -- Check if period already exists
  if exists (
    select 1 from accounting_periods
    where organization_id = v_organization_id
      and start_date = v_start_date
  ) then
    return jsonb_build_object(
      'success', false,
      'error', 'Period already exists for this month'
    );
  end if;
  
  -- Generate period name (e.g., "August 2026")
  v_month_name := to_char(v_start_date, 'Month');
  v_period_name := trim(v_month_name) || ' ' || p_year::text;
  
  -- Create period
  insert into accounting_periods (
    organization_id,
    name,
    start_date,
    end_date,
    status,
    is_locked
  ) values (
    v_organization_id,
    v_period_name,
    v_start_date,
    v_end_date,
    'Open',
    false
  )
  returning id into v_period_id;
  
  return jsonb_build_object(
    'success', true,
    'period_id', v_period_id,
    'period_name', v_period_name
  );
end;
$$;

grant execute on function open_period to authenticated;

-- Soft-close a period (owner only, sequential)
create or replace function soft_close_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_period accounting_periods;
  v_organization_id uuid;
  v_earlier_open_count int;
begin
  -- Check role
  if not has_role('owner') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required'
    );
  end if;

  v_organization_id := current_org_id();

  -- Get period
  select * into v_period
  from accounting_periods
  where id = p_period_id
    and organization_id = v_organization_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Period not found'
    );
  end if;

  -- Check current status
  if v_period.status != 'Open' then
    return jsonb_build_object(
      'success', false,
      'error', 'Period must be Open to soft-close'
    );
  end if;

  -- Check sequential order: no earlier periods should be Open
  select count(*) into v_earlier_open_count
  from accounting_periods
  where organization_id = v_organization_id
    and end_date < v_period.start_date
    and status = 'Open';

  if v_earlier_open_count > 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot soft-close ' || v_period.name || ' while earlier months are still Open. Close months in order.'
    );
  end if;

  -- Soft-close the period
  update accounting_periods
  set status = 'Soft-closed',
      updated_at = now()
  where id = p_period_id;

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function soft_close_period to authenticated;

-- Lock a period (owner only, sequential, requires soft-closed or open)
create or replace function lock_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_period accounting_periods;
  v_organization_id uuid;
  v_earlier_open_count int;
  v_current_user_id uuid;
begin
  -- Check role
  if not has_role('owner') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required'
    );
  end if;

  v_organization_id := current_org_id();
  v_current_user_id := auth.uid();

  -- Get period
  select * into v_period
  from accounting_periods
  where id = p_period_id
    and organization_id = v_organization_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Period not found'
    );
  end if;

  -- Check current status
  if v_period.status = 'Locked' then
    return jsonb_build_object(
      'success', false,
      'error', 'Period is already locked'
    );
  end if;

  -- Check sequential order: no earlier periods should be Open
  select count(*) into v_earlier_open_count
  from accounting_periods
  where organization_id = v_organization_id
    and end_date < v_period.start_date
    and status = 'Open';

  if v_earlier_open_count > 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot lock ' || v_period.name || ' while earlier months are still Open. Close months in order.'
    );
  end if;

  -- Lock the period
  update accounting_periods
  set status = 'Locked',
      is_locked = true,
      locked_at = now(),
      locked_by = v_current_user_id,
      updated_at = now()
  where id = p_period_id;

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function lock_period to authenticated;

-- Reopen a period (owner only, reverse sequential, requires reason)
create or replace function reopen_period(
  p_period_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_period accounting_periods;
  v_organization_id uuid;
  v_later_closed_count int;
  v_current_user_id uuid;
begin
  -- Check role
  if not has_role('owner') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required'
    );
  end if;

  -- Validate reason
  if p_reason is null or trim(p_reason) = '' then
    return jsonb_build_object(
      'success', false,
      'error', 'Reopen reason is required'
    );
  end if;

  v_organization_id := current_org_id();
  v_current_user_id := auth.uid();

  -- Get period
  select * into v_period
  from accounting_periods
  where id = p_period_id
    and organization_id = v_organization_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Period not found'
    );
  end if;

  -- Check current status
  if v_period.status = 'Open' then
    return jsonb_build_object(
      'success', false,
      'error', 'Period is already open'
    );
  end if;

  -- Check reverse sequential order: no later periods should be Soft-closed or Locked
  select count(*) into v_later_closed_count
  from accounting_periods
  where organization_id = v_organization_id
    and start_date > v_period.end_date
    and status in ('Soft-closed', 'Locked');

  if v_later_closed_count > 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot reopen ' || v_period.name || ' while later months are Soft-closed or Locked. Reopen in reverse order.'
    );
  end if;

  -- Reopen the period
  update accounting_periods
  set status = 'Open',
      is_locked = false,
      reopen_reason = p_reason,
      reopened_at = now(),
      reopened_by = v_current_user_id,
      updated_at = now()
  where id = p_period_id;

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function reopen_period to authenticated;

-- Update the legacy unlock_period to use reopen_period
create or replace function unlock_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- Legacy function: redirect to reopen_period with default reason
  return reopen_period(p_period_id, 'Unlocked via legacy function');
end;
$$;

grant execute on function unlock_period to authenticated;

-- ============================================================================
-- UPDATE POST_JOURNAL TO USE NEW PERIOD CHECKS
-- ============================================================================

create or replace function post_journal(p_journal_id uuid)
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
  v_organization_id uuid;
  v_current_user_id text;
  v_current_role membership_role;
  v_can_post boolean;
  v_period_info jsonb;
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

  v_current_role := "current_role"();

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

  -- Sum debits and credits
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

  -- Check period status with role
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

    -- Build detailed error message
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot post journal with entry date %s: %s is %s. %s',
        to_char(v_journal.entry_date, 'Mon DD, YYYY'),
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

  -- Post the journal
  update journals
  set
    status = 'Posted',
    posted_at = now(),
    posted_by = v_current_user_id
  where id = p_journal_id;

  return jsonb_build_object(
    'success', true,
    'journal_id', p_journal_id
  );
end;
$$;

grant execute on function post_journal to authenticated;

-- ============================================================================
-- UPDATE REVERSE_JOURNAL TO USE NEW PERIOD CHECKS
-- ============================================================================

create or replace function reverse_journal(
  p_journal_id uuid,
  p_reversal_date date,
  p_reversal_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_journal journals;
  v_reversal_journal_id uuid;
  v_reversal_number text;
  v_reversal_description text;
  v_line record;
  v_organization_id uuid;
  v_current_user_id text;
  v_current_role membership_role;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid()::text;
  v_current_role := "current_role"();

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

  v_organization_id := v_journal.organization_id;

  -- Check period status for reversal date
  v_can_post := can_post_to_period(
    v_organization_id,
    p_reversal_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_reversal_date);
    
    if v_period_info is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Cannot post reversal to this date'
      );
    end if;

    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot reverse with date %s: %s is %s. %s',
        to_char(p_reversal_date, 'Mon DD, YYYY'),
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
    posted_at,
    posted_by,
    reverses_journal_id
  ) values (
    v_organization_id,
    v_reversal_number,
    p_reversal_date,
    v_reversal_description,
    'Posted',
    now(),
    v_current_user_id,
    p_journal_id
  )
  returning id into v_reversal_journal_id;

  -- Copy lines with reversed amounts
  for v_line in
    select * from journal_lines
    where journal_id = p_journal_id
  loop
    insert into journal_lines (
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      description
    ) values (
      v_reversal_journal_id,
      v_line.account_id,
      v_line.credit_cents,  -- Swap
      v_line.debit_cents,   -- Swap
      v_line.description
    );
  end loop;

  -- Mark original journal as reversed
  update journals
  set
    status = 'Reversed',
    reversed_by_journal_id = v_reversal_journal_id
  where id = p_journal_id;

  return jsonb_build_object(
    'success', true,
    'reversal_journal_id', v_reversal_journal_id
  );
end;
$$;

grant execute on function reverse_journal to authenticated;

comment on function post_journal is 'Posts a journal entry after validating balance, lines, header accounts, and period status with role enforcement';
comment on function reverse_journal is 'Reverses a posted journal, checking period status with role enforcement for reversal date';
