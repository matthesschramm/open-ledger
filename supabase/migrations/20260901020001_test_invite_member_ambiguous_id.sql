-- Regression tests for invite_member ambiguous-id fix and existing-user attach.

do $$
declare
  v_org_id uuid;
  v_owner_id uuid := '00000000-0000-0000-0000-0000000000a1'::uuid;
  v_member_id uuid := '00000000-0000-0000-0000-0000000000a2'::uuid;
  v_result jsonb;
  v_invitation_id uuid;
  v_count int;
begin
  raise notice '========================================';
  raise notice 'INVITE MEMBER REGRESSION TESTS';
  raise notice '========================================';

  insert into organizations (name, currency_code)
  values ('Invite Regression Org', 'USD')
  returning id into v_org_id;

  insert into auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (v_owner_id, 'invite.owner@test.com', 'mock', now(), now(), now()),
    (v_member_id, 'invite.member@test.com', 'mock', now(), now(), now())
  on conflict (id) do update
    set email = excluded.email;

  delete from memberships where user_id in (v_owner_id, v_member_id);
  delete from invitations where organization_id = v_org_id;

  insert into memberships (organization_id, user_id, role)
  values (v_org_id, v_owner_id, 'owner');

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner_id::text, 'role', 'authenticated')::text,
    true
  );

  -- New email invite must succeed (this is the path that hit ambiguous id)
  v_result := invite_member('invite.new@test.com', 'bookkeeper');
  if coalesce(v_result->>'success', 'false') <> 'true' then
    raise exception '✗ FAIL: new invite failed: %', v_result;
  end if;

  select count(*) into v_count
  from invitations
  where organization_id = v_org_id
    and email = 'invite.new@test.com'
    and status = 'pending';
  if v_count <> 1 then
    raise exception '✗ FAIL: expected one pending invite, got %', v_count;
  end if;
  raise notice '✓ PASS: invite_member creates pending invite for new email';

  -- Existing auth user with no membership attaches immediately
  v_result := invite_member('invite.member@test.com', 'read_only');
  if coalesce(v_result->>'success', 'false') <> 'true' then
    raise exception '✗ FAIL: invite existing auth user failed: %', v_result;
  end if;

  select count(*) into v_count
  from memberships
  where organization_id = v_org_id
    and user_id = v_member_id
    and role = 'read_only';
  if v_count <> 1 then
    raise exception '✗ FAIL: existing auth user was not attached, count=%', v_count;
  end if;

  if exists (
    select 1 from invitations
    where organization_id = v_org_id
      and email = 'invite.member@test.com'
      and status = 'pending'
  ) then
    raise exception '✗ FAIL: invitation should be accepted after attach';
  end if;
  raise notice '✓ PASS: invite_member attaches existing auth users';

  -- Existing member cannot be invited again
  v_result := invite_member('invite.member@test.com', 'bookkeeper');
  if coalesce(v_result->>'success', 'true') = 'true' then
    raise exception '✗ FAIL: inviting an existing member should fail';
  end if;
  raise notice '✓ PASS: invite_member refuses existing members';

  -- Cleanup
  delete from invitations where organization_id = v_org_id;
  delete from memberships where organization_id = v_org_id;
  delete from organizations where id = v_org_id;
  delete from auth.users where id in (v_owner_id, v_member_id);

  raise notice '========================================';
  raise notice 'ALL INVITE MEMBER REGRESSION TESTS PASSED';
  raise notice '========================================';
end;
$$;
