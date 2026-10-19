-- Test: Account Ledger Running Balance with Opening Balance
-- Verify that the running balance in account ledger includes transactions before start_date

do $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_account_id uuid;
  v_counter_account_id uuid;
  v_journal1_id uuid;
  v_journal2_id uuid;
  v_result record;
  v_opening_balance bigint;
  v_first_running_balance bigint;
begin
  -- Create test organization
  insert into organizations (name, currency_code)
  values ('Test Ledger Balance Org', 'USD')
  returning id into v_org_id;

  -- Create test user
  v_user_id := gen_random_uuid();
  
  -- Create membership
  insert into memberships (organization_id, user_id, role)
  values (v_org_id, v_user_id, 'owner');

  -- Create cash account (1010)
  insert into accounts (organization_id, code, name, type, category, is_cash)
  values (v_org_id, '1010', 'Operating Cash', 'Asset', 'Cash', true)
  returning id into v_account_id;

  -- Create equity account (3100)
  insert into accounts (organization_id, code, name, type, category)
  values (v_org_id, '3100', 'APIC', 'Equity', 'Paid-in Capital')
  returning id into v_counter_account_id;

  raise notice '=== Test 1: Account Ledger Opening Balance ===';
  
  -- Post Journal 1 on 2026-01-01: Dr 1010 $1000 / Cr 3100 $1000
  insert into journals (organization_id, number, entry_date, description, status, created_by)
  values (v_org_id, 'J0001', '2026-01-01', 'Opening balance', 'Posted', v_user_id)
  returning id into v_journal1_id;

  insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents)
  values
    (v_org_id, v_journal1_id, v_account_id, 100000, 0),
    (v_org_id, v_journal1_id, v_counter_account_id, 0, 100000);

  -- Post Journal 2 on 2026-06-01: Dr 1010 $500 / Cr 3100 $500
  insert into journals (organization_id, number, entry_date, description, status, created_by)
  values (v_org_id, 'J0002', '2026-06-01', 'Additional funding', 'Posted', v_user_id)
  returning id into v_journal2_id;

  insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents)
  values
    (v_org_id, v_journal2_id, v_account_id, 50000, 0),
    (v_org_id, v_journal2_id, v_counter_account_id, 0, 50000);

  -- Query ledger from 2026-06-01 onwards (should include opening balance from before)
  select running_balance_cents into v_first_running_balance
  from get_account_ledger(
    v_org_id,
    v_account_id,
    '2026-06-01'::date,
    '2026-12-31'::date
  )
  limit 1;

  -- Calculate what the opening balance should be (all transactions before 2026-06-01)
  v_opening_balance := 100000; -- Only J0001 before start date

  raise notice 'Opening balance (before 2026-06-01): %', v_opening_balance;
  raise notice 'First running balance in ledger (2026-06-01): %', v_first_running_balance;
  raise notice 'Expected first running balance: %', v_opening_balance + 50000;

  -- The first row should be J0002 with running balance = opening (100000) + J0002 (50000) = 150000
  if v_first_running_balance = v_opening_balance + 50000 then
    raise notice '✅ PASS: Running balance includes opening balance';
  else
    raise exception '❌ FAIL: Running balance = % but expected %', 
      v_first_running_balance, v_opening_balance + 50000;
  end if;

  raise notice '=== Test 2: Trial Balance vs Account Ledger Ending ===';
  
  -- Get trial balance for account 1010 as of 2026-12-31
  declare
    v_tb_balance bigint;
    v_ledger_ending bigint;
  begin
    select debit_cents - credit_cents into v_tb_balance
    from get_trial_balance(v_org_id, '2026-12-31'::date)
    where account_code = '1010';

    -- Get ending balance from account ledger (full year)
    -- The function returns rows ordered chronologically, so last row is ending balance
    with ledger_rows as (
      select running_balance_cents, row_number() over () as rn
      from get_account_ledger(
        v_org_id,
        v_account_id,
        null,
        '2026-12-31'::date
      )
    )
    select running_balance_cents into v_ledger_ending
    from ledger_rows
    order by rn desc
    limit 1;

    raise notice 'Trial balance (1010 as of 2026-12-31): %', v_tb_balance;
    raise notice 'Ledger ending balance (1010 as of 2026-12-31): %', v_ledger_ending;

    if v_tb_balance = v_ledger_ending then
      raise notice '✅ PASS: Trial balance matches ledger ending balance';
    else
      raise exception '❌ FAIL: Trial balance = % but ledger ending = %', 
        v_tb_balance, v_ledger_ending;
    end if;
  end;

  -- Cleanup
  delete from journal_lines where organization_id = v_org_id;
  delete from journals where organization_id = v_org_id;
  delete from accounts where organization_id = v_org_id;
  delete from contacts where organization_id = v_org_id;
  delete from memberships where organization_id = v_org_id;
  delete from organizations where id = v_org_id;

  raise notice '✅ All tests passed';
end;
$$;

comment on column journals.status is 'Journal status: Draft (editable) | Posted (locked, on reports) | Reversed (locked, on reports, has reversal)';
