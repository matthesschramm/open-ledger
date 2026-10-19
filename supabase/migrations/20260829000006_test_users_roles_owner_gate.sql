-- Open Ledger S2-3: Tests for Users, Roles, and Owner Gate
-- SQL tests for member management RPCs

-- ============================================================================
-- TEST SETUP
-- ============================================================================

do $$
declare
  v_org_id uuid;
  v_owner_id uuid := '00000000-0000-0000-0000-000000000001'::uuid;
  v_bookkeeper_id uuid := '00000000-0000-0000-0000-000000000002'::uuid;
  v_readonly_id uuid := '00000000-0000-0000-0000-000000000003'::uuid;
  v_owner_membership_id uuid;
  v_bookkeeper_membership_id uuid;
  v_readonly_membership_id uuid;
  v_result jsonb;
  v_invitation_count int;
  v_audit_count int;
  v_membership_count int;
  v_new_role membership_role;
begin
  raise notice '========================================';
  raise notice 'S2-3 USERS, ROLES, AND OWNER GATE TESTS';
  raise notice '========================================';

  -- Create test organization
  insert into organizations (name, currency_code)
  values ('Test Org S2-3', 'USD')
  returning id into v_org_id;

  -- Create test users in auth.users (mock)
  insert into auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (v_owner_id, 'owner@test.com', 'mock', now(), now(), now()),
    (v_bookkeeper_id, 'bookkeeper@test.com', 'mock', now(), now(), now()),
    (v_readonly_id, 'readonly@test.com', 'mock', now(), now(), now())
  on conflict (id) do nothing;

  -- Create memberships
  insert into memberships (id, organization_id, user_id, role)
  values
    (uuid_generate_v4(), v_org_id, v_owner_id, 'owner'),
    (uuid_generate_v4(), v_org_id, v_bookkeeper_id, 'bookkeeper'),
    (uuid_generate_v4(), v_org_id, v_readonly_id, 'read_only')
  returning id into v_owner_membership_id;

  select id into v_bookkeeper_membership_id
  from memberships
  where organization_id = v_org_id and user_id = v_bookkeeper_id;

  select id into v_readonly_membership_id
  from memberships
  where organization_id = v_org_id and user_id = v_readonly_id;

  -- ============================================================================
  -- TEST 1: Owner can invite a new member
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 1: Owner can invite a new member';
  
  -- Set context to owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text)::text, true);

  v_result := invite_member('newuser@test.com', 'bookkeeper');
  
  if v_result->>'success' = 'true' then
    select count(*) into v_invitation_count
    from invitations
    where organization_id = v_org_id
      and email = 'newuser@test.com'
      and role = 'bookkeeper'
      and status = 'pending';

    if v_invitation_count = 1 then
      raise notice '✓ PASS: Owner invited new member successfully';
    else
      raise exception '✗ FAIL: Invitation not created';
    end if;

    -- Check audit log
    select count(*) into v_audit_count
    from audit_events
    where organization_id = v_org_id
      and action = 'member_invited'
      and changes->>'email' = 'newuser@test.com'
      and changes->>'role' = 'bookkeeper';

    if v_audit_count = 1 then
      raise notice '✓ PASS: Invitation logged in audit trail';
    else
      raise exception '✗ FAIL: Invitation not logged in audit trail';
    end if;
  else
    raise exception '✗ FAIL: invite_member returned error: %', v_result->>'error';
  end if;

  -- ============================================================================
  -- TEST 2: Bookkeeper cannot invite members
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 2: Bookkeeper cannot invite members';
  
  -- Set context to bookkeeper
  perform set_config('request.jwt.claims', json_build_object('sub', v_bookkeeper_id::text)::text, true);

  v_result := invite_member('another@test.com', 'read_only');
  
  if v_result->>'success' = 'false' and v_result->>'error' like '%Permission denied%' then
    raise notice '✓ PASS: Bookkeeper blocked from inviting';
  else
    raise exception '✗ FAIL: Bookkeeper should not be able to invite';
  end if;

  -- ============================================================================
  -- TEST 3: Owner can change member role
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 3: Owner can change member role';
  
  -- Set context to owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text)::text, true);

  v_result := change_member_role(v_readonly_membership_id, 'bookkeeper');
  
  if v_result->>'success' = 'true' then
    select role into v_new_role
    from memberships
    where id = v_readonly_membership_id;

    if v_new_role = 'bookkeeper' then
      raise notice '✓ PASS: Role changed successfully';
    else
      raise exception '✗ FAIL: Role not updated in database';
    end if;

    -- Check audit log
    select count(*) into v_audit_count
    from audit_events
    where organization_id = v_org_id
      and action = 'member_role_changed'
      and changes->>'email' = 'readonly@test.com'
      and changes->>'old_role' = 'read_only'
      and changes->>'new_role' = 'bookkeeper';

    if v_audit_count = 1 then
      raise notice '✓ PASS: Role change logged in audit trail';
    else
      raise exception '✗ FAIL: Role change not logged in audit trail';
    end if;
  else
    raise exception '✗ FAIL: change_member_role returned error: %', v_result->>'error';
  end if;

  -- ============================================================================
  -- TEST 4: Cannot demote last owner
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 4: Cannot demote last owner';
  
  v_result := change_member_role(v_owner_membership_id, 'bookkeeper');
  
  if v_result->>'success' = 'false' and v_result->>'error' = 'At least one owner has to stay.' then
    raise notice '✓ PASS: Last owner cannot be demoted';
  else
    raise exception '✗ FAIL: Should block demoting last owner';
  end if;

  -- ============================================================================
  -- TEST 5: Owner can remove non-owner member
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 5: Owner can remove non-owner member';
  
  v_result := remove_member(v_bookkeeper_membership_id);
  
  if v_result->>'success' = 'true' then
    select count(*) into v_membership_count
    from memberships
    where id = v_bookkeeper_membership_id;

    if v_membership_count = 0 then
      raise notice '✓ PASS: Member removed successfully';
    else
      raise exception '✗ FAIL: Member not removed from database';
    end if;

    -- Check audit log
    select count(*) into v_audit_count
    from audit_events
    where organization_id = v_org_id
      and action = 'member_removed'
      and changes->>'email' = 'bookkeeper@test.com';

    if v_audit_count = 1 then
      raise notice '✓ PASS: Removal logged in audit trail';
    else
      raise exception '✗ FAIL: Removal not logged in audit trail';
    end if;
  else
    raise exception '✗ FAIL: remove_member returned error: %', v_result->>'error';
  end if;

  -- ============================================================================
  -- TEST 6: Cannot remove last owner
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 6: Cannot remove last owner';
  
  v_result := remove_member(v_owner_membership_id);
  
  if v_result->>'success' = 'false' and v_result->>'error' = 'At least one owner has to stay.' then
    raise notice '✓ PASS: Last owner cannot be removed';
  else
    raise exception '✗ FAIL: Should block removing last owner';
  end if;

  -- ============================================================================
  -- TEST 7: Removed member journals and audit rows remain
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 7: Removed member journals and audit rows remain';
  
  -- Create another bookkeeper and post a journal
  insert into auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000004'::uuid, 'temp@test.com', 'mock', now(), now(), now())
  on conflict (id) do nothing;

  insert into memberships (id, organization_id, user_id, role)
  values
    (uuid_generate_v4(), v_org_id, '00000000-0000-0000-0000-000000000004'::uuid, 'bookkeeper')
  returning id into v_bookkeeper_membership_id;

  -- Set context to temp bookkeeper
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000000004'::text)::text, true);

  -- Open a period first (as owner)
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text)::text, true);
  perform open_period(2026, 8);

  -- Create and post a journal as temp bookkeeper
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000000004'::text)::text, true);
  
  declare
    v_journal_id uuid;
    v_cash_account_id uuid;
    v_revenue_account_id uuid;
  begin
    -- Get accounts
    select id into v_cash_account_id
    from accounts
    where organization_id = v_org_id and code = '1000';
    
    select id into v_revenue_account_id
    from accounts
    where organization_id = v_org_id and code = '4000';

    -- Create journal
    insert into journals (organization_id, number, entry_date, description, status, source, created_by)
    values (v_org_id, 'TEST-001', '2026-08-15', 'Test journal', 'Draft', 'manual', '00000000-0000-0000-0000-000000000004'::uuid)
    returning id into v_journal_id;

    -- Add lines
    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents)
    values
      (v_org_id, v_journal_id, v_cash_account_id, 100000, 0),
      (v_org_id, v_journal_id, v_revenue_account_id, 0, 100000);

    -- Post journal
    perform post_journal(v_journal_id);

    -- Now remove the temp bookkeeper as owner
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text)::text, true);
    perform remove_member(v_bookkeeper_membership_id);

    -- Check that journal still exists
    if exists(select 1 from journals where id = v_journal_id) then
      raise notice '✓ PASS: Journal remains after member removal';
    else
      raise exception '✗ FAIL: Journal was deleted';
    end if;

    -- Check that audit events still exist
    if exists(select 1 from audit_events where organization_id = v_org_id and actor_id = '00000000-0000-0000-0000-000000000004'::uuid) then
      raise notice '✓ PASS: Audit events remain after member removal';
    else
      raise exception '✗ FAIL: Audit events were deleted';
    end if;
  end;

  -- ============================================================================
  -- TEST 8: Role change visible on next has_role() call
  -- ============================================================================

  raise notice '';
  raise notice 'TEST 8: Role change visible immediately in has_role()';
  
  -- Create another member
  insert into auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000005'::uuid, 'test5@test.com', 'mock', now(), now(), now())
  on conflict (id) do nothing;

  insert into memberships (id, organization_id, user_id, role)
  values
    (uuid_generate_v4(), v_org_id, '00000000-0000-0000-0000-000000000005'::uuid, 'read_only')
  returning id into v_readonly_membership_id;

  -- Set context to this user
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000000005'::text)::text, true);

  -- Check initial role
  if not has_role('bookkeeper') then
    raise notice '✓ PASS: Initially read_only cannot do bookkeeper actions';
  else
    raise exception '✗ FAIL: has_role should return false for read_only';
  end if;

  -- Change role as owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text)::text, true);
  perform change_member_role(v_readonly_membership_id, 'bookkeeper');

  -- Check role immediately as the user
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000000005'::text)::text, true);

  if has_role('bookkeeper') then
    raise notice '✓ PASS: Role change visible immediately in has_role()';
  else
    raise exception '✗ FAIL: has_role should return true after role change';
  end if;

  -- ============================================================================
  -- CLEANUP
  -- ============================================================================

  delete from audit_events where organization_id = v_org_id;
  delete from journal_lines where organization_id = v_org_id;
  delete from journals where organization_id = v_org_id;
  delete from accounting_periods where organization_id = v_org_id;
  delete from accounts where organization_id = v_org_id;
  delete from invitations where organization_id = v_org_id;
  delete from memberships where organization_id = v_org_id;
  delete from organizations where id = v_org_id;

  raise notice '';
  raise notice '========================================';
  raise notice 'ALL TESTS PASSED';
  raise notice '========================================';
end;
$$;
