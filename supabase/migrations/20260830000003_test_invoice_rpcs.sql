-- Open Ledger S2-6: Invoice RPC Tests
-- Tests for invoice posting, receipts, credit notes, and write-offs

-- Test setup: Create test data
do $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_customer_id uuid;
  v_revenue_account_id uuid;
  v_cash_account_id uuid;
  v_invoice_id uuid;
  v_result jsonb;
begin
  -- Create test organization
  insert into organizations (name, currency_code)
  values ('Test AR Org', 'USD')
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
  values (v_org_id, 'Customer', 'Acme Corp', 'billing@example.com')
  returning id into v_customer_id;

  -- Create test invoice
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
    'INV-2026-0001',
    '2026-08-01',
    '2026-08-31',
    'Draft',
    10000,
    v_user_id
  )
  returning id into v_invoice_id;

  -- Add invoice line
  insert into invoice_lines (
    organization_id,
    invoice_id,
    account_id,
    line_number,
    description,
    amount_cents
  ) values (
    v_org_id,
    v_invoice_id,
    v_revenue_account_id,
    1,
    'Consulting services',
    10000
  );

  raise notice 'Test setup complete: org_id=%, invoice_id=%', v_org_id, v_invoice_id;

  -- Test 1: Post invoice (should create Dr 1100 / Cr 4000 journal)
  raise notice 'Test 1: Post invoice';
  
  -- Set session variables (simulate authenticated user)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_id)::text, true);
  
  v_result := post_invoice(v_invoice_id);
  
  if not (v_result->>'success')::boolean then
    raise exception 'Test 1 failed: %', v_result->>'error';
  end if;
  
  -- Verify invoice status changed to Posted
  if not exists (
    select 1 from invoices
    where id = v_invoice_id
      and status = 'Posted'
      and recognition_journal_id is not null
  ) then
    raise exception 'Test 1 failed: Invoice status not updated';
  end if;
  
  -- Verify journal lines
  if not exists (
    select 1
    from journal_lines jl
    join journals j on j.id = jl.journal_id
    join invoices i on i.recognition_journal_id = j.id
    where i.id = v_invoice_id
      and jl.debit_cents = 10000
      and exists (
        select 1 from accounts
        where id = jl.account_id and code = '1100'
      )
  ) then
    raise exception 'Test 1 failed: AR debit not found';
  end if;
  
  if not exists (
    select 1
    from journal_lines jl
    join journals j on j.id = jl.journal_id
    join invoices i on i.recognition_journal_id = j.id
    where i.id = v_invoice_id
      and jl.credit_cents = 10000
      and jl.account_id = v_revenue_account_id
  ) then
    raise exception 'Test 1 failed: Revenue credit not found';
  end if;

  raise notice 'Test 1 passed: Invoice posted successfully';

  -- Test 2: Record receipt (Dr 1010 / Cr 1100)
  raise notice 'Test 2: Record receipt';
  
  v_result := record_receipt(
    v_invoice_id,
    '2026-08-15',
    6000,  -- Partial payment
    v_cash_account_id,
    'First payment'
  );
  
  if not (v_result->>'success')::boolean then
    raise exception 'Test 2 failed: %', v_result->>'error';
  end if;
  
  -- Verify invoice received_cents updated
  if not exists (
    select 1 from invoices
    where id = v_invoice_id
      and received_cents = 6000
      and status = 'Posted'  -- Still posted, not fully paid
  ) then
    raise exception 'Test 2 failed: Invoice received_cents not updated';
  end if;
  
  -- Verify receipt journal
  if not exists (
    select 1
    from invoice_receipts ir
    join journal_lines jl on jl.journal_id = ir.receipt_journal_id
    where ir.invoice_id = v_invoice_id
      and ir.receipt_type = 'payment'
      and ir.amount_cents = 6000
      and jl.debit_cents = 6000
      and jl.account_id = v_cash_account_id
  ) then
    raise exception 'Test 2 failed: Cash debit not found';
  end if;

  raise notice 'Test 2 passed: Receipt recorded successfully';

  -- Test 3: Issue credit note (Dr 4000 / Cr 1100)
  raise notice 'Test 3: Issue credit note';
  
  v_result := issue_credit_note(
    v_invoice_id,
    '2026-08-20',
    2000,  -- Credit $20
    'Service adjustment'
  );
  
  if not (v_result->>'success')::boolean then
    raise exception 'Test 3 failed: %', v_result->>'error';
  end if;
  
  -- Verify invoice received_cents updated
  if not exists (
    select 1 from invoices
    where id = v_invoice_id
      and received_cents = 8000  -- 6000 + 2000
      and status = 'Posted'
  ) then
    raise exception 'Test 3 failed: Invoice received_cents not updated';
  end if;
  
  -- Verify credit note journal
  if not exists (
    select 1
    from invoice_receipts ir
    join journal_lines jl on jl.journal_id = ir.receipt_journal_id
    where ir.invoice_id = v_invoice_id
      and ir.receipt_type = 'credit_note'
      and ir.amount_cents = 2000
      and jl.debit_cents = 2000
      and jl.account_id = v_revenue_account_id
  ) then
    raise exception 'Test 3 failed: Revenue debit not found';
  end if;

  raise notice 'Test 3 passed: Credit note issued successfully';

  -- Test 4: Write off remaining balance (Dr 5110 / Cr 1100)
  raise notice 'Test 4: Write off invoice';
  
  v_result := write_off_invoice(
    v_invoice_id,
    '2026-08-25',
    2000,  -- Write off remaining $20
    'Customer bankrupt'
  );
  
  if not (v_result->>'success')::boolean then
    raise exception 'Test 4 failed: %', v_result->>'error';
  end if;
  
  -- Verify invoice fully resolved
  if not exists (
    select 1 from invoices
    where id = v_invoice_id
      and received_cents = 10000
      and status = 'Paid'  -- Now fully resolved
  ) then
    raise exception 'Test 4 failed: Invoice not marked as Paid';
  end if;
  
  -- Verify write-off journal with bad debt account
  if not exists (
    select 1
    from invoice_receipts ir
    join journal_lines jl on jl.journal_id = ir.receipt_journal_id
    join accounts a on a.id = jl.account_id
    where ir.invoice_id = v_invoice_id
      and ir.receipt_type = 'write_off'
      and ir.amount_cents = 2000
      and jl.debit_cents = 2000
      and a.code = '5110'
  ) then
    raise exception 'Test 4 failed: Bad debt expense debit not found';
  end if;

  raise notice 'Test 4 passed: Invoice written off successfully';

  -- Test 5: Cannot post invoice twice
  raise notice 'Test 5: Cannot post already-posted invoice';
  
  v_result := post_invoice(v_invoice_id);
  
  if (v_result->>'success')::boolean then
    raise exception 'Test 5 failed: Should not allow posting already-posted invoice';
  end if;
  
  if v_result->>'error' != 'Invoice already posted' then
    raise exception 'Test 5 failed: Wrong error message: %', v_result->>'error';
  end if;

  raise notice 'Test 5 passed: Correctly rejected duplicate post';

  -- Test 6: AR aging report
  raise notice 'Test 6: AR aging report';
  
  -- Create a new unpaid invoice
  declare
    v_invoice2_id uuid;
  begin
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
      'INV-2026-0002',
      '2026-07-01',
      '2026-07-31',
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
      'Overdue consulting',
      5000
    );

    -- Post it
    v_result := post_invoice(v_invoice2_id);
    
    if not (v_result->>'success')::boolean then
      raise exception 'Test 6 setup failed: %', v_result->>'error';
    end if;

    -- Check AR aging
    if not exists (
      select 1
      from get_ar_aging(v_org_id, '2026-08-30')
      where invoice_id = v_invoice2_id
        and amount_due_cents = 5000
        and days_overdue > 0
    ) then
      raise exception 'Test 6 failed: Invoice not in AR aging';
    end if;

    raise notice 'Test 6 passed: AR aging report working';
  end;

  -- Cleanup
  delete from organizations where id = v_org_id;
  
  raise notice 'All tests passed! ✓';
  
end;
$$ language plpgsql;
