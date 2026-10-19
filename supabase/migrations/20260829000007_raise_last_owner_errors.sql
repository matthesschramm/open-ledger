-- Open Ledger S2-3: Belt-and-suspenders for last owner errors
-- Add RAISE EXCEPTION to change_member_role and remove_member so PostgREST
-- surfaces the error in error.message (in addition to jsonb response)

-- ============================================================================
-- UPDATE CHANGE_MEMBER_ROLE TO RAISE EXCEPTION
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
    raise exception 'Permission denied: owner role required';
  end if;

  v_organization_id := current_org_id();

  -- Get membership with lock
  select * into v_membership
  from memberships
  where id = p_membership_id
    and organization_id = v_organization_id
  for update;

  if not found then
    raise exception 'Membership not found';
  end if;

  v_old_role := v_membership.role;

  -- If demoting from owner to non-owner, check that there's at least one other owner
  if v_old_role = 'owner' and p_new_role != 'owner' then
    select count(*) into v_owner_count
    from memberships
    where organization_id = v_organization_id
      and role = 'owner';

    if v_owner_count <= 1 then
      raise exception 'At least one owner has to stay.';
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

comment on function change_member_role is 'Owner changes a member role. Prevents demoting the last owner. Raises exception and returns jsonb error. Logs audit event.';

-- ============================================================================
-- UPDATE REMOVE_MEMBER TO RAISE EXCEPTION
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
    raise exception 'Permission denied: owner role required';
  end if;

  v_organization_id := current_org_id();

  -- Get membership with lock
  select * into v_membership
  from memberships
  where id = p_membership_id
    and organization_id = v_organization_id
  for update;

  if not found then
    raise exception 'Membership not found';
  end if;

  -- If removing an owner, check that there's at least one other owner
  if v_membership.role = 'owner' then
    select count(*) into v_owner_count
    from memberships
    where organization_id = v_organization_id
      and role = 'owner';

    if v_owner_count <= 1 then
      raise exception 'At least one owner has to stay.';
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

comment on function remove_member is 'Owner removes a member. Prevents removing the last owner. Raises exception and returns jsonb error. Logs audit event. Does not delete journals or audit rows.';
