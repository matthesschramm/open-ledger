-- Open Ledger S2-2: Audit Trail
-- Add audit event logging to period management and journal RPCs

-- ============================================================================
-- HELPER FUNCTION: Log Audit Event
-- ============================================================================

create or replace function log_audit_event(
  p_entity_type text,
  p_entity_id uuid,
  p_action text,
  p_changes jsonb default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_actor_id uuid;
  v_actor_email text;
  v_changes_with_email jsonb;
begin
  v_organization_id := current_org_id();
  v_actor_id := auth.uid();
  
  -- Look up actor email from auth.users
  select email into v_actor_email
  from auth.users
  where id = v_actor_id;
  
  -- Merge actor_email into changes
  v_changes_with_email := coalesce(p_changes, '{}'::jsonb) || jsonb_build_object('actor_email', v_actor_email);
  
  insert into audit_events (
    organization_id,
    entity_type,
    entity_id,
    action,
    actor_id,
    changes
  ) values (
    v_organization_id,
    p_entity_type,
    p_entity_id,
    p_action,
    v_actor_id,
    v_changes_with_email
  );
end;
$$;

-- Only SECURITY DEFINER RPCs can log events - revoke from clients
revoke execute on function log_audit_event from public;
revoke execute on function log_audit_event from authenticated;

comment on function log_audit_event is 'Logs an audit event for the current organization and user. Stamps actor_email at write time. Only callable from SECURITY DEFINER RPCs.';

-- ============================================================================
-- UPDATE OPEN_PERIOD TO LOG AUDIT EVENTS
-- ============================================================================

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
  
  -- Log audit event
  perform log_audit_event(
    'accounting_period',
    v_period_id,
    'period_opened',
    jsonb_build_object(
      'period_name', v_period_name,
      'start_date', v_start_date,
      'end_date', v_end_date
    )
  );
  
  return jsonb_build_object(
    'success', true,
    'period_id', v_period_id,
    'period_name', v_period_name
  );
end;
$$;

grant execute on function open_period to authenticated;

-- ============================================================================
-- UPDATE SOFT_CLOSE_PERIOD TO LOG AUDIT EVENTS
-- ============================================================================

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

  -- Log audit event
  perform log_audit_event(
    'accounting_period',
    p_period_id,
    'period_soft_closed',
    jsonb_build_object(
      'period_name', v_period.name
    )
  );

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function soft_close_period to authenticated;

-- ============================================================================
-- UPDATE LOCK_PERIOD TO LOG AUDIT EVENTS
-- ============================================================================

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

  -- Log audit event
  perform log_audit_event(
    'accounting_period',
    p_period_id,
    'period_locked',
    jsonb_build_object(
      'period_name', v_period.name
    )
  );

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function lock_period to authenticated;

-- ============================================================================
-- UPDATE REOPEN_PERIOD TO LOG AUDIT EVENTS
-- ============================================================================

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

  -- Log audit event
  perform log_audit_event(
    'accounting_period',
    p_period_id,
    'period_reopened',
    jsonb_build_object(
      'period_name', v_period.name,
      'reopen_reason', p_reason
    )
  );

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function reopen_period to authenticated;

-- ============================================================================
-- UPDATE POST_JOURNAL TO LOG AUDIT EVENTS
-- ============================================================================

-- Note: post_journal is already updated in S2-1, so we need to extend it
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
  v_current_user_id uuid;
  v_current_role membership_role;
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

  -- Log audit event
  perform log_audit_event(
    'journal',
    p_journal_id,
    'journal_posted',
    jsonb_build_object(
      'journal_number', v_journal.number,
      'entry_date', v_journal.entry_date,
      'description', v_journal.description,
      'source', v_journal.source
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_id', p_journal_id
  );
end;
$$;

grant execute on function post_journal to authenticated;

-- ============================================================================
-- UPDATE REVERSE_JOURNAL TO LOG AUDIT EVENTS
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
  v_current_user_id uuid;
  v_current_role membership_role;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
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
    source,
    posted_at,
    posted_by,
    created_by,
    reverses_journal_id
  ) values (
    v_organization_id,
    v_reversal_number,
    p_reversal_date,
    v_reversal_description,
    'Posted',
    'reversal',
    now(),
    v_current_user_id,
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
      v_line.credit_cents,  -- Swap
      v_line.debit_cents,   -- Swap
      v_line.memo
    );
  end loop;

  -- Mark original journal as reversed
  update journals
  set
    status = 'Reversed',
    reversed_by_journal_id = v_reversal_journal_id
  where id = p_journal_id;

  -- Log audit event for the reversal
  perform log_audit_event(
    'journal',
    v_reversal_journal_id,
    'journal_posted',
    jsonb_build_object(
      'journal_number', v_reversal_number,
      'entry_date', p_reversal_date,
      'description', v_reversal_description,
      'source', 'reversal',
      'reverses_journal_id', p_journal_id,
      'reverses_journal_number', v_journal.number
    )
  );

  return jsonb_build_object(
    'success', true,
    'reversal_journal_id', v_reversal_journal_id
  );
end;
$$;

grant execute on function reverse_journal to authenticated;

comment on function post_journal is 'Posts a journal entry after validating balance, lines, header accounts, and period status with role enforcement. Logs audit event.';
comment on function reverse_journal is 'Reverses a posted journal, checking period status with role enforcement for reversal date. Logs audit event.';

-- ============================================================================
-- RLS POLICY UPDATES FOR READ_ONLY ACCESS
-- ============================================================================

-- Add read_only access to audit events (can view all in their organization)
create policy "Read-only can view all audit events"
  on audit_events for select
  using (
    organization_id = current_org_id()
    and has_role('read_only')
  );
