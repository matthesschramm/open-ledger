-- Test atomic invoice posting: journal and invoice status must both succeed or fail

begin;

do $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_customer_id uuid;
  v_revenue_account_id uuid;
  v_invoice_id uuid;
  v_result jsonb;
  v_invoice_status text;
  v_journal_count int;
begin
  raise notice 'TEST: Atomic invoice posting';

  -- Setup
  insert into organizations (id, name) values ('10000000-0000-0000-0000-000000000001', 'Test Org') returning id into v_org_id;
  insert into users (id, email, password_hash) values ('10000000-0000-0000-0000-000000000001', 'owner@test.com', 'hash');
  v_user_id := '10000000-0000-0000-0000-000000000001';
  
  insert into memberships (organization_id, user_id, role, can_post)
  values (v_org_id, v_user_id, 'owner', true);

  -- Set JWT context for setup
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_id::text)::text, true);

  -- Create accounts
  insert into accounts (id, organization_id, code, name, account_type, normal_balance)
  values 
    ('10000000-0000-0000-0000-000000001100', v_org_id, '1100', 'Accounts Receivable', 'Asset', 'Debit'),
    ('10000000-0000-0000-0000-000000004010', v_org_id, '4010', 'Service Revenue', 'Revenue', 'Credit');

  v_revenue_account_id := '10000000-0000-0000-0000-000000004010';

  -- Create customer
  insert into contacts (id, organization_id, name, contact_type)
  values ('10000000-0000-0000-0000-000000000010', v_org_id, 'Test Customer', 'Customer')
  returning id into v_customer_id;

  -- Create draft invoice
  insert into invoices (id, organization_id, customer_id, number, invoice_date, status, total_cents, received_cents, created_by)
  values ('20000000-0000-0000-0000-000000000001', v_org_id, v_customer_id, 'INV-2026-0001', '2026-08-30', 'Draft', 100000, 0, v_user_id)
  returning id into v_invoice_id;

  insert into invoice_lines (organization_id, invoice_id, line_number, account_id, amount_cents, description)
  values (v_org_id, v_invoice_id, 1, v_revenue_account_id, 100000, 'Services');

  -- TEST 1: Successful post updates invoice status atomically
  raise notice 'TEST 1: Successful post updates invoice status';
  
  v_result := post_invoice(v_invoice_id, v_user_id);
  
  if not (v_result->>'success')::boolean then
    raise exception 'Post invoice failed: %', v_result->>'error';
  end if;

  select status into v_invoice_status from invoices where id = v_invoice_id;
  
  if v_invoice_status != 'Posted' then
    raise exception 'Invoice status is % but should be Posted', v_invoice_status;
  end if;

  select count(*) into v_journal_count from journals where organization_id = v_org_id and source = 'invoice';
  
  if v_journal_count != 1 then
    raise exception 'Expected 1 journal, found %', v_journal_count;
  end if;

  raise notice 'PASS: Invoice posted atomically with status Posted';

  -- TEST 2: Verify journal has correct entries (Dr 1100 / Cr 4010)
  raise notice 'TEST 2: Verify Dr 1100 / Cr Revenue';
  
  if not exists (
    select 1 from journal_lines jl
    join journals j on j.id = jl.journal_id
    where j.organization_id = v_org_id
      and j.source = 'invoice'
      and jl.account_id = '10000000-0000-0000-0000-000000001100'
      and jl.debit_cents = 100000
      and jl.credit_cents = 0
  ) then
    raise exception 'Missing Dr 1100 Accounts Receivable entry';
  end if;

  if not exists (
    select 1 from journal_lines jl
    join journals j on j.id = jl.journal_id
    where j.organization_id = v_org_id
      and j.source = 'invoice'
      and jl.account_id = v_revenue_account_id
      and jl.debit_cents = 0
      and jl.credit_cents = 100000
  ) then
    raise exception 'Missing Cr 4010 Revenue entry';
  end if;

  raise notice 'PASS: Journal has correct Dr 1100 / Cr 4010 entries';

  raise notice 'All atomic posting tests passed';
end;
$$;

rollback;
