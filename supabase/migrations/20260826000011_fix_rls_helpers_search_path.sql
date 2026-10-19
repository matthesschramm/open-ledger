-- Fix RLS helper functions search_path for SECURITY DEFINER
-- Bug: current_org_id, current_role, and has_role are SECURITY DEFINER without search_path
-- This causes RLS policies using these functions to fail when memberships table isn't in search path
-- Fix: SET search_path = public AND qualify memberships with public.

-- Get current user's organization ID (from first membership found)
create or replace function current_org_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select organization_id
  from public.memberships
  where user_id = auth.uid()
  limit 1;
$$;

comment on function current_org_id is 'Returns the organization_id for the current authenticated user';

-- Get current user's role in their organization
create or replace function "current_role"()
returns membership_role
language sql
stable
security definer
set search_path = public
as $$
  select role
  from public.memberships
  where user_id = auth.uid()
    and organization_id = current_org_id()
  limit 1;
$$;

comment on function "current_role" is 'Returns the role (owner/admin/bookkeeper/read_only) for the current user';

-- Check if current user has a specific role or higher
create or replace function has_role(required_role membership_role)
returns boolean
language sql
stable
security definer
set search_path = public
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
