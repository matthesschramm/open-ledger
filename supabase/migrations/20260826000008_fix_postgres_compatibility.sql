-- Open Ledger Postgres Compatibility Fixes
-- Phase 8: Fix SQL that fails on real Postgres
-- This migration is idempotent and safe to run on databases that already applied the original migrations
-- or databases that already have these fixes applied.
--
-- Fixes three issues:
-- 1. current_role is a reserved keyword - quote the function name
-- 2. RLS policies cannot reference NEW in USING clause - split into USING + WITH CHECK
-- 3. audit_events.actor_id is uuid - compare with auth.uid() as uuid, not text

-- ============================================================================
-- FIX 1: Quote current_role function (reserved keyword)
-- ============================================================================

-- Recreate the helper function with quoted name
create or replace function "current_role"()
returns membership_role
language sql
stable
security definer
as $$
  select role
  from memberships
  where user_id = auth.uid()
    and organization_id = current_org_id()
  limit 1;
$$;

comment on function "current_role" is 'Returns the role (owner/admin/bookkeeper/read_only) for the current user';

-- Recreate has_role to call quoted current_role
create or replace function has_role(required_role membership_role)
returns boolean
language sql
stable
security definer
as $$
  select case required_role
    when 'read_only' then "current_role"() in ('read_only', 'bookkeeper', 'admin', 'owner')
    when 'bookkeeper' then "current_role"() in ('bookkeeper', 'admin', 'owner')
    when 'admin' then "current_role"() in ('admin', 'owner')
    when 'owner' then "current_role"() = 'owner'
    else false
  end;
$$;

comment on function has_role is 'Check if current user has the required role or higher in the hierarchy';

-- ============================================================================
-- FIX 2: RLS Policies - Split USING and WITH CHECK (cannot use NEW in USING)
-- ============================================================================

-- Fix memberships UPDATE policy: cannot remove last owner
drop policy if exists "Owner/admin can update roles" on memberships;
create policy "Owner/admin can update roles"
  on memberships for update
  using (
    organization_id = current_org_id()
    and has_role('admin')
  )
  with check (
    organization_id = current_org_id()
    and has_role('admin')
    -- Cannot remove the last owner: either there are other owners, or new role is owner
    and (
      (select count(*) from memberships m where m.organization_id = organization_id and m.role = 'owner' and m.id != id) > 0
      or role = 'owner'
    )
  );

-- Fix journals UPDATE policy: only draft journals, must remain draft
drop policy if exists "Bookkeeper+ can update draft journals" on journals;
create policy "Bookkeeper+ can update draft journals"
  on journals for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  )
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  );

-- ============================================================================
-- FIX 3: audit_events.actor_id is uuid - compare as uuid, not text
-- ============================================================================

drop policy if exists "Bookkeeper can view own audit events" on audit_events;
create policy "Bookkeeper can view own audit events"
  on audit_events for select
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and actor_id = auth.uid()
  );

-- ============================================================================
-- FIX 4: Update unlock_period RPC to call quoted current_role
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
