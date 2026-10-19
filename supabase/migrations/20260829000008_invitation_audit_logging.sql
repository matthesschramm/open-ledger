-- Open Ledger S2-3: Audit logging for invitation mutations
-- Add RPCs for invitation role change and removal that write audit events

-- ============================================================================
-- RPC: Change Invitation Role
-- ============================================================================

create or replace function change_invitation_role(
  p_invitation_id uuid,
  p_new_role membership_role
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_invitation invitations;
  v_old_role membership_role;
begin
  -- Check role
  if not has_role('owner') then
    raise exception 'Permission denied: owner role required';
  end if;

  v_organization_id := current_org_id();

  -- Get invitation with lock
  select * into v_invitation
  from invitations
  where id = p_invitation_id
    and organization_id = v_organization_id
    and status = 'pending'
  for update;

  if not found then
    raise exception 'Invitation not found';
  end if;

  v_old_role := v_invitation.role;

  -- If no change, return success early
  if v_old_role = p_new_role then
    return jsonb_build_object(
      'success', true,
      'changed', false
    );
  end if;

  -- Update role
  update invitations
  set role = p_new_role
  where id = p_invitation_id;

  -- Log audit event
  perform log_audit_event(
    'membership',
    p_invitation_id,
    'member_role_changed',
    jsonb_build_object(
      'email', v_invitation.email,
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

grant execute on function change_invitation_role to authenticated;

comment on function change_invitation_role is 'Owner changes an invited person role. Logs audit event with email and roles.';

-- ============================================================================
-- RPC: Remove Invitation
-- ============================================================================

create or replace function remove_invitation(p_invitation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_invitation invitations;
begin
  -- Check role
  if not has_role('owner') then
    raise exception 'Permission denied: owner role required';
  end if;

  v_organization_id := current_org_id();

  -- Get invitation with lock
  select * into v_invitation
  from invitations
  where id = p_invitation_id
    and organization_id = v_organization_id
  for update;

  if not found then
    raise exception 'Invitation not found';
  end if;

  -- Log audit event before deletion
  perform log_audit_event(
    'membership',
    p_invitation_id,
    'member_removed',
    jsonb_build_object(
      'email', v_invitation.email,
      'role', v_invitation.role
    )
  );

  -- Delete invitation
  delete from invitations
  where id = p_invitation_id;

  return jsonb_build_object(
    'success', true
  );
end;
$$;

grant execute on function remove_invitation to authenticated;

comment on function remove_invitation is 'Owner removes an invitation. Logs audit event with email and role.';

-- ============================================================================
-- ADD DELETE RLS POLICY FOR INVITATIONS
-- ============================================================================

-- Owner can delete invitations
create policy "Owner can delete invitations"
  on invitations for delete
  using (organization_id = current_org_id() and has_role('owner'));
