-- invite_member joined memberships to auth.users and selected bare "id",
-- which is ambiguous and broke every invite.

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
  v_existing_user uuid;
begin
  if not has_role('owner') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: owner role required'
    );
  end if;

  v_organization_id := current_org_id();
  v_current_user_id := auth.uid();

  if p_email is null or trim(p_email) = '' or p_email !~ '^[^@]+@[^@]+\.[^@]+$' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invalid email address'
    );
  end if;

  p_email := lower(trim(p_email));

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

  select i.id into v_existing_invitation
  from invitations i
  where i.organization_id = v_organization_id
    and lower(i.email) = p_email
    and i.status = 'pending'
    and i.expires_at > now();

  if v_existing_invitation is not null then
    select u.id into v_existing_user
    from auth.users u
    where lower(u.email) = p_email;

    if v_existing_user is not null then
      perform apply_invitation_for_user(v_existing_user, p_email);
      return jsonb_build_object(
        'success', true,
        'invitation_id', v_existing_invitation,
        'attached', true
      );
    end if;

    return jsonb_build_object(
      'success', false,
      'error', 'An invitation has already been sent to this email'
    );
  end if;

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
  returning invitations.id into v_invitation_id;

  perform log_audit_event(
    'membership',
    v_invitation_id,
    'member_invited',
    jsonb_build_object(
      'email', p_email,
      'role', p_role
    )
  );

  select u.id into v_existing_user
  from auth.users u
  where lower(u.email) = p_email;

  if v_existing_user is not null then
    perform apply_invitation_for_user(v_existing_user, p_email);
  end if;

  return jsonb_build_object(
    'success', true,
    'invitation_id', v_invitation_id
  );
end;
$$;

grant execute on function invite_member(text, membership_role) to authenticated;
