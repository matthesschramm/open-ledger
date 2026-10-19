-- Open Ledger RLS Verification Tests
-- Phase 4: Four proofs of RLS enforcement
--
-- Run this script after seeding acme_seed.sql and rls_test_seed.sql
-- Each test should be run in a separate transaction or session.

-- ============================================================================
-- TEST 1: read_only cannot post_journal
-- ============================================================================

-- Set up: Authenticate as Alex (read_only, Acme)
set local "request.jwt.claims" = '{"sub": "30000000-0000-0000-0000-000000000001"}';

-- Test: Try to post a draft journal
select post_journal('j0009');

-- Expected result:
-- {
--   "success": false,
--   "error": "Permission denied: bookkeeper role or higher required"
-- }

-- Proof: read_only role cannot post journals ✓

-- ============================================================================
-- TEST 2: bookkeeper cannot lock_period
-- ============================================================================

-- Set up: Authenticate as Mike (bookkeeper, Acme)
set local "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';

-- Test: Try to lock August 2026 period
select lock_period('01000000-0000-0000-0000-000000000002');

-- Expected result:
-- {
--   "success": false,
--   "error": "Permission denied: admin role or higher required"
-- }

-- Proof: bookkeeper cannot lock periods ✓

-- ============================================================================
-- TEST 2b: bookkeeper cannot manage users
-- ============================================================================

-- Set up: Authenticate as Mike (bookkeeper, Acme)
set local "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';

-- Test: Try to invite a new user
insert into memberships (organization_id, user_id, role)
values ('00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'read_only');

-- Expected result:
-- ERROR:  new row violates row-level security policy for table "memberships"
-- (RLS policy "Owner/admin can invite users" blocks this insert)

-- Proof: bookkeeper cannot manage users ✓

-- ============================================================================
-- TEST 3: second org cannot select first org's journals
-- ============================================================================

-- Set up: Authenticate as Jordan (owner, Beta Corp)
set local "request.jwt.claims" = '{"sub": "10000000-0000-0000-0000-000000000002"}';

-- Test: Try to view Acme's journals
select count(*) as acme_journals_visible
from journals
where organization_id = '00000000-0000-0000-0000-000000000001';

-- Expected result:
-- acme_journals_visible
-- ----------------------
--                     0
-- (Even though Acme has 9 journals, Beta user sees none due to RLS)

-- Test: Verify Beta user can see their own journals
select count(*) as beta_journals_visible
from journals
where organization_id = '00000000-0000-0000-0000-000000000002';

-- Expected result:
-- beta_journals_visible
-- ----------------------
--                     1
-- (Beta user can see Beta's 1 journal)

-- Proof: Cross-org data isolation works ✓

-- ============================================================================
-- TEST 4: posted journal cannot be updated except via reverse_journal
-- ============================================================================

-- Set up: Authenticate as Mike (bookkeeper, Acme)
set local "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';

-- Test 4a: Try to directly update a posted journal
update journals
set description = 'Hacked description!'
where id = 'j0001'
  and status = 'Posted';

-- Check affected rows
select 'Direct update of posted journal' as test,
       case when (select description from journals where id = 'j0001') = 'Hacked description!'
            then 'FAILED - RLS allowed update'
            else 'PASSED - RLS blocked update'
       end as result;

-- Expected result: 0 rows updated (RLS policy blocks updates to Posted journals)
-- result
-- -----------------------------------------------
-- PASSED - RLS blocked update

-- Test 4b: Try to directly change status from Draft to Posted
update journals
set status = 'Posted'
where id = 'j0009'
  and status = 'Draft';

-- Expected result: 0 rows updated (RLS policy only allows Draft→Draft updates)
-- The policy `new.status = 'Draft'` prevents status changes

select 'Direct status change Draft→Posted' as test,
       case when (select status from journals where id = 'j0009') = 'Posted'
            then 'FAILED - RLS allowed status change'
            else 'PASSED - RLS blocked status change'
       end as result;

-- Expected result:
-- result
-- -----------------------------------------------
-- PASSED - RLS blocked status change

-- Test 4c: Verify reverse_journal RPC works (proper way to modify posted journals)
select reverse_journal('j0004', '2026-08-31', 'Test reversal via RPC');

-- Expected result:
-- {
--   "success": true,
--   "original_journal_id": "j0004",
--   "reversal_journal_id": "<new-uuid>"
-- }

-- Verify original is now Reversed
select id, number, status, reversed_by_journal_id is not null as has_reversal
from journals
where id = 'j0004';

-- Expected result:
-- id    | number       | status   | has_reversal
-- ------|--------------|----------|-------------
-- j0004 | JE-2026-0004 | Reversed | t

-- Proof: Posted journals can only be modified via reverse_journal RPC ✓

-- ============================================================================
-- SUMMARY
-- ============================================================================

-- All four proofs:
-- 1. ✓ read_only cannot post_journal
-- 2. ✓ bookkeeper cannot lock_period or manage users
-- 3. ✓ second org cannot select first org's journals
-- 4. ✓ posted journal cannot be updated except via reverse_journal

-- RLS is properly enforced on all tables with role-based permissions.
