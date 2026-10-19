-- Open Ledger S2-6: AR Aging As-Of Date Tests
-- Tests for AR aging report with as-of date functionality

-- Test: AR aging with as-of date
do $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_customer_id uuid;
  v_revenue_account_id uuid;
  v_cash_account_id uuid;
  v_invoice1_id uuid;
  v_invoice2_id uuid;
  v_invoice3_id uuid;
  v_result jsonb;
  v_count int;
  v_amount bigint;
begin
  -- Create test organization
  insert into organizations (name, currency_code)
  values ('Test AR Aging Org', 'USD')
  returning id into v_org_id;

  -- Create test user
  v_user_id := gen_random_uuid();
  
  -- Create membership
  insert into memberships (organization_id, user_id, role)
  values (v_org_id, v_user_id, 'owner');

  -- Create revenue account
  insert into accounts (organization_id, code, name, type, category)
  values (v_org_id, '4000', 'Service Revenue', 'Revenue', 'Revenue')
  returning id into v_revenue_account_id;

  -- Create cash account
  insert into accounts (organization_id, code, name, type, category, is_cash)
  values (v_org_id, '1010', 'Operating Cash', 'Asset', 'Cash', true)
  returning id into v_cash_account_id;

  -- Create customer contact
  insert into contacts (organization_id, type, name, email)
  values (v_org_id, 'Customer', 'Test Customer', 'test@customer.com')
  returning id into v_customer_id;

  -- Set session variables (simulate authenticated user)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_id)::text, true);

  raise notice '=== Test 1: Invoice with no receipts ===';
  -- Create Invoice 1: Posted 2026-08-01, no receipts
  insert into invoices (
    organization_id,
    customer_id,
    number,
    invoice_date,
    due_date,
    status,
    total_cents,
    created_by
  ) values (
    v_org_id,
    v_customer_id,
    'INV-001',
    '2026-08-01',
    '2026-08-31',
    'Draft',
    10000,
    v_user_id
  )
  returning id into v_invoice1_id;

  insert into invoice_lines (
    organization_id,
    invoice_id,
    account_id,
    line_number,
    description,
    amount_cents
  ) values (
    v_org_id,
    v_invoice1_id,
    v_revenue_account_id,
    1,
    'Services',
    10000
  );

  v_result := post_invoice(v_invoice1_id);
  if not (v_result->>'success')::boolean then
    raise exception 'Test 1 setup failed: %', v_result->>'error';
  end if;

  -- Test 1a: Should NOT show on as-of date before invoice date
  select count(*) into v_count
  from get_ar_aging(v_org_id, '2026-07-31')
  where invoice_id = v_invoice1_id;

  if v_count != 0 then
    raise exception 'Test 1a failed: Invoice should not appear before invoice date';
  end if;
  raise notice 'Test 1a passed: Invoice does not show before invoice date';

  -- Test 1b: Should show on as-of date after invoice date with full amount
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-15')
  where invoice_id = v_invoice1_id;

  if v_amount is null or v_amount != 10000 then
    raise exception 'Test 1b failed: Invoice should show full amount (got %)', v_amount;
  end if;
  raise notice 'Test 1b passed: Invoice shows full amount on as-of date after invoice date';

  raise notice '=== Test 2: Invoice with later credit ===';
  -- Create Invoice 2: Posted 2026-08-01, credit note dated 2026-08-20
  insert into invoices (
    organization_id,
    customer_id,
    number,
    invoice_date,
    due_date,
    status,
    total_cents,
    created_by
  ) values (
    v_org_id,
    v_customer_id,
    'INV-002',
    '2026-08-01',
    '2026-08-31',
    'Draft',
    5000,
    v_user_id
  )
  returning id into v_invoice2_id;

  insert into invoice_lines (
    organization_id,
    invoice_id,
    account_id,
    line_number,
    description,
    amount_cents
  ) values (
    v_org_id,
    v_invoice2_id,
    v_revenue_account_id,
    1,
    'Services',
    5000
  );

  v_result := post_invoice(v_invoice2_id);
  if not (v_result->>'success')::boolean then
    raise exception 'Test 2 setup failed: %', v_result->>'error';
  end if;

  -- Issue full credit on 2026-08-20
  v_result := issue_credit_note(
    v_invoice2_id,
    '2026-08-20',
    5000,
    'Full refund'
  );

  if not (v_result->>'success')::boolean then
    raise exception 'Test 2 setup failed: %', v_result->>'error';
  end if;

  -- Test 2a: Should show full amount on as-of date between invoice and credit (2026-08-10)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-10')
  where invoice_id = v_invoice2_id;

  if v_amount is null or v_amount != 5000 then
    raise exception 'Test 2a failed: Invoice should show full amount before credit date (got %)', v_amount;
  end if;
  raise notice 'Test 2a passed: Invoice shows full amount on as-of date before credit';

  -- Test 2b: Should NOT show on as-of date on credit date (2026-08-20)
  select count(*) into v_count
  from get_ar_aging(v_org_id, '2026-08-20')
  where invoice_id = v_invoice2_id;

  if v_count != 0 then
    raise exception 'Test 2b failed: Invoice should not appear on as-of date at credit date';
  end if;
  raise notice 'Test 2b passed: Invoice does not show on as-of date at credit date';

  -- Test 2c: Should NOT show on as-of date after credit (2026-08-25)
  select count(*) into v_count
  from get_ar_aging(v_org_id, '2026-08-25')
  where invoice_id = v_invoice2_id;

  if v_count != 0 then
    raise exception 'Test 2c failed: Invoice should not appear after credit date';
  end if;
  raise notice 'Test 2c passed: Invoice does not show after credit date';

  raise notice '=== Test 3: Invoice with partial receipt ===';
  -- Create Invoice 3: Posted 2026-08-01, partial receipt 3000 on 2026-08-15
  insert into invoices (
    organization_id,
    customer_id,
    number,
    invoice_date,
    due_date,
    status,
    total_cents,
    created_by
  ) values (
    v_org_id,
    v_customer_id,
    'INV-003',
    '2026-08-01',
    '2026-08-31',
    'Draft',
    5000,
    v_user_id
  )
  returning id into v_invoice3_id;

  insert into invoice_lines (
    organization_id,
    invoice_id,
    account_id,
    line_number,
    description,
    amount_cents
  ) values (
    v_org_id,
    v_invoice3_id,
    v_revenue_account_id,
    1,
    'Services',
    5000
  );

  v_result := post_invoice(v_invoice3_id);
  if not (v_result->>'success')::boolean then
    raise exception 'Test 3 setup failed: %', v_result->>'error';
  end if;

  -- Record partial receipt on 2026-08-15
  v_result := record_receipt(
    v_invoice3_id,
    '2026-08-15',
    3000,
    v_cash_account_id,
    'Partial payment'
  );

  if not (v_result->>'success')::boolean then
    raise exception 'Test 3 setup failed: %', v_result->>'error';
  end if;

  -- Test 3a: Should show full amount on as-of date before receipt (2026-08-10)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-10')
  where invoice_id = v_invoice3_id;

  if v_amount is null or v_amount != 5000 then
    raise exception 'Test 3a failed: Invoice should show full amount before receipt (got %)', v_amount;
  end if;
  raise notice 'Test 3a passed: Invoice shows full amount before receipt';

  -- Test 3b: Should show remaining amount on as-of date at receipt date (2026-08-15)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-15')
  where invoice_id = v_invoice3_id;

  if v_amount is null or v_amount != 2000 then
    raise exception 'Test 3b failed: Invoice should show remaining amount (got %)', v_amount;
  end if;
  raise notice 'Test 3b passed: Invoice shows remaining amount at receipt date';

  -- Test 3c: Should show remaining amount on as-of date after receipt (2026-08-25)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-25')
  where invoice_id = v_invoice3_id;

  if v_amount is null or v_amount != 2000 then
    raise exception 'Test 3c failed: Invoice should show remaining amount (got %)', v_amount;
  end if;
  raise notice 'Test 3c passed: Invoice shows remaining amount after receipt';

  raise notice '=== Test 4: Zero remaining omitted ===';
  -- Complete payment on Invoice 3
  v_result := record_receipt(
    v_invoice3_id,
    '2026-08-20',
    2000,
    v_cash_account_id,
    'Final payment'
  );

  if not (v_result->>'success')::boolean then
    raise exception 'Test 4 setup failed: %', v_result->>'error';
  end if;

  -- Test 4a: Should still show remaining on as-of before final payment (2026-08-18)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-18')
  where invoice_id = v_invoice3_id;

  if v_amount is null or v_amount != 2000 then
    raise exception 'Test 4a failed: Invoice should show remaining before final payment (got %)', v_amount;
  end if;
  raise notice 'Test 4a passed: Invoice shows remaining before final payment';

  -- Test 4b: Should NOT show on as-of at or after final payment (2026-08-20)
  select count(*) into v_count
  from get_ar_aging(v_org_id, '2026-08-20')
  where invoice_id = v_invoice3_id;

  if v_count != 0 then
    raise exception 'Test 4b failed: Invoice with zero remaining should not appear';
  end if;
  raise notice 'Test 4b passed: Invoice with zero remaining does not show';

  -- Test 4c: Should NOT show on today (after final payment)
  select count(*) into v_count
  from get_ar_aging(v_org_id, current_date)
  where invoice_id = v_invoice3_id;

  if v_count != 0 then
    raise exception 'Test 4c failed: Invoice with zero remaining should not appear on current date';
  end if;
  raise notice 'Test 4c passed: Invoice with zero remaining does not show on current date';

  raise notice '=== Test 5: Multiple receipts on same invoice ===';
  -- Test Invoice 1 still shows (no receipts yet)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, current_date)
  where invoice_id = v_invoice1_id;

  if v_amount is null or v_amount != 10000 then
    raise exception 'Test 5a failed: Invoice 1 should show full amount (got %)', v_amount;
  end if;
  raise notice 'Test 5a passed: Invoice 1 shows full amount';

  -- Add a receipt and a write-off
  v_result := record_receipt(
    v_invoice1_id,
    '2026-08-10',
    6000,
    v_cash_account_id,
    'Partial payment'
  );

  if not (v_result->>'success')::boolean then
    raise exception 'Test 5 setup failed: %', v_result->>'error';
  end if;

  v_result := write_off_invoice(
    v_invoice1_id,
    '2026-08-25',
    4000,
    'Customer default'
  );

  if not (v_result->>'success')::boolean then
    raise exception 'Test 5 setup failed: %', v_result->>'error';
  end if;

  -- Test 5b: As-of 2026-08-09 should show full amount (before any receipts)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-09')
  where invoice_id = v_invoice1_id;

  if v_amount is null or v_amount != 10000 then
    raise exception 'Test 5b failed: Should show full amount before receipts (got %)', v_amount;
  end if;
  raise notice 'Test 5b passed: Shows full amount before receipts';

  -- Test 5c: As-of 2026-08-15 should show 4000 (after first receipt, before write-off)
  select amount_due_cents into v_amount
  from get_ar_aging(v_org_id, '2026-08-15')
  where invoice_id = v_invoice1_id;

  if v_amount is null or v_amount != 4000 then
    raise exception 'Test 5c failed: Should show 4000 after partial payment (got %)', v_amount;
  end if;
  raise notice 'Test 5c passed: Shows correct remaining after partial payment';

  -- Test 5d: As-of 2026-08-25 (write-off date) should not show (fully resolved)
  select count(*) into v_count
  from get_ar_aging(v_org_id, '2026-08-25')
  where invoice_id = v_invoice1_id;

  if v_count != 0 then
    raise exception 'Test 5d failed: Should not show after write-off';
  end if;
  raise notice 'Test 5d passed: Does not show after write-off';

  -- Cleanup
  delete from organizations where id = v_org_id;
  
  raise notice '=== All AR aging as-of date tests passed! ✓ ===';
  
end;
$$ language plpgsql;
