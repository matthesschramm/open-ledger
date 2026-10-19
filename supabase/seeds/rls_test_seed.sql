-- Open Ledger RLS Test Seed
-- Phase 4: Second test org + test users for RLS verification
--
-- This seed adds a second organization and test users with different roles
-- to prove RLS isolation and role enforcement.

begin;

-- ============================================================================
-- TEST ORGANIZATION 2: Beta Corp
-- ============================================================================

insert into organizations (id, name, currency_code, timezone, fiscal_year_end_month, fiscal_year_end_day)
values (
  '00000000-0000-0000-0000-000000000002',
  'Beta Corp',
  'USD',
  'America/New_York',
  12, -- December
  31  -- 31st
);

-- ============================================================================
-- TEST USERS (Mock auth.users entries for local testing)
-- ============================================================================

-- In production, these would be real auth.users rows created by Supabase Auth.
-- For local testing without real auth, we simulate user IDs.
--
-- Acme users:
-- - '10000000-0000-0000-0000-000000000001' = Sarah (owner)
-- - '20000000-0000-0000-0000-000000000001' = Mike (bookkeeper)
-- - '30000000-0000-0000-0000-000000000001' = Alex (read_only)
--
-- Beta users:
-- - '10000000-0000-0000-0000-000000000002' = Jordan (owner)
-- - '20000000-0000-0000-0000-000000000002' = Taylor (admin)

-- ============================================================================
-- MEMBERSHIPS: Acme Corp
-- ============================================================================

insert into memberships (id, organization_id, user_id, role) values
-- Sarah: Owner
('m-acme-sarah', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'owner'),
-- Mike: Bookkeeper
('m-acme-mike', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'bookkeeper'),
-- Alex: Read-only
('m-acme-alex', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'read_only');

-- ============================================================================
-- MEMBERSHIPS: Beta Corp
-- ============================================================================

insert into memberships (id, organization_id, user_id, role) values
-- Jordan: Owner
('m-beta-jordan', '00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'owner'),
-- Taylor: Admin
('m-beta-taylor', '00000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'admin');

-- ============================================================================
-- BETA CORP: Minimal CoA
-- ============================================================================

insert into accounts (id, organization_id, code, name, type, category, is_header, is_cash, is_system, is_active) values
-- 1000 Cash
('b-a1010', '00000000-0000-0000-0000-000000000002', '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
-- 2000 AP
('b-a2000', '00000000-0000-0000-0000-000000000002', '2000', 'Accounts payable', 'Liability', 'AP', false, false, true, true),
-- 3100 APIC
('b-a3100', '00000000-0000-0000-0000-000000000002', '3100', 'Additional paid-in capital', 'Equity', 'Equity', false, false, true, true),
-- 5000 Expense
('b-a5000', '00000000-0000-0000-0000-000000000002', '5000', 'Operating expenses', 'Expense', 'Expense', true, false, false, true),
('b-a5010', '00000000-0000-0000-0000-000000000002', '5010', 'Contractors and professional', 'Expense', 'Expense', false, false, false, true);

-- ============================================================================
-- BETA CORP: August 2026 period (open)
-- ============================================================================

insert into accounting_periods (
  id,
  organization_id,
  name,
  start_date,
  end_date,
  is_locked
) values (
  '02000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'August 2026',
  '2026-08-01',
  '2026-08-31',
  false
);

-- ============================================================================
-- BETA CORP: Parent funding journal (Dr 1010, Cr 3100) - POSTED
-- ============================================================================

insert into journals (
  id,
  organization_id,
  number,
  entry_date,
  description,
  status,
  source,
  created_by,
  posted_at,
  posted_by
) values (
  'j-beta-001',
  '00000000-0000-0000-0000-000000000002',
  'JE-BETA-0001',
  '2026-08-01',
  'Parent funding - Beta Corp',
  'Posted',
  'opening',
  '10000000-0000-0000-0000-000000000002',
  '2026-08-01 09:00:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000002'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000002', 'j-beta-001', 'b-a1010', 50000000, 0, 'Initial capital funding'),
('00000000-0000-0000-0000-000000000002', 'j-beta-001', 'b-a3100', 0, 50000000, null);

commit;

-- ============================================================================
-- RLS TEST QUERIES
-- ============================================================================

-- These queries verify RLS isolation and role enforcement.
-- Run these after seeding to prove:
-- 1. read_only cannot post_journal
-- 2. bookkeeper cannot lock_period or manage users
-- 3. second org cannot select first org's journals
-- 4. posted journal cannot be updated except via reverse_journal

-- TEST 1: read_only cannot post_journal
-- Expected: Permission denied error
-- Run as Alex (read_only, Acme):
-- SET LOCAL "request.jwt.claims" = '{"sub": "30000000-0000-0000-0000-000000000001"}';
-- SELECT post_journal('j0009');  -- Draft journal in Acme
-- Result should be: {"success": false, "error": "Permission denied: bookkeeper role or higher required"}

-- TEST 2: bookkeeper cannot lock_period
-- Expected: Permission denied error
-- Run as Mike (bookkeeper, Acme):
-- SET LOCAL "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';
-- SELECT lock_period('01000000-0000-0000-0000-000000000002');  -- August 2026 period
-- Result should be: {"success": false, "error": "Permission denied: admin role or higher required"}

-- TEST 3: bookkeeper cannot manage users (invite)
-- Expected: RLS policy blocks insert
-- Run as Mike (bookkeeper, Acme):
-- SET LOCAL "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';
-- INSERT INTO memberships (organization_id, user_id, role)
-- VALUES ('00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'read_only');
-- Result should be: RLS policy violation (new row violates row-level security policy)

-- TEST 4: second org cannot select first org's journals
-- Expected: Zero rows returned (RLS blocks cross-org access)
-- Run as Jordan (owner, Beta):
-- SET LOCAL "request.jwt.claims" = '{"sub": "10000000-0000-0000-0000-000000000002"}';
-- SELECT * FROM journals WHERE organization_id = '00000000-0000-0000-0000-000000000001';
-- Result should be: 0 rows (even though Acme has 9 journals, Beta user sees none)

-- TEST 5: posted journal cannot be updated directly
-- Expected: RLS policy blocks update
-- Run as Mike (bookkeeper, Acme):
-- SET LOCAL "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';
-- UPDATE journals SET description = 'Hacked!' WHERE id = 'j0001' AND status = 'Posted';
-- Result should be: 0 rows updated (RLS policy only allows Draft updates)

-- TEST 6: reverse_journal works for bookkeeper
-- Expected: Success
-- Run as Mike (bookkeeper, Acme):
-- SET LOCAL "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000001"}';
-- SELECT reverse_journal('j0007', '2026-08-31', 'Test reversal');
-- Result should be: {"success": true, "original_journal_id": "j0007", "reversal_journal_id": "..."}
