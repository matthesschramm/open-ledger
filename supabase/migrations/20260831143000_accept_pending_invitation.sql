-- Attach invitees when they already have an auth user, not only on first insert.

create or replace function apply_invitation_for_user(p_user_id uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite invitations;
begin
  if p_user_id is null or p_email is null or trim(p_email) = '' then
    return null;
  end if;

  select *
  into v_invite
  from public.invitations
  where lower(email) = lower(trim(p_email))
    and status = 'pending'
    and expires_at > now()
  order by created_at desc
  limit 1;

  if not found then
    return null;
  end if;

  insert into public.memberships (organization_id, user_id, role)
  values (v_invite.organization_id, p_user_id, v_invite.role)
  on conflict (organization_id, user_id) do update
    set role = excluded.role;

  update public.invitations
  set status = 'accepted'
  where id = v_invite.id;

  if auth.uid() is not null then
    perform log_audit_event(
      'membership',
      v_invite.id,
      'member_joined',
      jsonb_build_object(
        'email', lower(trim(p_email)),
        'role', v_invite.role
      )
    );
  end if;

  return v_invite.id;
end;
$$;

revoke all on function apply_invitation_for_user(uuid, text) from public, anon, authenticated;
grant execute on function apply_invitation_for_user(uuid, text) to service_role;

create or replace function accept_pending_invitation()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text;
  v_invitation_id uuid;
begin
  if v_user_id is null then
    return jsonb_build_object('success', false, 'error', 'Not authenticated');
  end if;

  select email into v_email
  from auth.users
  where id = v_user_id;

  v_invitation_id := apply_invitation_for_user(v_user_id, v_email);

  if v_invitation_id is null then
    return jsonb_build_object('success', false, 'error', 'No pending invitation');
  end if;

  return jsonb_build_object('success', true, 'invitation_id', v_invitation_id);
end;
$$;

grant execute on function accept_pending_invitation() to authenticated;

comment on function accept_pending_invitation is
  'Adds the signed-in user to the organization they were invited to and marks the invitation accepted.';

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_org_name text;
begin
  if exists(select 1 from public.memberships where user_id = new.id) then
    return new;
  end if;

  if apply_invitation_for_user(new.id, new.email) is not null then
    return new;
  end if;

  v_org_name := coalesce(
    new.raw_user_meta_data->>'company_name',
    split_part(new.email, '@', 1) || '''s Organization'
  );

  insert into public.organizations (name, currency_code, timezone)
  values (v_org_name, 'USD', 'America/New_York')
  returning id into v_org_id;

  insert into public.memberships (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  insert into public.accounts (organization_id, code, name, type, category, is_header, is_cash, is_system, is_active) values
  (v_org_id, '1000', 'Cash', 'Asset', 'Cash', true, false, false, true),
  (v_org_id, '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1020', 'Savings / reserves', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1100', 'Accounts receivable', 'Asset', 'AR', false, false, true, true),
  (v_org_id, '1200', 'Prepaid expenses', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '1400', 'Due from parent', 'Asset', 'AR', false, false, false, true),
  (v_org_id, '1500', 'Computer and equipment', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '2000', 'Accounts payable', 'Liability', 'AP', false, false, true, true),
  (v_org_id, '2100', 'Accrued expenses', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '2200', 'Due to parent', 'Liability', 'AP', false, false, false, true),
  (v_org_id, '2300', 'Credit cards', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '3000', 'Common stock', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3100', 'Additional paid-in capital', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3200', 'Retained earnings', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3900', 'Opening balance equity', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '4000', 'Revenue', 'Revenue', 'Revenue', true, false, false, true),
  (v_org_id, '4010', 'Product / service revenue', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '4100', 'Other income', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '5000', 'Operating expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '5010', 'Contractors and professional', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5020', 'Legal and formation', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5030', 'Software and subscriptions', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5040', 'Banking and payments', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5050', 'Travel', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5060', 'Insurance', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5070', 'Payroll and benefits', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5080', 'Office and admin', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5090', 'Tax expense', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5110', 'Bad debt', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '6000', 'Other expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '6100', 'FX and rounding', 'Expense', 'Expense', false, false, false, true);

  return new;
end;
$$;

comment on function handle_new_user is
  'Joins a pending invitation when present; otherwise creates an org, owner membership, and US CoA';

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

comment on function invite_member is
  'Owner invites a member by email. Pending invites are attached immediately when that email already has an account.';
