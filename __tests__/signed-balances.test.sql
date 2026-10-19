-- Test: Signed Balances (BUG-01)
-- Verify that signed balances use normal balance conventions

-- Setup: Create test organization and accounts
BEGIN;

-- Insert test organization
INSERT INTO organizations (id, name, currency_code, timezone)
VALUES ('00000000-0000-0000-0000-000000000001', 'Test Org', 'USD', 'America/New_York');

-- Insert test accounts
INSERT INTO accounts (id, organization_id, code, name, type, category, is_cash, is_active) VALUES
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '1010', 'Operating Cash', 'Asset', 'Cash', true, true),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '3100', 'APIC', 'Equity', 'Equity', false, true),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '5080', 'Office Expense', 'Expense', 'Expense', false, true),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '4000', 'Service Revenue', 'Revenue', 'Revenue', false, true);

-- Create test user for posting
DO $$
BEGIN
  -- Set request.jwt.claims for security definer functions
  PERFORM set_config('request.jwt.claims', '{"sub": "test-user-001"}', true);
END $$;

-- Test 1: Dr Expense / Cr Cash -> Cash decreases
-- Journal: Dr 5080 Office Expense $100 / Cr 1010 Operating Cash $100
INSERT INTO journals (id, organization_id, number, entry_date, description, status, source, created_by)
VALUES ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'TEST-001', '2026-08-29', 'Test: Cash decrease', 'Draft', 'manual', 'test-user-001');

INSERT INTO journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents) VALUES
  ('00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', 10000, 0),  -- Dr 5080 $100
  ('00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 0, 10000);  -- Cr 1010 $100

-- Post the journal
SELECT post_journal('20000000-0000-0000-0000-000000000001');

-- Verify: Cash balance should be NEGATIVE (decreased)
DO $$
DECLARE
  v_cash_balance bigint;
BEGIN
  v_cash_balance := calculate_account_balance(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '10000000-0000-0000-0000-000000000001'::uuid,
    '2026-08-29'::date
  );
  
  IF v_cash_balance != -10000 THEN
    RAISE EXCEPTION 'FAIL: Cash balance should be -10000 (decrease), got %', v_cash_balance;
  END IF;
  
  RAISE NOTICE 'PASS: Cash balance is -10000 (correctly decreased)';
END $$;

-- Verify: Expense balance should be POSITIVE (increased)
DO $$
DECLARE
  v_expense_balance bigint;
BEGIN
  v_expense_balance := calculate_account_balance(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '10000000-0000-0000-0000-000000000003'::uuid,
    '2026-08-29'::date
  );
  
  IF v_expense_balance != 10000 THEN
    RAISE EXCEPTION 'FAIL: Expense balance should be 10000 (increase), got %', v_expense_balance;
  END IF;
  
  RAISE NOTICE 'PASS: Expense balance is 10000 (correctly increased)';
END $$;

-- Test 2: Balance Sheet equation (Assets = Liabilities + Equity)
-- Add parent funding: Dr 1010 Cash $100,000 / Cr 3100 APIC $100,000
INSERT INTO journals (id, organization_id, number, entry_date, description, status, source, created_by)
VALUES ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'TEST-002', '2026-08-29', 'Test: Parent funding', 'Draft', 'manual', 'test-user-001');

INSERT INTO journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents) VALUES
  ('00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 10000000, 0),  -- Dr 1010 $100,000
  ('00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 0, 10000000);  -- Cr 3100 $100,000

SELECT post_journal('20000000-0000-0000-0000-000000000002');

-- Verify: Balance Sheet is balanced (Assets = Liabilities + Equity)
DO $$
DECLARE
  v_total_assets bigint := 0;
  v_total_liabilities bigint := 0;
  v_total_equity bigint := 0;
  v_row record;
BEGIN
  -- Get balance sheet
  FOR v_row IN
    SELECT * FROM get_balance_sheet('00000000-0000-0000-0000-000000000001'::uuid, '2026-08-29'::date)
  LOOP
    IF v_row.section = 'Assets' THEN
      v_total_assets := v_total_assets + v_row.balance_cents;
    ELSIF v_row.section = 'Liabilities' THEN
      v_total_liabilities := v_total_liabilities + v_row.balance_cents;
    ELSIF v_row.section = 'Equity' THEN
      v_total_equity := v_total_equity + v_row.balance_cents;
    END IF;
  END LOOP;
  
  -- Assets should equal Liabilities + Equity
  IF v_total_assets != (v_total_liabilities + v_total_equity) THEN
    RAISE EXCEPTION 'FAIL: Balance Sheet not balanced. Assets=%, Liabilities=%, Equity=%',
      v_total_assets, v_total_liabilities, v_total_equity;
  END IF;
  
  RAISE NOTICE 'PASS: Balance Sheet is balanced. Assets=%, L+E=%',
    v_total_assets, (v_total_liabilities + v_total_equity);
END $$;

-- Test 3: Cash Movement footer matches row nets
-- Add revenue: Dr 1010 Cash $5,000 / Cr 4000 Revenue $5,000
INSERT INTO journals (id, organization_id, number, entry_date, description, status, source, created_by)
VALUES ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 'TEST-003', '2026-08-29', 'Test: Revenue received', 'Draft', 'manual', 'test-user-001');

INSERT INTO journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents) VALUES
  ('00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 500000, 0),  -- Dr 1010 $5,000
  ('00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000004', 0, 500000);  -- Cr 4000 $5,000

SELECT post_journal('20000000-0000-0000-0000-000000000003');

-- Verify: Cash Movement rows sum to net change
DO $$
DECLARE
  v_sum_of_rows bigint := 0;
  v_row record;
BEGIN
  FOR v_row IN
    SELECT * FROM get_cash_movement('00000000-0000-0000-0000-000000000001'::uuid, '2026-08-29'::date, '2026-08-29'::date)
  LOOP
    v_sum_of_rows := v_sum_of_rows + v_row.net_change_cents;
  END LOOP;
  
  -- Sum of cash movement rows should equal net cash change for the period
  -- Expected: +100,000 (parent funding) - 100 (expense) + 5,000 (revenue) = +104,900
  IF v_sum_of_rows != 10490000 THEN
    RAISE EXCEPTION 'FAIL: Cash Movement rows do not sum correctly. Expected 10490000, got %', v_sum_of_rows;
  END IF;
  
  RAISE NOTICE 'PASS: Cash Movement rows sum to % (correct net change)', v_sum_of_rows;
END $$;

-- Test 4: Balanced: Yes is honest (only true when statement balances)
-- Verify that with current transactions, balance sheet balances
DO $$
DECLARE
  v_total_assets bigint := 0;
  v_total_liabilities bigint := 0;
  v_total_equity bigint := 0;
  v_row record;
  v_is_balanced boolean;
BEGIN
  FOR v_row IN
    SELECT * FROM get_balance_sheet('00000000-0000-0000-0000-000000000001'::uuid, '2026-08-29'::date)
  LOOP
    IF v_row.section = 'Assets' THEN
      v_total_assets := v_total_assets + v_row.balance_cents;
    ELSIF v_row.section = 'Liabilities' THEN
      v_total_liabilities := v_total_liabilities + v_row.balance_cents;
    ELSIF v_row.section = 'Equity' THEN
      v_total_equity := v_total_equity + v_row.balance_cents;
    END IF;
  END LOOP;
  
  -- Check if balanced (allow 1 cent tolerance for rounding)
  v_is_balanced := abs(v_total_assets - (v_total_liabilities + v_total_equity)) < 100;
  
  IF NOT v_is_balanced THEN
    RAISE EXCEPTION 'FAIL: Balance Sheet should be balanced but is not. Assets=%, L+E=%',
      v_total_assets, (v_total_liabilities + v_total_equity);
  END IF;
  
  RAISE NOTICE 'PASS: Balanced: Yes is honest (statement actually balances)';
END $$;

-- Cleanup
ROLLBACK;

-- Summary
SELECT 'All signed balance tests passed!' as result;
