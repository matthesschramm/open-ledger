-- Fixed-asset register. Journals stay the GL; this table is the source of
-- truth for cost, life, method, and IAS 16 notes.

alter table organizations
  add column if not exists capitalization_threshold_cents bigint not null default 100000
  check (capitalization_threshold_cents >= 0);

comment on column organizations.capitalization_threshold_cents is
  'Purchases below this amount should be expensed. register_fixed_asset refuses them.';

create table if not exists fixed_assets (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  number text not null,
  description text not null,
  class fixed_asset_class not null,
  status fixed_asset_status not null default 'in_use',
  serial_number text,
  location text,
  vendor_id uuid,
  source_bill_id uuid,
  acquisition_date date not null,
  in_service_date date not null,
  cost_cents bigint not null check (cost_cents > 0),
  residual_cents bigint not null default 0 check (residual_cents >= 0),
  useful_life_months int not null check (useful_life_months > 0),
  method depreciation_method not null default 'straight_line',
  asset_account_id uuid not null,
  accum_dep_account_id uuid not null,
  dep_expense_account_id uuid not null,
  accum_dep_cents bigint not null default 0 check (accum_dep_cents >= 0),
  brought_forward_accum_dep_cents bigint not null default 0 check (brought_forward_accum_dep_cents >= 0),
  brought_forward_as_of date,
  pledged boolean not null default false,
  idle boolean not null default false,
  component_parent_id uuid,
  recognition_journal_id uuid references journals(id),
  disposal_journal_id uuid references journals(id),
  disposal_date date,
  disposal_proceeds_cents bigint check (disposal_proceeds_cents is null or disposal_proceeds_cents >= 0),
  notes text,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, number),
  unique (id, organization_id),
  check (residual_cents <= cost_cents),
  check (in_service_date >= acquisition_date),
  check (accum_dep_cents <= cost_cents)
);

create index if not exists fixed_assets_organization_id_idx on fixed_assets(organization_id);
create index if not exists fixed_assets_class_idx on fixed_assets(organization_id, class);
create index if not exists fixed_assets_status_idx on fixed_assets(organization_id, status);

alter table fixed_assets
  add constraint fixed_assets_vendor_org_fkey
  foreign key (vendor_id, organization_id) references contacts(id, organization_id);

alter table fixed_assets
  add constraint fixed_assets_asset_account_org_fkey
  foreign key (asset_account_id, organization_id) references accounts(id, organization_id);

alter table fixed_assets
  add constraint fixed_assets_accum_account_org_fkey
  foreign key (accum_dep_account_id, organization_id) references accounts(id, organization_id);

alter table fixed_assets
  add constraint fixed_assets_expense_account_org_fkey
  foreign key (dep_expense_account_id, organization_id) references accounts(id, organization_id);

alter table fixed_assets
  add constraint fixed_assets_parent_org_fkey
  foreign key (component_parent_id, organization_id) references fixed_assets(id, organization_id);

create table if not exists fixed_asset_depreciation_runs (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  asset_id uuid not null,
  period_start date not null,
  period_end date not null,
  amount_cents bigint not null check (amount_cents >= 0),
  journal_id uuid not null references journals(id),
  created_at timestamptz not null default now(),
  unique (asset_id, period_start),
  check (period_start <= period_end)
);

alter table fixed_asset_depreciation_runs
  add constraint fixed_asset_depreciation_runs_asset_org_fkey
  foreign key (asset_id, organization_id) references fixed_assets(id, organization_id);

create index if not exists fixed_asset_depreciation_runs_org_idx
  on fixed_asset_depreciation_runs(organization_id, period_start);

comment on table fixed_assets is
  'Asset register. One row per item or component. Journals are generated from this table.';
comment on table fixed_asset_depreciation_runs is
  'One row per asset per month. Prevents a second depreciation journal for the same month.';

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table fixed_assets enable row level security;
alter table fixed_asset_depreciation_runs enable row level security;

create policy "Members can view fixed_assets"
  on fixed_assets for select
  using (organization_id = current_org_id());

create policy "Bookkeeper+ can create fixed_assets"
  on fixed_assets for insert
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

create policy "Bookkeeper+ can update unlocked fixed_asset fields"
  on fixed_assets for update
  using (organization_id = current_org_id() and has_role('bookkeeper'))
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

create policy "Members can view depreciation runs"
  on fixed_asset_depreciation_runs for select
  using (organization_id = current_org_id());

create policy "Bookkeeper+ can insert depreciation runs"
  on fixed_asset_depreciation_runs for insert
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

-- Source fields lock after a recognition journal exists. RPCs are SECURITY
-- DEFINER so they can still write accum, status, and disposal columns.
create or replace function enforce_fixed_asset_source_lock()
returns trigger
language plpgsql
as $$
begin
  if old.recognition_journal_id is null then
    return new;
  end if;

  if new.number is distinct from old.number
    or new.cost_cents is distinct from old.cost_cents
    or new.residual_cents is distinct from old.residual_cents
    or new.useful_life_months is distinct from old.useful_life_months
    or new.method is distinct from old.method
    or new.class is distinct from old.class
    or new.acquisition_date is distinct from old.acquisition_date
    or new.in_service_date is distinct from old.in_service_date
    or new.asset_account_id is distinct from old.asset_account_id
    or new.accum_dep_account_id is distinct from old.accum_dep_account_id
    or new.dep_expense_account_id is distinct from old.dep_expense_account_id
    or new.recognition_journal_id is distinct from old.recognition_journal_id
  then
    raise exception 'Posted fixed-asset source fields cannot be changed. Reverse the journal or dispose the asset.';
  end if;

  return new;
end;
$$;

create trigger enforce_fixed_asset_source_lock
  before update on fixed_assets
  for each row
  execute function enforce_fixed_asset_source_lock();

-- ---------------------------------------------------------------------------
-- Class accounts on every org
-- ---------------------------------------------------------------------------

create or replace function ensure_ppe_accounts(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into accounts (organization_id, code, name, type, category, is_header, is_cash, is_system, is_active)
  values
    (p_organization_id, '1550', 'Furniture and fixtures', 'Asset', 'Other', false, false, false, true),
    (p_organization_id, '1560', 'Leasehold improvements', 'Asset', 'Other', false, false, false, true),
    (p_organization_id, '1590', 'Accumulated depreciation - equipment', 'Asset', 'Other', false, false, false, true),
    (p_organization_id, '1591', 'Accumulated depreciation - furniture', 'Asset', 'Other', false, false, false, true),
    (p_organization_id, '1592', 'Accumulated depreciation - leasehold', 'Asset', 'Other', false, false, false, true),
    (p_organization_id, '1700', 'Intangible assets', 'Asset', 'Other', false, false, false, true),
    (p_organization_id, '1790', 'Accumulated amortization - intangibles', 'Asset', 'Other', false, false, false, true),
    (p_organization_id, '5120', 'Depreciation expense', 'Expense', 'Expense', false, false, false, true),
    (p_organization_id, '5130', 'Amortization expense', 'Expense', 'Expense', false, false, false, true),
    (p_organization_id, '6110', 'Gain or loss on asset disposal', 'Expense', 'Expense', false, false, false, true)
  on conflict (organization_id, code) do nothing;
end;
$$;

revoke all on function ensure_ppe_accounts(uuid) from public, anon, authenticated;
grant execute on function ensure_ppe_accounts(uuid) to service_role;

comment on function ensure_ppe_accounts is
  'Creates class-level PPE and intangible accounts if missing. Safe to call again.';

select ensure_ppe_accounts(id) from organizations;

-- New orgs get the same accounts after the locked CoA insert.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_org_name text;
begin
  if exists(select 1 from public.memberships where user_id = new.id) then
    return new;
  end if;

  if apply_invitation_for_user(new.id, new.email) is not null then
    return new;
  end if;

  v_org_name := coalesce(
    new.raw_user_meta_data->>'company_name',
    split_part(new.email, '@', 1) || '''s Organization'
  );

  insert into public.organizations (name, currency_code, timezone)
  values (v_org_name, 'USD', 'America/New_York')
  returning id into v_org_id;

  insert into public.memberships (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  insert into public.accounts (organization_id, code, name, type, category, is_header, is_cash, is_system, is_active) values
  (v_org_id, '1000', 'Cash', 'Asset', 'Cash', true, false, false, true),
  (v_org_id, '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1020', 'Savings / reserves', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1100', 'Accounts receivable', 'Asset', 'AR', false, false, true, true),
  (v_org_id, '1200', 'Prepaid expenses', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '1400', 'Due from parent', 'Asset', 'AR', false, false, false, true),
  (v_org_id, '1500', 'Computer and equipment', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '2000', 'Accounts payable', 'Liability', 'AP', false, false, true, true),
  (v_org_id, '2100', 'Accrued expenses', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '2200', 'Due to parent', 'Liability', 'AP', false, false, false, true),
  (v_org_id, '2300', 'Credit cards', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '3000', 'Common stock', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3100', 'Additional paid-in capital', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3200', 'Retained earnings', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3900', 'Opening balance equity', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '4000', 'Revenue', 'Revenue', 'Revenue', true, false, false, true),
  (v_org_id, '4010', 'Product / service revenue', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '4100', 'Other income', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '5000', 'Operating expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '5010', 'Contractors and professional', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5020', 'Legal and formation', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5030', 'Software and subscriptions', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5040', 'Banking and payments', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5050', 'Travel', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5060', 'Insurance', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5070', 'Payroll and benefits', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5080', 'Office and admin', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5090', 'Tax expense', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5110', 'Bad debt', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '6000', 'Other expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '6100', 'FX and rounding', 'Expense', 'Expense', false, false, false, true);

  perform ensure_ppe_accounts(v_org_id);

  return new;
end;
$$;

comment on function handle_new_user is
  'Joins a pending invitation when present; otherwise creates an org, owner membership, US CoA, and PPE accounts';
