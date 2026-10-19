-- Open Ledger S2-3: Users, Roles, and Owner Gate
-- Member invitation, role management, and removal with owner gate

-- ============================================================================
-- INVITATIONS TABLE
-- ============================================================================

create table invitations (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  email text not null,
  role membership_role not null default 'bookkeeper',
  status text not null default 'pending' check (status in ('pending', 'accepted', 'expired')),
  invited_by uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  unique(organization_id, email)
);

create index invitations_organization_id_idx on invitations(organization_id);
create index invitations_email_idx on invitations(email);
create index invitations_status_idx on invitations(status);

alter table invitations enable row level security;

-- Users can view invitations in their organization
create policy "Members can view org invitations"
  on invitations for select
  using (organization_id = current_org_id());

-- Owner can insert invitations
create policy "Owner can invite users"
  on invitations for insert
  with check (organization_id = current_org_id() and has_role('owner'));

-- Owner can update invitation status
create policy "Owner can update invitations"
  on invitations for update
  using (organization_id = current_org_id() and has_role('owner'));

-- ============================================================================
-- HELPER: Get user email by user_id
-- ============================================================================

create or replace function get_user_email(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select email
  from auth.users
  where id = p_user_id;
$$;

comment on function get_user_email is 'Returns the email for a given user_id from auth.users';

-- ============================================================================
-- RPC: Invite Member
-- ============================================================================

create or replace function invite_member(
  p_email text,
  p_role membership_role
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_current_user_id uuid;
  v_invitation_id uuid;
  v_existing_membership uuid;
  v_existing_invitation uuid;
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

  -- Validate email format (basic check)
  if p_email is null or trim(p_email) = '' or p_email !~ '^[^@]+@[^@]+\.[^@]+$' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invalid email address'
    );
  end if;

  -- Normalize email (lowercase)
  p_email := lower(trim(p_email));

  -- Check if user is already a member
  select m.id into v_existing_membership
  from memberships m
  join auth.users u on u.id = m.user_id
  where m.organization_id = v_organization_id
    and lower(u.email) = p_email;

  if v_existing_membership is not null then
    return jsonb_build_object(
      'success', false,
      'error', 'User is already a member of this organization'
    );
  end if;

  -- Check if there's already a pending invitation
  select id into v_existing_invitation
  from invitations
  where organization_id = v_organization_id
    and lower(email) = p_email
    and status = 'pending'
    and expires_at > now();

  if v_existing_invitation is not null then
    return jsonb_build_object(
      'success', false,
      'error', 'An invitation has already been sent to this email'
    );
  end if;

  -- Create invitation
  insert into invitations (
    organization_id,
    email,
    role,
    status,
    invited_by
  ) values (
    v_organization_id,
    p_email,
    p_role,
    'pending',
    v_current_user_id
  )
  on conflict (organization_id, email) 
  do update set
    role = p_role,
    status = 'pending',
    invited_by = v_current_user_id,
    expires_at = now() + interval '7 days',
    created_at = now()
  returning id into v_invitation_id;

  -- Log audit event
  perform log_audit_event(
    'membership',
    v_invitation_id,
    'member_invited',
    jsonb_build_object(
      'email', p_email,
      'role', p_role
    )
  );

  return jsonb_build_object(
    'success', true,
    'invitation_id', v_invitation_id
  );
end;
$$;

grant execute on function invite_member to authenticated;

comment on function invite_member is 'Owner invites a new member by email and role. Creates a pending invitation. Logs audit event.';

-- ============================================================================
-- RPC: Change Member Role
-- ============================================================================

create or replace function change_member_role(
  p_membership_id uuid,
  p_new_role membership_role
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_membership memberships;
  v_owner_count int;
  v_user_email text;
  v_old_role membership_role;
begin
  -- Check role
  if not has_role('owner') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required'
    );
  end if;

  v_organization_id := current_org_id();

  -- Get membership with lock
  select * into v_membership
  from memberships
  where id = p_membership_id
    and organization_id = v_organization_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Membership not found'
    );
  end if;

  v_old_role := v_membership.role;

  -- If demoting from owner to non-owner, check that there's at least one other owner
  if v_old_role = 'owner' and p_new_role != 'owner' then
    select count(*) into v_owner_count
    from memberships
    where organization_id = v_organization_id
      and role = 'owner';

    if v_owner_count <= 1 then
      return jsonb_build_object(
        'success', false,
        'error', 'At least one owner has to stay.'
      );
    end if;
  end if;

  -- If no change, return success early
  if v_old_role = p_new_role then
    return jsonb_build_object(
      'success', true,
      'changed', false
    );
  end if;

  -- Get user email
  v_user_email := get_user_email(v_membership.user_id);

  -- Update role
  update memberships
  set role = p_new_role,
      updated_at = now()
  where id = p_membership_id;

  -- Log audit event
  perform log_audit_event(
    'membership',
    p_membership_id,
    'member_role_changed',
    jsonb_build_object(
      'email', v_user_email,
      'old_role', v_old_role,
      'new_role', p_new_role
    )
  );

  return jsonb_build_object(
    'success', true,
    'changed', true
  );
end;
$$;

grant execute on function change_member_role to authenticated;

comment on function change_member_role is 'Owner changes a member role. Prevents demoting the last owner. Logs audit event.';

-- ============================================================================
-- RPC: Remove Member
-- ============================================================================

create or replace function remove_member(p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_membership memberships;
  v_owner_count int;
  v_user_email text;
begin
  -- Check role
  if not has_role('owner') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required'
    );
  end if;

  v_organization_id := current_org_id();

  -- Get membership with lock
  select * into v_membership
  from memberships
  where id = p_membership_id
    and organization_id = v_organization_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Membership not found'
    );
  end if;

  -- If removing an owner, check that there's at least one other owner
  if v_membership.role = 'owner' then
    select count(*) into v_owner_count
    from memberships
    where organization_id = v_organization_id
      and role = 'owner';

    if v_owner_count <= 1 then
      return jsonb_build_object(
        'success', false,
        'error', 'At least one owner has to stay.'
      );
    end if;
  end if;

  -- Get user email
  v_user_email := get_user_email(v_membership.user_id);

  -- Log audit event before deletion
  perform log_audit_event(
    'membership',
    p_membership_id,
    'member_removed',
    jsonb_build_object(
      'email', v_user_email,
      'role', v_membership.role
    )
  );

  -- Delete membership
  delete from memberships
  where id = p_membership_id;

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function remove_member to authenticated;

comment on function remove_member is 'Owner removes a member. Prevents removing the last owner. Logs audit event. Does not delete journals or audit rows.';

-- ============================================================================
-- UPDATE AUDIT LOG UI TO HANDLE MEMBER EVENTS
-- ============================================================================

-- No schema changes needed - member events are already logged to audit_events table
-- The UI will need to format these new action types: member_invited, member_role_changed, member_removed
