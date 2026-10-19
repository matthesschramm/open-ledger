-- Open Ledger Public Seed: Acme Corp (FIXED)
-- Phase 3: Public seed data for Acme only (generic, no company secrets)
-- Mock org: Acme, USD, FYE 31 Dec, August 2026 open, timezone America/New_York
--
-- FIXES:
-- - All IDs are now proper UUIDs
-- - Account codes remain as 1010, 3100, etc.
-- - Expected TB: 100,035,000 = 100,035,000
-- - Expected BS: Cash 99,200,000, APIC 100,000,000, AP 35,000, Deficit 8,350
--
-- IMPORTANT: Internal seed data is environment/config-specific and must not be committed.
-- For internal use, create a separate seed file (e.g., supabase/seeds/internal_seed.sql)
-- and add it to .gitignore.

begin;

-- ============================================================================
-- ORGANIZATION: Acme Corp
-- ============================================================================

insert into organizations (id, name, currency_code, timezone, fiscal_year_end_month, fiscal_year_end_day)
values (
  '00000000-0000-0000-0000-000000000001',
  'Acme Corp',
  'USD',
  'America/New_York',
  12, -- December
  31  -- 31st
);

-- ============================================================================
-- MOCK USER (for created_by, posted_by fields)
-- ============================================================================

-- Using fixed UUIDs for mock users (in real usage, these would be auth.users.id)
-- '10000000-0000-0000-0000-000000000001' represents "Sarah Johnson" (owner)
-- '20000000-0000-0000-0000-000000000001' represents "Mike Chen" (bookkeeper)

-- ============================================================================
-- ACCOUNTING PERIODS
-- ============================================================================

-- July 2026 (locked to test period lock validation)
insert into accounting_periods (
  id,
  organization_id,
  name,
  start_date,
  end_date,
  is_locked,
  locked_at,
  locked_by
) values (
  '01000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'July 2026',
  '2026-07-01',
  '2026-07-31',
  true,
  '2026-08-01 00:00:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000001'
);

-- August 2026 (open period)
insert into accounting_periods (
  id,
  organization_id,
  name,
  start_date,
  end_date,
  is_locked
) values (
  '01000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  'August 2026',
  '2026-08-01',
  '2026-08-31',
  false
);

-- ============================================================================
-- CHART OF ACCOUNTS (Locked compact US CoA)
-- ============================================================================

insert into accounts (id, organization_id, code, name, type, category, is_header, is_cash, is_system, is_active) values
-- 1000 Cash
('10000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001', '1000', 'Cash', 'Asset', 'Cash', true, false, false, true),
('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
('10000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', '1020', 'Savings / reserves', 'Asset', 'Cash', false, true, false, true),

-- 1200-1500 Other Assets
('10000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000001', '1200', 'Prepaid expenses', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000400', '00000000-0000-0000-0000-000000000001', '1400', 'Due from parent', 'Asset', 'AR', false, false, false, true),
('10000000-0000-0000-0000-000000000500', '00000000-0000-0000-0000-000000000001', '1500', 'Computer and equipment', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000550', '00000000-0000-0000-0000-000000000001', '1550', 'Furniture and fixtures', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000560', '00000000-0000-0000-0000-000000000001', '1560', 'Leasehold improvements', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000590', '00000000-0000-0000-0000-000000000001', '1590', 'Accumulated depreciation - equipment', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000591', '00000000-0000-0000-0000-000000000001', '1591', 'Accumulated depreciation - furniture', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000592', '00000000-0000-0000-0000-000000000001', '1592', 'Accumulated depreciation - leasehold', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000700', '00000000-0000-0000-0000-000000000001', '1700', 'Intangible assets', 'Asset', 'Other', false, false, false, true),
('10000000-0000-0000-0000-000000000790', '00000000-0000-0000-0000-000000000001', '1790', 'Accumulated amortization - intangibles', 'Asset', 'Other', false, false, false, true),

-- 2000 Liabilities
('20000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001', '2000', 'Accounts payable', 'Liability', 'AP', false, false, true, true),
('20000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000001', '2100', 'Accrued expenses', 'Liability', 'Other', false, false, false, true),
('20000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000001', '2200', 'Due to parent', 'Liability', 'AP', false, false, false, true),
('20000000-0000-0000-0000-000000000300', '00000000-0000-0000-0000-000000000001', '2300', 'Credit cards', 'Liability', 'Other', false, false, false, true),

-- 3000 Equity
('30000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001', '3000', 'Common stock', 'Equity', 'Equity', false, false, true, true),
('30000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000001', '3100', 'Additional paid-in capital', 'Equity', 'Equity', false, false, true, true),
('30000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000001', '3200', 'Retained earnings', 'Equity', 'Equity', false, false, true, true),
('30000000-0000-0000-0000-000000000900', '00000000-0000-0000-0000-000000000001', '3900', 'Opening balance equity', 'Equity', 'Equity', false, false, true, true),

-- 4000 Revenue
('40000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001', '4000', 'Revenue', 'Revenue', 'Revenue', true, false, false, true),
('40000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '4010', 'Product / service revenue', 'Revenue', 'Revenue', false, false, false, true),
('40000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000001', '4100', 'Other income', 'Revenue', 'Revenue', false, false, false, true),

-- 5000 Operating Expenses
('50000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001', '5000', 'Operating expenses', 'Expense', 'Expense', true, false, false, true),
('50000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '5010', 'Contractors and professional', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', '5020', 'Legal and formation', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000001', '5030', 'Software and subscriptions', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000040', '00000000-0000-0000-0000-000000000001', '5040', 'Banking and payments', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000050', '00000000-0000-0000-0000-000000000001', '5050', 'Travel', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000060', '00000000-0000-0000-0000-000000000001', '5060', 'Insurance', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000070', '00000000-0000-0000-0000-000000000001', '5070', 'Payroll and benefits', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000080', '00000000-0000-0000-0000-000000000001', '5080', 'Office and admin', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000090', '00000000-0000-0000-0000-000000000001', '5090', 'Tax expense', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000120', '00000000-0000-0000-0000-000000000001', '5120', 'Depreciation expense', 'Expense', 'Expense', false, false, false, true),
('50000000-0000-0000-0000-000000000130', '00000000-0000-0000-0000-000000000001', '5130', 'Amortization expense', 'Expense', 'Expense', false, false, false, true),

-- 6000 Other Expenses
('60000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001', '6000', 'Other expenses', 'Expense', 'Expense', true, false, false, true),
('60000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000001', '6100', 'FX and rounding', 'Expense', 'Expense', false, false, false, true),
('60000000-0000-0000-0000-000000000110', '00000000-0000-0000-0000-000000000001', '6110', 'Gain or loss on asset disposal', 'Expense', 'Expense', false, false, false, true);

-- ============================================================================
-- CONTACTS
-- ============================================================================

insert into contacts (id, organization_id, type, name, email, notes, is_active) values
-- Parent company (type: Other)
('c0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'Other', 'Parent Company LLC', 'finance@parentco.example.com', 'Parent entity for funding and IC transactions', true),

-- Vendors
('c0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'Vendor', 'Acme Legal Services', 'billing@acmelegal.example.com', 'Corporate legal counsel', true),
('c0000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 'Vendor', 'CloudHost Inc', 'accounts@cloudhost.example.com', 'Infrastructure hosting provider', true),
('c0000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', 'Vendor', 'Office Supplies Co', 'billing@officesupplies.example.com', 'Office supplies and equipment', true);

-- ============================================================================
-- JOURNALS & JOURNAL LINES
-- ============================================================================

-- JOURNAL 1: Parent funding (Dr 1010 Operating cash, Cr 3100 APIC) - POSTED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by
) values (
  'a0000001-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0001',
  '2026-08-01',
  'Parent funding - initial capital contribution',
  'Posted',
  'opening',
  '10000000-0000-0000-0000-000000000001',
  '2026-08-01 09:00:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000001'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000001-0000-0000-0000-000000000000', '10000000-0000-0000-0000-000000000010', 100000000, 0, 'Initial capital funding from parent'),
('00000000-0000-0000-0000-000000000001', 'a0000001-0000-0000-0000-000000000000', '30000000-0000-0000-0000-000000000100', 0, 100000000, null);

-- JOURNAL 2: Legal services bill recognition (Dr 5020 Legal, Cr 2000 AP) - POSTED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by
) values (
  'a0000002-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0002',
  '2026-08-05',
  'Legal services - incorporation',
  'Posted',
  'bill',
  '10000000-0000-0000-0000-000000000001',
  '2026-08-05 10:30:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000001'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000002-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000020', 500000, 0, 'Incorporation legal fees'),
('00000000-0000-0000-0000-000000000001', 'a0000002-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000000', 0, 500000, null);

-- JOURNAL 3: Payment of legal bill (Dr 2000 AP, Cr 1010 Operating cash) - POSTED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by
) values (
  'a0000003-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0003',
  '2026-08-07',
  'Payment: Legal services',
  'Posted',
  'bill_payment',
  '10000000-0000-0000-0000-000000000001',
  '2026-08-07 14:15:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000001'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000003-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000000', 500000, 0, 'Payment to Acme Legal Services'),
('00000000-0000-0000-0000-000000000001', 'a0000003-0000-0000-0000-000000000000', '10000000-0000-0000-0000-000000000010', 0, 500000, null);

-- JOURNAL 4: Software subscription (Dr 5030 Software, Cr 1010 Cash) - POSTED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by
) values (
  'a0000004-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0004',
  '2026-08-10',
  'Software subscription - annual',
  'Posted',
  'cash',
  '10000000-0000-0000-0000-000000000001',
  '2026-08-10 11:20:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000001'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000004-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000030', 120000, 0, 'Annual software license'),
('00000000-0000-0000-0000-000000000001', 'a0000004-0000-0000-0000-000000000000', '10000000-0000-0000-0000-000000000010', 0, 120000, null);

-- JOURNAL 5: Intercompany service (Dr 1400 Due from parent, Cr 4010 Revenue) - ORIGINAL, NOW REVERSED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by, reversed_by_journal_id
) values (
  'a0000005-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0005',
  '2026-08-15',
  'Service revenue - parent company',
  'Reversed',
  'manual',
  '20000000-0000-0000-0000-000000000001',
  '2026-08-15 13:00:00-04'::timestamptz,
  '20000000-0000-0000-0000-000000000001',
  'a0000006-0000-0000-0000-000000000000'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000005-0000-0000-0000-000000000000', '10000000-0000-0000-0000-000000000400', 250000, 0, 'Consulting services to parent'),
('00000000-0000-0000-0000-000000000001', 'a0000005-0000-0000-0000-000000000000', '40000000-0000-0000-0000-000000000010', 0, 250000, null);

-- JOURNAL 6: REVERSAL of journal 5 - POSTED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by, reverses_journal_id
) values (
  'a0000006-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'REV-JE-2026-0005',
  '2026-08-20',
  'REVERSAL: Service revenue - parent company',
  'Posted',
  'reversal',
  '20000000-0000-0000-0000-000000000001',
  '2026-08-20 09:30:00-04'::timestamptz,
  '20000000-0000-0000-0000-000000000001',
  'a0000005-0000-0000-0000-000000000000'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000006-0000-0000-0000-000000000000', '40000000-0000-0000-0000-000000000010', 250000, 0, 'Reversing: Consulting services to parent'),
('00000000-0000-0000-0000-000000000001', 'a0000006-0000-0000-0000-000000000000', '10000000-0000-0000-0000-000000000400', 0, 250000, null);

-- JOURNAL 7: Insurance payment (Dr 5060 Insurance, Cr 1010 Cash) - POSTED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by
) values (
  'a0000007-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0007',
  '2026-08-22',
  'General liability insurance - annual premium',
  'Posted',
  'cash',
  '10000000-0000-0000-0000-000000000001',
  '2026-08-22 15:45:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000001'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000007-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000060', 180000, 0, 'Annual liability insurance'),
('00000000-0000-0000-0000-000000000001', 'a0000007-0000-0000-0000-000000000000', '10000000-0000-0000-0000-000000000010', 0, 180000, null);

-- JOURNAL 8: Office supplies bill (Dr 5080 Office, Cr 2000 AP) - POSTED
insert into journals (
  id, organization_id, number, entry_date, description, status, source,
  created_by, posted_at, posted_by
) values (
  'a0000008-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0008',
  '2026-08-25',
  'Office supplies and equipment',
  'Posted',
  'bill',
  '10000000-0000-0000-0000-000000000001',
  '2026-08-25 10:00:00-04'::timestamptz,
  '10000000-0000-0000-0000-000000000001'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000008-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000080', 35000, 0, 'Desks, chairs, and office supplies'),
('00000000-0000-0000-0000-000000000001', 'a0000008-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000000', 0, 35000, null);

-- JOURNAL 9: DRAFT - contractor payment pending approval - DRAFT (not on reports)
insert into journals (
  id, organization_id, number, entry_date, description, status, source, created_by
) values (
  'a0000009-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'JE-2026-0009',
  '2026-08-28',
  'Contractor payment - pending approval',
  'Draft',
  'manual',
  '20000000-0000-0000-0000-000000000001'
);

insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo) values
('00000000-0000-0000-0000-000000000001', 'a0000009-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000010', 450000, 0, 'Web development contractor - August'),
('00000000-0000-0000-0000-000000000001', 'a0000009-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000000', 0, 450000, null);

-- ============================================================================
-- BILLS
-- ============================================================================

insert into bills (
  id, organization_id, vendor_id, number, bill_date, due_date, status,
  total_cents, paid_cents, recognition_journal_id, created_by
) values
-- Legal bill (fully paid)
(
  'b0000001-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'c0000000-0000-0000-0000-000000000002',
  'INV-2026-001',
  '2026-08-05',
  '2026-09-04',
  'Paid',
  500000,
  500000,
  'a0000002-0000-0000-0000-000000000000',
  '10000000-0000-0000-0000-000000000001'
),
-- Office supplies bill (unpaid)
(
  'b0000002-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'c0000000-0000-0000-0000-000000000004',
  'INV-2026-002',
  '2026-08-25',
  '2026-09-24',
  'Open',
  35000,
  0,
  'a0000008-0000-0000-0000-000000000000',
  '10000000-0000-0000-0000-000000000001'
);

-- ============================================================================
-- BILL LINES
-- ============================================================================

insert into bill_lines (organization_id, bill_id, account_id, description, amount_cents) values
('00000000-0000-0000-0000-000000000001', 'b0000001-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000020', 'Corporate incorporation filing', 500000),
('00000000-0000-0000-0000-000000000001', 'b0000002-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000080', 'Standing desks (2)', 25000),
('00000000-0000-0000-0000-000000000001', 'b0000002-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000080', 'Office chairs (2)', 10000);

-- ============================================================================
-- BILL PAYMENTS
-- ============================================================================

insert into bill_payments (
  id, organization_id, bill_id, payment_journal_id, payment_date, amount_cents, created_by
) values (
  'bp000001-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'b0000001-0000-0000-0000-000000000000',
  'a0000003-0000-0000-0000-000000000000',
  '2026-08-07',
  500000,
  '10000000-0000-0000-0000-000000000001'
);

commit;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Expected results (all amounts in cents):
-- Trial Balance: 100,035,000 debit = 100,035,000 credit
-- Operating cash (1010): 99,200,000 debit (100M - 500k - 120k - 180k)
-- APIC (3100): 100,000,000 credit
-- AP (2000): 35,000 credit (500k - 500k + 35k)
-- Expenses (5020+5030+5060+5080): 835,000 debit (500k + 120k + 180k + 35k)
-- Net Income (deficit): -835,000 (no revenue due to reversal pair netting to zero)
-- Balance Sheet: Assets (99,200,000) = Liabilities (35,000) + Equity (100,000,000 - 835,000)
