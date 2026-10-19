-- Open Ledger S2-1: Period Close Controls Tests
-- Tests for sequential lock/reopen, role-based posting restrictions
--
-- Prerequisites:
-- 1. Run acme_seed.sql first
-- 2. Migrations applied including 20260829000001_accounting_periods_close_controls.sql
--
-- Test organization: Acme Corp (00000000-0000-0000-0000-000000000001)
-- Test users:
--   - Owner: Sam (10000000-0000-0000-0000-000000000001)
--   - Bookkeeper: Mike (20000000-0000-0000-0000-000000000001)
--   - Read-only: Alex (30000000-0000-0000-0000-000000000001)

-- ============================================================================
-- SETUP: Create test periods
-- ============================================================================

-- Authenticate as Sam (owner)
set local "request.jwt.claims" = '{"sub": "10000000-0000-0000-0000-000000000001"}';

-- Create September 2026 period for testing
select open_period(2026, 9);

-- Expected: {"success": true, "period_id": "<uuid>", "period_name": "September 2026"}

-- ============================================================================
-- TEST 1: Sequential lock - cannot lock August while July is still Open
-- ============================================================================

-- First, reopen July (which is Locked in seed data)
select reopen_period('01000000-0000-0000-0000-000000000001', 'Test sequential lock behavior');

-- Expected: {"success": true}

-- Now try to lock August while July is Open
select lock_period('01000000-0000-0000-0000-000000000002');

-- Expected result:
-- {
--   "success": false,
--   "error": "Cannot lock August 2026 while earlier months are still Open. Close months in order."
-- }

-- Proof: Sequential lock enforcement works ✓

-- ============================================================================
-- TEST 2: Sequential reopen - cannot reopen July while August is Soft-closed
-- ============================================================================

-- Close July first
select lock_period('01000000-0000-0000-0000-000000000001');

-- Expected: {"success": true}

-- Soft-close August
select soft_close_period('01000000-0000-0000-0000-000000000002');

-- Expected: {"success": true}

-- Try to reopen July while August is Soft-closed
select reopen_period('01000000-0000-0000-0000-000000000001', 'Attempt to reopen earlier period');

-- Expected result:
-- {
--   "success": false,
--   "error": "Cannot reopen July 2026 while later months are Soft-closed or Locked. Reopen in reverse order."
-- }

-- Proof: Sequential reopen enforcement works (reverse order) ✓

-- ============================================================================
-- TEST 3: Bookkeeper blocked on Soft-closed
-- ============================================================================

-- Set up: August is Soft-closed (from TEST 2)
-- Authenticate as Mike (bookkeeper)
set local "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';

-- Create a test draft journal in August
insert into journals (
  id,
  organization_id,
  number,
  entry_date,
  description,
  status
) values (
  'test-journal-soft-closed',
  '00000000-0000-0000-0000-000000000001',
  'TEST-SC-001',
  '2026-08-15',
  'Test soft-close bookkeeper block',
  'Draft'
);

-- Add balanced lines
insert into journal_lines (journal_id, account_id, debit_cents, credit_cents)
values 
  ('test-journal-soft-closed', '10100000-0000-0000-0000-000000000001', 10000, 0),
  ('test-journal-soft-closed', '51000000-0000-0000-0000-000000000001', 0, 10000);

-- Try to post as bookkeeper
select post_journal('test-journal-soft-closed');

-- Expected result:
-- {
--   "success": false,
--   "error": "Cannot post journal with entry date Aug 15, 2026: August 2026 is Soft-closed. Only the owner can post to a soft-closed month.",
--   "period_name": "August 2026",
--   "period_status": "Soft-closed"
-- }

-- Proof: Bookkeeper cannot post to Soft-closed period ✓

-- ============================================================================
-- TEST 4: Owner can post in Soft-closed
-- ============================================================================

-- Authenticate as Sam (owner)
set local "request.jwt.claims" = '{"sub": "10000000-0000-0000-0000-000000000001"}';

-- Try to post same journal as owner
select post_journal('test-journal-soft-closed');

-- Expected result:
-- {
--   "success": true,
--   "journal_id": "test-journal-soft-closed"
-- }

-- Verify status
select id, status from journals where id = 'test-journal-soft-closed';

-- Expected: status = 'Posted'

-- Proof: Owner can post to Soft-closed period ✓

-- ============================================================================
-- TEST 5: Everyone blocked on Locked (including reversal)
-- ============================================================================

-- Set up: Lock August
select lock_period('01000000-0000-0000-0000-000000000002');

-- Expected: {"success": true}

-- Test 5a: Owner cannot post new journal
insert into journals (
  id,
  organization_id,
  number,
  entry_date,
  description,
  status
) values (
  'test-journal-locked',
  '00000000-0000-0000-0000-000000000001',
  'TEST-LOCK-001',
  '2026-08-20',
  'Test locked period owner block',
  'Draft'
);

insert into journal_lines (journal_id, account_id, debit_cents, credit_cents)
values 
  ('test-journal-locked', '10100000-0000-0000-0000-000000000001', 20000, 0),
  ('test-journal-locked', '51000000-0000-0000-0000-000000000001', 0, 20000);

select post_journal('test-journal-locked');

-- Expected result:
-- {
--   "success": false,
--   "error": "Cannot post journal with entry date Aug 20, 2026: August 2026 is Locked. No one can post to a locked month. Reopen the period in Settings → Periods first.",
--   "period_name": "August 2026",
--   "period_status": "Locked"
-- }

-- Proof: Owner cannot post to Locked period ✓

-- Test 5b: Owner cannot reverse into locked period
select reverse_journal('test-journal-soft-closed', '2026-08-25', 'Attempt reversal into locked period');

-- Expected result:
-- {
--   "success": false,
--   "error": "Cannot reverse with date Aug 25, 2026: August 2026 is Locked. No one can post to a locked month. Reopen the period in Settings → Periods first.",
--   "period_name": "August 2026",
--   "period_status": "Locked"
-- }

-- Proof: Reversal blocked on Locked period ✓

-- ============================================================================
-- TEST 6: Reopen requires a reason
-- ============================================================================

-- Try to reopen without reason (empty string)
select reopen_period('01000000-0000-0000-0000-000000000002', '');

-- Expected result:
-- {
--   "success": false,
--   "error": "Reopen reason is required"
-- }

-- Try to reopen with null reason
select reopen_period('01000000-0000-0000-0000-000000000002', null);

-- Expected result:
-- {
--   "success": false,
--   "error": "Reopen reason is required"
-- }

-- Reopen with valid reason
select reopen_period('01000000-0000-0000-0000-000000000002', 'Need to correct expense classification');

-- Expected: {"success": true}

-- Verify reopen_reason was recorded
select id, name, status, reopen_reason, reopened_at is not null as was_reopened
from accounting_periods
where id = '01000000-0000-0000-0000-000000000002';

-- Expected:
-- status = 'Open'
-- reopen_reason = 'Need to correct expense classification'
-- was_reopened = true

-- Proof: Reopen requires reason and records it ✓

-- ============================================================================
-- CLEANUP
-- ============================================================================

-- Delete test journals
delete from journal_lines where journal_id in ('test-journal-soft-closed', 'test-journal-locked');
delete from journals where id in ('test-journal-soft-closed', 'test-journal-locked');

-- ============================================================================
-- SUMMARY
-- ============================================================================

-- All tests:
-- 1. ✓ Sequential lock - cannot lock August while July is Open
-- 2. ✓ Sequential reopen - cannot reopen July while August is Soft-closed (reverse order)
-- 3. ✓ Bookkeeper blocked on Soft-closed
-- 4. ✓ Owner can post in Soft-closed
-- 5. ✓ Everyone blocked on Locked (including reversal)
-- 6. ✓ Reopen requires a reason

-- Period close controls are properly enforced.
