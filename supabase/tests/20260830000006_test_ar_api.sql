-- Open Ledger: Test AR API/MCP functionality
-- Tests for invoice posting via API, can_post gate, locked-month refuse, Parent validation, reminder audit-only

do $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_customer_id uuid;
  v_parent_id uuid;
  v_vendor_id uuid;
  v_revenue_account_id uuid;
  v_cash_account_id uuid;
  v_invoice_id uuid;
  v_result jsonb;
  v_period_id uuid;
begin
  raise notice 'TEST: AR API/MCP functionality';

  -- Setup: Create test organization
  insert into organizations (name, currency_code)
  values ('Test AR Org', 'USD')
  returning id into v_org_id;

  -- Create test user (owner)
  insert into users (email, full_name)
  values ('test-ar@example.com', 'Test AR User')
  returning id into v_user_id;

  insert into memberships (organization_id, user_id, role)
  values (v_org_id, v_user_id, 'owner');

  -- Create revenue account (4000)
  insert into accounts (organization_id, code, name, type, category, is_active)
  values (v_org_id, '4000', 'Service Revenue', 'Revenue', 'Revenue', true)
  returning id into v_revenue_account_id;

  -- Create cash account (1010)
  insert into accounts (organization_id, code, name, type, category, is_cash, is_active)
  values (v_org_id, '1010', 'Operating Cash', 'Asset', 'Cash', true, true)
  returning id into v_cash_account_id;

  -- Create Customer contact
  insert into contacts (organization_id, type, name, email, is_active)
  values (v_org_id, 'Customer', 'Customer', 'customer@example.com', true)
  returning id into v_customer_id;

  -- Create Parent contact (should NOT be invoiceable)
  insert into contacts (organization_id, type, name, is_active)
  values (v_org_id, 'Parent', 'Parent Company', true)
  returning id into v_parent_id;

  -- Create Vendor contact (should NOT be invoiceable)
  insert into contacts (organization_id, type, name, is_active)
  values (v_org_id, 'Vendor', 'Test Vendor', true)
  returning id into v_vendor_id;

  -- Set current user context
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_user_id::text,
    'app_metadata', jsonb_build_object('organization_id', v_org_id::text)
  )::text, false);

  -- ============================================================================
  -- TEST 1: Post invoice via RPC (mimics API/MCP path)
  -- ============================================================================
  raise notice 'TEST 1: Post invoice via RPC (API/MCP posting path)';

  -- Create draft invoice
  insert into invoices (
    organization_id,
    customer_id,
    number,
    invoice_date,
    due_date,
    status,
    total_cents,
    received_cents,
    created_by
  ) values (
    v_org_id,
    v_customer_id,
    'INV-2026-0001',
    '2026-08-15',
    '2026-09-15',
    'Draft',
    100000,
    0,
    v_user_id
  ) returning id into v_invoice_id;

  -- Add invoice line
  insert into invoice_lines (
    organization_id,
    invoice_id,
    line_number,
    account_id,
    amount_cents,
    description
  ) values (
    v_org_id,
    v_invoice_id,
    1,
    v_revenue_account_id,
    100000,
    'Professional services'
  );

  -- Post invoice
  v_result := post_invoice(v_invoice_id);

  if not (v_result->>'success')::boolean then
    raise exception 'TEST 1 FAILED: Post invoice failed: %', v_result->>'error';
  end if;

  -- Verify invoice status
  if not exists (
    select 1 from invoices
    where id = v_invoice_id
      and status = 'Posted'
      and recognition_journal_id is not null
  ) then
    raise exception 'TEST 1 FAILED: Invoice not marked Posted with journal';
  end if;

  -- Verify journal created: Dr 1100 / Cr Revenue
  if not exists (
    select 1 from journals j
    join journal_lines jl_debit on jl_debit.journal_id = j.id
    join journal_lines jl_credit on jl_credit.journal_id = j.id
    join accounts a_debit on a_debit.id = jl_debit.account_id
    join accounts a_credit on a_credit.id = jl_credit.account_id
    where j.organization_id = v_org_id
      and j.status = 'Posted'
      and a_debit.code = '1100'
      and jl_debit.debit_cents = 100000
      and jl_debit.credit_cents = 0
      and a_credit.code = '4000'
      and jl_credit.debit_cents = 0
      and jl_credit.credit_cents = 100000
  ) then
    raise exception 'TEST 1 FAILED: Journal entries incorrect for invoice';
  end if;

  raise notice 'TEST 1 PASSED: Invoice posted via RPC with correct Dr 1100 / Cr Revenue';

  -- ============================================================================
  -- TEST 2: Parent contact cannot be invoiced
  -- ============================================================================
  raise notice 'TEST 2: Parent contact cannot be invoiced';

  declare
    v_parent_invoice_id uuid;
  begin
    -- Create invoice for Parent
    insert into invoices (
      organization_id,
      customer_id,
      number,
      invoice_date,
      status,
      total_cents,
      received_cents,
      created_by
    ) values (
      v_org_id,
      v_parent_id,
      'INV-2026-0002',
      '2026-08-15',
      'Draft',
      50000,
      0,
      v_user_id
    ) returning id into v_parent_invoice_id;

    insert into invoice_lines (
      organization_id,
      invoice_id,
      line_number,
      account_id,
      amount_cents,
      description
    ) values (
      v_org_id,
      v_parent_invoice_id,
      1,
      v_revenue_account_id,
      50000,
      'Test'
    );

    -- Try to post (should fail)
    v_result := post_invoice(v_parent_invoice_id);

    if (v_result->>'success')::boolean then
      raise exception 'TEST 2 FAILED: Parent invoice should not be postable';
    end if;

    if v_result->>'error' not like '%Cannot invoice contact type%Parent%' then
      raise exception 'TEST 2 FAILED: Wrong error message: %', v_result->>'error';
    end if;

    raise notice 'TEST 2 PASSED: Parent contact refused with correct error';
  end;

  -- ============================================================================
  -- TEST 3: Locked month refuses posting
  -- ============================================================================
  raise notice 'TEST 3: Locked month refuses posting';

  declare
    v_locked_invoice_id uuid;
  begin
    -- Lock August 2026
    insert into accounting_periods (
      organization_id,
      year,
      month,
      status,
      closed_by,
      closed_at
    ) values (
      v_org_id,
      2026,
      8,
      'Locked',
      v_user_id,
      now()
    ) returning id into v_period_id;

    -- Create invoice in locked month
    insert into invoices (
      organization_id,
      customer_id,
      number,
      invoice_date,
      status,
      total_cents,
      received_cents,
      created_by
    ) values (
      v_org_id,
      v_customer_id,
      'INV-2026-0003',
      '2026-08-20',
      'Draft',
      75000,
      0,
      v_user_id
    ) returning id into v_locked_invoice_id;

    insert into invoice_lines (
      organization_id,
      invoice_id,
      line_number,
      account_id,
      amount_cents,
      description
    ) values (
      v_org_id,
      v_locked_invoice_id,
      1,
      v_revenue_account_id,
      75000,
      'Test'
    );

    -- Try to post (should fail)
    v_result := post_invoice(v_locked_invoice_id);

    if (v_result->>'success')::boolean then
      raise exception 'TEST 3 FAILED: Locked month invoice should not be postable';
    end if;

    if v_result->>'error' not like '%Locked%' or v_result->>'error' not like '%August 2026%' then
      raise exception 'TEST 3 FAILED: Error should name the locked month: %', v_result->>'error';
    end if;

    raise notice 'TEST 3 PASSED: Locked month refused with month name in error';
  end;

  -- ============================================================================
  -- TEST 4: Reminder logs audit event only (no journal, no email)
  -- ============================================================================
  raise notice 'TEST 4: Reminder logs audit event only';

  declare
    v_reminder_invoice_id uuid;
    v_audit_count int;
    v_journal_count_before int;
    v_journal_count_after int;
  begin
    -- Unlock period for this test
    update accounting_periods
    set status = 'Open'
    where id = v_period_id;

    -- Create and post an invoice
    insert into invoices (
      organization_id,
      customer_id,
      number,
      invoice_date,
      status,
      total_cents,
      received_cents,
      created_by
    ) values (
      v_org_id,
      v_customer_id,
      'INV-2026-0004',
      '2026-08-25',
      'Draft',
      60000,
      0,
      v_user_id
    ) returning id into v_reminder_invoice_id;

    insert into invoice_lines (
      organization_id,
      invoice_id,
      line_number,
      account_id,
      amount_cents,
      description
    ) values (
      v_org_id,
      v_reminder_invoice_id,
      1,
      v_revenue_account_id,
      60000,
      'Test'
    );

    v_result := post_invoice(v_reminder_invoice_id);
    if not (v_result->>'success')::boolean then
      raise exception 'TEST 4 FAILED: Could not post invoice: %', v_result->>'error';
    end if;

    -- Count journals before reminder
    select count(*) into v_journal_count_before
    from journals
    where organization_id = v_org_id;

    -- Send reminder
    v_result := send_invoice_reminder(v_reminder_invoice_id);

    if not (v_result->>'success')::boolean then
      raise exception 'TEST 4 FAILED: Reminder failed: %', v_result->>'error';
    end if;

    -- Count journals after reminder (should be same)
    select count(*) into v_journal_count_after
    from journals
    where organization_id = v_org_id;

    if v_journal_count_after != v_journal_count_before then
      raise exception 'TEST 4 FAILED: Reminder created a journal (should not)';
    end if;

    -- Verify audit event logged
    select count(*) into v_audit_count
    from audit_events
    where organization_id = v_org_id
      and entity_type = 'invoice'
      and entity_id = v_reminder_invoice_id
      and event_type = 'invoice_reminder_sent';

    if v_audit_count = 0 then
      raise exception 'TEST 4 FAILED: Reminder did not log audit event';
    end if;

    raise notice 'TEST 4 PASSED: Reminder logged audit event, no journal created';
  end;

  -- ============================================================================
  -- TEST 5: Record receipt (Dr 1010 / Cr 1100)
  -- ============================================================================
  raise notice 'TEST 5: Record receipt';

  v_result := record_receipt(
    p_invoice_id => v_invoice_id,
    p_receipt_date => '2026-08-28',
    p_amount_cents => 100000,
    p_cash_account_id => v_cash_account_id,
    p_notes => 'Full payment'
  );

  if not (v_result->>'success')::boolean then
    raise exception 'TEST 5 FAILED: Receipt failed: %', v_result->>'error';
  end if;

  -- Verify receipt journal: Dr 1010 / Cr 1100
  if not exists (
    select 1 from journals j
    join journal_lines jl_debit on jl_debit.journal_id = j.id
    join journal_lines jl_credit on jl_credit.journal_id = j.id
    join accounts a_debit on a_debit.id = jl_debit.account_id
    join accounts a_credit on a_credit.id = jl_credit.account_id
    where j.organization_id = v_org_id
      and j.status = 'Posted'
      and a_debit.code = '1010'
      and jl_debit.debit_cents = 100000
      and a_credit.code = '1100'
      and jl_credit.credit_cents = 100000
  ) then
    raise exception 'TEST 5 FAILED: Receipt journal incorrect';
  end if;

  -- Verify invoice marked Paid
  if not exists (
    select 1 from invoices
    where id = v_invoice_id
      and status = 'Paid'
      and received_cents = 100000
  ) then
    raise exception 'TEST 5 FAILED: Invoice not marked Paid';
  end if;

  raise notice 'TEST 5 PASSED: Receipt recorded with Dr 1010 / Cr 1100';

  -- ============================================================================
  -- TEST 6: Write-off (Dr 5110 / Cr 1100)
  -- ============================================================================
  raise notice 'TEST 6: Write-off bad debt';

  declare
    v_writeoff_invoice_id uuid;
  begin
    -- Create and post another invoice
    insert into invoices (
      organization_id,
      customer_id,
      number,
      invoice_date,
      status,
      total_cents,
      received_cents,
      created_by
    ) values (
      v_org_id,
      v_customer_id,
      'INV-2026-0005',
      '2026-08-26',
      'Draft',
      50000,
      0,
      v_user_id
    ) returning id into v_writeoff_invoice_id;

    insert into invoice_lines (
      organization_id,
      invoice_id,
      line_number,
      account_id,
      amount_cents,
      description
    ) values (
      v_org_id,
      v_writeoff_invoice_id,
      1,
      v_revenue_account_id,
      50000,
      'Test'
    );

    v_result := post_invoice(v_writeoff_invoice_id);
    if not (v_result->>'success')::boolean then
      raise exception 'TEST 6 FAILED: Could not post invoice: %', v_result->>'error';
    end if;

    -- Write off
    v_result := write_off_invoice(
      p_invoice_id => v_writeoff_invoice_id,
      p_write_off_date => '2026-08-29',
      p_amount_cents => 50000,
      p_reason => 'Uncollectible'
    );

    if not (v_result->>'success')::boolean then
      raise exception 'TEST 6 FAILED: Write-off failed: %', v_result->>'error';
    end if;

    -- Verify write-off journal: Dr 5110 / Cr 1100
    if not exists (
      select 1 from journals j
      join journal_lines jl_debit on jl_debit.journal_id = j.id
      join journal_lines jl_credit on jl_credit.journal_id = j.id
      join accounts a_debit on a_debit.id = jl_debit.account_id
      join accounts a_credit on a_credit.id = jl_credit.account_id
      where j.organization_id = v_org_id
        and j.status = 'Posted'
        and a_debit.code = '5110'
        and jl_debit.debit_cents = 50000
        and a_credit.code = '1100'
        and jl_credit.credit_cents = 50000
    ) then
      raise exception 'TEST 6 FAILED: Write-off journal incorrect';
    end if;

    raise notice 'TEST 6 PASSED: Write-off recorded with Dr 5110 / Cr 1100';
  end;

  raise notice 'ALL AR API/MCP TESTS PASSED';
end;
$$;
