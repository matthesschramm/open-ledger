-- Fixed-asset register: threshold, acquisition, double-run, dispose, rollforward.

do $$
declare
  v_org_id uuid;
  v_user_id uuid := '00000000-0000-0000-0000-0000000000c1'::uuid;
  v_cash_id uuid;
  v_result jsonb;
  v_laptop_id uuid;
  v_journal_id uuid;
  v_count int;
  v_balance bigint;
  v_opening_gross bigint;
  v_dep bigint;
  v_closing_nbv bigint;
begin
  raise notice '========================================';
  raise notice 'FIXED ASSET REGISTER TESTS';
  raise notice '========================================';

  insert into organizations (name, currency_code, capitalization_threshold_cents)
  values ('FA Regression Org', 'USD', 100000)
  returning id into v_org_id;

  insert into auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (v_user_id, 'fa.owner@test.com', 'mock', now(), now(), now())
  on conflict (id) do update set email = excluded.email;

  delete from memberships where user_id = v_user_id;
  insert into memberships (organization_id, user_id, role)
  values (v_org_id, v_user_id, 'owner');

  insert into accounts (organization_id, code, name, type, category, is_header, is_cash, is_system, is_active)
  values
    (v_org_id, '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
    (v_org_id, '1500', 'Computer and equipment', 'Asset', 'Other', false, false, false, true);

  perform ensure_ppe_accounts(v_org_id);

  select id into v_cash_id from accounts where organization_id = v_org_id and code = '1010';

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text,
    true
  );

  -- Below threshold must be refused
  v_result := register_fixed_asset(
    p_description => 'USB-C hub',
    p_class => 'equipment',
    p_cost_cents => 4500,
    p_useful_life_months => 36,
    p_acquisition_date => '2026-08-01',
    p_in_service_date => '2026-08-01',
    p_credit_account_id => v_cash_id,
    p_user_id => v_user_id
  );
  if coalesce(v_result->>'success', 'false') = 'true' then
    raise exception '✗ FAIL: sub-threshold purchase was capitalized';
  end if;
  if v_result->>'error' not like '%threshold%' then
    raise exception '✗ FAIL: expected threshold error, got %', v_result;
  end if;
  raise notice '✓ PASS: register_fixed_asset refuses cost below threshold';

  -- Capitalize a laptop
  v_result := register_fixed_asset(
    p_description => 'Test MacBook',
    p_class => 'equipment',
    p_cost_cents => 360000,
    p_useful_life_months => 36,
    p_acquisition_date => '2026-08-01',
    p_in_service_date => '2026-08-01',
    p_residual_cents => 0,
    p_credit_account_id => v_cash_id,
    p_user_id => v_user_id
  );
  if coalesce(v_result->>'success', 'false') <> 'true' then
    raise exception '✗ FAIL: register laptop failed: %', v_result;
  end if;
  v_laptop_id := (v_result->>'asset_id')::uuid;
  v_journal_id := (v_result->>'journal_id')::uuid;

  select calculate_account_balance(v_org_id, a.id, '2026-08-01')
  into v_balance
  from accounts a
  where a.organization_id = v_org_id and a.code = '1500';
  if v_balance <> 360000 then
    raise exception '✗ FAIL: 1500 should be 360000 after purchase, got %', v_balance;
  end if;

  select count(*) into v_count
  from journals
  where id = v_journal_id and source = 'fixed_asset' and status = 'Posted';
  if v_count <> 1 then
    raise exception '✗ FAIL: acquisition journal was not posted as fixed_asset';
  end if;
  raise notice '✓ PASS: register_fixed_asset posts Dr PPE / Cr cash';

  -- August depreciation: 360000 / 36 = 10000
  v_result := run_depreciation('2026-08-01', v_user_id);
  if coalesce(v_result->>'success', 'false') <> 'true' then
    raise exception '✗ FAIL: August depreciation failed: %', v_result;
  end if;
  if (v_result->>'total_cents')::bigint <> 10000 then
    raise exception '✗ FAIL: expected August dep 10000, got %', v_result;
  end if;

  select accum_dep_cents into v_count from fixed_assets where id = v_laptop_id;
  if v_count <> 10000 then
    raise exception '✗ FAIL: laptop accum should be 10000, got %', v_count;
  end if;
  raise notice '✓ PASS: run_depreciation posts one month straight-line';

  -- Same month again must not double-charge
  v_result := run_depreciation('2026-08-15', v_user_id);
  if coalesce(v_result->>'success', 'false') <> 'true' then
    raise exception '✗ FAIL: second August run should succeed as a no-op: %', v_result;
  end if;
  if (v_result->>'total_cents')::bigint <> 0 then
    raise exception '✗ FAIL: second August run charged again: %', v_result;
  end if;
  select accum_dep_cents into v_count from fixed_assets where id = v_laptop_id;
  if v_count <> 10000 then
    raise exception '✗ FAIL: accum changed after skipped month';
  end if;
  raise notice '✓ PASS: run_depreciation refuses a second charge for the same month';

  -- Rollforward for August
  select opening_gross_cents, depreciation_cents, closing_nbv_cents
  into v_opening_gross, v_dep, v_closing_nbv
  from get_ppe_rollforward(v_org_id, '2026-08-01', '2026-08-31')
  where asset_class = 'equipment';

  if v_opening_gross <> 0 then
    raise exception '✗ FAIL: August opening gross should be 0, got %', v_opening_gross;
  end if;
  if v_dep <> 10000 then
    raise exception '✗ FAIL: August depreciation should be 10000, got %', v_dep;
  end if;
  if v_closing_nbv <> 350000 then
    raise exception '✗ FAIL: August closing NBV should be 350000, got %', v_closing_nbv;
  end if;
  raise notice '✓ PASS: get_ppe_rollforward matches the register for August';

  -- Dispose in September for 200000 cash. Month dep 10000, NBV 340000, loss 140000.
  v_result := dispose_fixed_asset(
    p_asset_id => v_laptop_id,
    p_disposal_date => '2026-09-10',
    p_proceeds_cents => 200000,
    p_cash_account_id => v_cash_id,
    p_user_id => v_user_id
  );
  if coalesce(v_result->>'success', 'false') <> 'true' then
    raise exception '✗ FAIL: dispose failed: %', v_result;
  end if;
  if (v_result->>'loss_cents')::bigint <> 140000 then
    raise exception '✗ FAIL: expected loss 140000, got %', v_result;
  end if;
  if (v_result->>'month_depreciation_cents')::bigint <> 10000 then
    raise exception '✗ FAIL: dispose should take September dep, got %', v_result;
  end if;

  if (select status from fixed_assets where id = v_laptop_id) <> 'disposed' then
    raise exception '✗ FAIL: asset status should be disposed';
  end if;

  select calculate_account_balance(v_org_id, a.id, '2026-09-10')
  into v_balance
  from accounts a
  where a.organization_id = v_org_id and a.code = '1500';
  if v_balance <> 0 then
    raise exception '✗ FAIL: 1500 should be 0 after disposal, got %', v_balance;
  end if;

  select calculate_account_balance(v_org_id, a.id, '2026-09-10')
  into v_balance
  from accounts a
  where a.organization_id = v_org_id and a.code = '1590';
  if v_balance <> 0 then
    raise exception '✗ FAIL: 1590 should be 0 after disposal, got %', v_balance;
  end if;
  raise notice '✓ PASS: dispose_fixed_asset clears gross and accum and records the loss';

  -- Already disposed
  v_result := dispose_fixed_asset(
    p_asset_id => v_laptop_id,
    p_disposal_date => '2026-09-11',
    p_proceeds_cents => 0,
    p_user_id => v_user_id
  );
  if coalesce(v_result->>'success', 'false') = 'true' then
    raise exception '✗ FAIL: second dispose should fail';
  end if;
  raise notice '✓ PASS: dispose_fixed_asset refuses an already disposed asset';

  -- Furniture + lock: cannot post into a locked month
  insert into accounting_periods (organization_id, name, start_date, end_date, status)
  values (v_org_id, 'October 2026', '2026-10-01', '2026-10-31', 'Locked');

  v_result := register_fixed_asset(
    p_description => 'Desk',
    p_class => 'furniture',
    p_cost_cents => 220000,
    p_useful_life_months => 60,
    p_acquisition_date => '2026-10-05',
    p_in_service_date => '2026-10-05',
    p_credit_account_id => v_cash_id,
    p_user_id => v_user_id
  );
  if coalesce(v_result->>'success', 'false') = 'true' then
    raise exception '✗ FAIL: locked period allowed an acquisition post';
  end if;
  if v_result->>'error' not like '%Locked%' and v_result->>'error' not like '%locked%' then
    raise exception '✗ FAIL: expected locked period error, got %', v_result;
  end if;
  raise notice '✓ PASS: register_fixed_asset respects a locked period';

  raise notice '========================================';
  raise notice 'FIXED ASSET REGISTER TESTS PASSED';
  raise notice '========================================';
end
$$;
