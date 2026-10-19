-- Fixed-asset RPCs. All posts go through post_journal so period locks apply.

create or replace function ppe_next_journal_number(p_organization_id uuid, p_entry_date date)
returns text
language plpgsql
as $$
declare
  v_count int;
begin
  select count(*) into v_count
  from journals
  where organization_id = p_organization_id;

  return format(
    'JE-%s-%s',
    extract(year from p_entry_date)::int,
    lpad((v_count + 1)::text, 4, '0')
  );
end;
$$;

create or replace function ppe_next_asset_number(p_organization_id uuid, p_acquisition_date date)
returns text
language plpgsql
as $$
declare
  v_year int := extract(year from p_acquisition_date)::int;
  v_count int;
begin
  select count(*) into v_count
  from fixed_assets
  where organization_id = p_organization_id
    and number like 'FA-' || v_year::text || '-%';

  return format('FA-%s-%s', v_year, lpad((v_count + 1)::text, 4, '0'));
end;
$$;

create or replace function ppe_default_accounts(
  p_organization_id uuid,
  p_class fixed_asset_class,
  out asset_account_id uuid,
  out accum_dep_account_id uuid,
  out dep_expense_account_id uuid
)
language plpgsql
as $$
declare
  v_asset_code text;
  v_accum_code text;
  v_exp_code text;
begin
  perform ensure_ppe_accounts(p_organization_id);

  case p_class
    when 'equipment' then
      v_asset_code := '1500'; v_accum_code := '1590'; v_exp_code := '5120';
    when 'furniture' then
      v_asset_code := '1550'; v_accum_code := '1591'; v_exp_code := '5120';
    when 'leasehold_improvements' then
      v_asset_code := '1560'; v_accum_code := '1592'; v_exp_code := '5120';
    when 'intangible' then
      v_asset_code := '1700'; v_accum_code := '1790'; v_exp_code := '5130';
  end case;

  select id into asset_account_id
  from accounts
  where organization_id = p_organization_id and code = v_asset_code and is_active;

  select id into accum_dep_account_id
  from accounts
  where organization_id = p_organization_id and code = v_accum_code and is_active;

  select id into dep_expense_account_id
  from accounts
  where organization_id = p_organization_id and code = v_exp_code and is_active;

  if asset_account_id is null or accum_dep_account_id is null or dep_expense_account_id is null then
    raise exception 'Default accounts for class % are missing. Create % / % / % first.',
      p_class, v_asset_code, v_accum_code, v_exp_code;
  end if;
end;
$$;

create or replace function ppe_charge_cents(
  p_cost_cents bigint,
  p_residual_cents bigint,
  p_useful_life_months int,
  p_accum_dep_cents bigint,
  p_in_service_date date,
  p_period_start date
)
returns bigint
language plpgsql
immutable
as $$
declare
  v_depreciable bigint;
  v_monthly bigint;
  v_remaining bigint;
  v_month_index int;
begin
  v_depreciable := p_cost_cents - p_residual_cents;
  if v_depreciable <= 0 then
    return 0;
  end if;

  v_remaining := v_depreciable - p_accum_dep_cents;
  if v_remaining <= 0 then
    return 0;
  end if;

  v_monthly := v_depreciable / p_useful_life_months;
  if v_monthly < 0 then
    v_monthly := 0;
  end if;

  v_month_index :=
    (extract(year from p_period_start)::int - extract(year from date_trunc('month', p_in_service_date))::int) * 12
    + (extract(month from p_period_start)::int - extract(month from p_in_service_date)::int)
    + 1;

  if v_month_index < 1 then
    return 0;
  end if;

  if v_month_index >= p_useful_life_months or v_monthly = 0 then
    return v_remaining;
  end if;

  return least(v_monthly, v_remaining);
end;
$$;

create or replace function ppe_require_org_account(
  p_organization_id uuid,
  p_account_id uuid,
  p_expected_types account_type[],
  p_label text
)
returns accounts
language plpgsql
as $$
declare
  v_account accounts;
begin
  select * into v_account
  from accounts
  where id = p_account_id
    and organization_id = p_organization_id;

  if not found then
    raise exception '% must belong to the organization', p_label;
  end if;
  if v_account.is_header then
    raise exception '% cannot be a header account', p_label;
  end if;
  if not v_account.is_active then
    raise exception '% must be active', p_label;
  end if;
  if p_expected_types is not null and not (v_account.type = any (p_expected_types)) then
    raise exception '% must be one of: %', p_label, p_expected_types;
  end if;

  return v_account;
end;
$$;

create or replace function ppe_post_or_raise(p_journal_id uuid, p_user_id uuid)
returns void
language plpgsql
as $$
declare
  v_result jsonb;
begin
  v_result := post_journal(p_journal_id, p_user_id);
  if coalesce(v_result->>'success', 'false') <> 'true' then
    raise exception '%', coalesce(v_result->>'error', 'Failed to post journal');
  end if;
end;
$$;

-- ============================================================================
-- REGISTER
-- ============================================================================

create or replace function register_fixed_asset(
  p_description text,
  p_class text,
  p_cost_cents bigint,
  p_useful_life_months int,
  p_acquisition_date date,
  p_in_service_date date,
  p_residual_cents bigint default 0,
  p_asset_account_id uuid default null,
  p_accum_dep_account_id uuid default null,
  p_dep_expense_account_id uuid default null,
  p_credit_account_id uuid default null,
  p_post_acquisition boolean default true,
  p_existing_journal_id uuid default null,
  p_brought_forward_accum_dep_cents bigint default 0,
  p_brought_forward_as_of date default null,
  p_brought_forward_journal_id uuid default null,
  p_vendor_id uuid default null,
  p_source_bill_id uuid default null,
  p_serial_number text default null,
  p_location text default null,
  p_notes text default null,
  p_pledged boolean default false,
  p_idle boolean default false,
  p_component_parent_id uuid default null,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_user_id uuid;
  v_class fixed_asset_class;
  v_threshold bigint;
  v_defaults record;
  v_asset_account_id uuid;
  v_accum_id uuid;
  v_exp_id uuid;
  v_credit accounts;
  v_journal_id uuid;
  v_asset_id uuid;
  v_number text;
  v_bf bigint := coalesce(p_brought_forward_accum_dep_cents, 0);
  v_bf_journal uuid;
  v_bf_start date;
begin
  perform assume_request_user(p_user_id);
  v_user_id := auth.uid();
  if v_user_id is null then
    return jsonb_build_object('success', false, 'error', 'Not authenticated');
  end if;

  v_organization_id := current_org_id();
  if v_organization_id is null then
    return jsonb_build_object('success', false, 'error', 'No organization found');
  end if;

  if not has_role('bookkeeper') then
    return jsonb_build_object('success', false, 'error', 'Permission denied: bookkeeper role or higher required');
  end if;

  begin
    v_class := p_class::fixed_asset_class;
  exception when others then
    return jsonb_build_object(
      'success', false,
      'error', 'class must be equipment, furniture, leasehold_improvements, or intangible'
    );
  end;

  if p_description is null or trim(p_description) = '' then
    return jsonb_build_object('success', false, 'error', 'description is required');
  end if;
  if p_cost_cents is null or p_cost_cents <= 0 then
    return jsonb_build_object('success', false, 'error', 'cost_cents must be greater than zero');
  end if;
  if p_useful_life_months is null or p_useful_life_months <= 0 then
    return jsonb_build_object('success', false, 'error', 'useful_life_months must be greater than zero');
  end if;
  if p_acquisition_date is null or p_in_service_date is null then
    return jsonb_build_object('success', false, 'error', 'acquisition_date and in_service_date are required');
  end if;
  if p_in_service_date < p_acquisition_date then
    return jsonb_build_object('success', false, 'error', 'in_service_date cannot be before acquisition_date');
  end if;
  if coalesce(p_residual_cents, 0) < 0 or coalesce(p_residual_cents, 0) > p_cost_cents then
    return jsonb_build_object('success', false, 'error', 'residual_cents must be between 0 and cost_cents');
  end if;
  if v_bf < 0 or v_bf > p_cost_cents then
    return jsonb_build_object('success', false, 'error', 'brought_forward_accum_dep_cents is out of range');
  end if;

  select capitalization_threshold_cents into v_threshold
  from organizations
  where id = v_organization_id;

  if p_cost_cents < coalesce(v_threshold, 0) then
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cost %s is below the capitalization threshold of %s cents. Expense this purchase.',
        p_cost_cents,
        coalesce(v_threshold, 0)
      )
    );
  end if;

  if p_post_acquisition and p_existing_journal_id is not null then
    return jsonb_build_object(
      'success', false,
      'error', 'Pass either post_acquisition or existing_journal_id, not both'
    );
  end if;
  if not p_post_acquisition and p_existing_journal_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Set post_acquisition true, or pass existing_journal_id for an asset already on the books'
    );
  end if;

  select * into v_defaults from ppe_default_accounts(v_organization_id, v_class);
  v_asset_account_id := coalesce(p_asset_account_id, v_defaults.asset_account_id);
  v_accum_id := coalesce(p_accum_dep_account_id, v_defaults.accum_dep_account_id);
  v_exp_id := coalesce(p_dep_expense_account_id, v_defaults.dep_expense_account_id);

  perform ppe_require_org_account(v_organization_id, v_asset_account_id, array['Asset']::account_type[], 'asset_account_id');
  perform ppe_require_org_account(v_organization_id, v_accum_id, array['Asset']::account_type[], 'accum_dep_account_id');
  perform ppe_require_org_account(v_organization_id, v_exp_id, array['Expense']::account_type[], 'dep_expense_account_id');

  if p_vendor_id is not null and not exists (
    select 1 from contacts
    where id = p_vendor_id and organization_id = v_organization_id
  ) then
    return jsonb_build_object('success', false, 'error', 'vendor_id must belong to the organization');
  end if;

  if p_source_bill_id is not null and not exists (
    select 1 from bills
    where id = p_source_bill_id and organization_id = v_organization_id
  ) then
    return jsonb_build_object('success', false, 'error', 'source_bill_id must belong to the organization');
  end if;

  if p_component_parent_id is not null and not exists (
    select 1 from fixed_assets
    where id = p_component_parent_id and organization_id = v_organization_id
  ) then
    return jsonb_build_object('success', false, 'error', 'component_parent_id must belong to the organization');
  end if;

  if p_existing_journal_id is not null then
    if not exists (
      select 1 from journals
      where id = p_existing_journal_id
        and organization_id = v_organization_id
        and status in ('Posted', 'Reversed')
    ) then
      return jsonb_build_object('success', false, 'error', 'existing_journal_id must be a posted journal in this organization');
    end if;
    v_journal_id := p_existing_journal_id;
  end if;

  if p_post_acquisition then
    if p_credit_account_id is null then
      return jsonb_build_object('success', false, 'error', 'credit_account_id is required when posting the acquisition');
    end if;
    v_credit := ppe_require_org_account(
      v_organization_id,
      p_credit_account_id,
      array['Asset', 'Liability']::account_type[],
      'credit_account_id'
    );

    insert into journals (
      organization_id, number, entry_date, description, status, source, created_by
    ) values (
      v_organization_id,
      ppe_next_journal_number(v_organization_id, p_acquisition_date),
      p_acquisition_date,
      format('Fixed asset: %s', trim(p_description)),
      'Draft',
      'fixed_asset',
      v_user_id
    )
    returning id into v_journal_id;

    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
    values
      (v_organization_id, v_journal_id, v_asset_account_id, p_cost_cents, 0, trim(p_description)),
      (v_organization_id, v_journal_id, v_credit.id, 0, p_cost_cents, trim(p_description));

    perform ppe_post_or_raise(v_journal_id, v_user_id);
  end if;

  v_number := ppe_next_asset_number(v_organization_id, p_acquisition_date);

  insert into fixed_assets (
    organization_id, number, description, class, status,
    serial_number, location, vendor_id, source_bill_id,
    acquisition_date, in_service_date, cost_cents, residual_cents,
    useful_life_months, method,
    asset_account_id, accum_dep_account_id, dep_expense_account_id,
    accum_dep_cents, brought_forward_accum_dep_cents, brought_forward_as_of,
    pledged, idle, component_parent_id, recognition_journal_id, notes, created_by
  ) values (
    v_organization_id, v_number, trim(p_description), v_class, 'in_use',
    nullif(trim(coalesce(p_serial_number, '')), ''),
    nullif(trim(coalesce(p_location, '')), ''),
    p_vendor_id, p_source_bill_id,
    p_acquisition_date, p_in_service_date, p_cost_cents, coalesce(p_residual_cents, 0),
    p_useful_life_months, 'straight_line',
    v_asset_account_id, v_accum_id, v_exp_id,
    v_bf, v_bf, p_brought_forward_as_of,
    coalesce(p_pledged, false), coalesce(p_idle, false), p_component_parent_id,
    v_journal_id, nullif(trim(coalesce(p_notes, '')), ''), v_user_id
  )
  returning id into v_asset_id;

  if v_bf > 0 then
    v_bf_journal := coalesce(p_brought_forward_journal_id, v_journal_id);
    if v_bf_journal is null then
      raise exception 'brought_forward_accum_dep_cents requires a journal id so the month is not charged twice';
    end if;
    v_bf_start := date_trunc('month', coalesce(p_brought_forward_as_of, p_in_service_date))::date;
    insert into fixed_asset_depreciation_runs (
      organization_id, asset_id, period_start, period_end, amount_cents, journal_id
    ) values (
      v_organization_id,
      v_asset_id,
      v_bf_start,
      coalesce(p_brought_forward_as_of, (v_bf_start + interval '1 month - 1 day')::date),
      v_bf,
      v_bf_journal
    );
  end if;

  perform log_audit_event(
    'fixed_asset',
    v_asset_id,
    'asset_registered',
    jsonb_build_object(
      'number', v_number,
      'description', trim(p_description),
      'class', v_class,
      'cost_cents', p_cost_cents,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'asset_id', v_asset_id,
    'number', v_number,
    'journal_id', v_journal_id,
    'accum_dep_cents', v_bf
  );
exception
  when others then
    return jsonb_build_object('success', false, 'error', sqlerrm);
end;
$$;

-- ============================================================================
-- DEPRECIATION
-- ============================================================================

create or replace function run_depreciation(
  p_period_start date,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_user_id uuid;
  v_start date;
  v_end date;
  v_asset record;
  v_charge bigint;
  v_group record;
  v_journal_id uuid;
  v_journals uuid[] := '{}';
  v_charged_count int := 0;
  v_skipped_count int := 0;
  v_total bigint := 0;
  v_charges jsonb := '[]'::jsonb;
begin
  perform assume_request_user(p_user_id);
  v_user_id := auth.uid();
  if v_user_id is null then
    return jsonb_build_object('success', false, 'error', 'Not authenticated');
  end if;

  v_organization_id := current_org_id();
  if v_organization_id is null then
    return jsonb_build_object('success', false, 'error', 'No organization found');
  end if;
  if not has_role('bookkeeper') then
    return jsonb_build_object('success', false, 'error', 'Permission denied: bookkeeper role or higher required');
  end if;
  if p_period_start is null then
    return jsonb_build_object('success', false, 'error', 'period_start is required');
  end if;

  v_start := date_trunc('month', p_period_start)::date;
  v_end := (v_start + interval '1 month - 1 day')::date;

  create temporary table if not exists _ppe_dep_charges (
    asset_id uuid,
    expense_account_id uuid,
    accum_account_id uuid,
    amount_cents bigint,
    description text
  ) on commit drop;
  -- WHERE true satisfies PostgREST safeupdate (loaded on authenticator).
  delete from _ppe_dep_charges where true;

  for v_asset in
    select *
    from fixed_assets
    where organization_id = v_organization_id
      and status = 'in_use'
      and in_service_date <= v_end
      and (disposal_date is null or disposal_date > v_end)
    order by number
  loop
    if exists (
      select 1 from fixed_asset_depreciation_runs
      where asset_id = v_asset.id and period_start = v_start
    ) then
      v_skipped_count := v_skipped_count + 1;
      continue;
    end if;

    v_charge := ppe_charge_cents(
      v_asset.cost_cents,
      v_asset.residual_cents,
      v_asset.useful_life_months,
      v_asset.accum_dep_cents,
      v_asset.in_service_date,
      v_start
    );

    if v_charge <= 0 then
      v_skipped_count := v_skipped_count + 1;
      continue;
    end if;

    insert into _ppe_dep_charges
    values (v_asset.id, v_asset.dep_expense_account_id, v_asset.accum_dep_account_id, v_charge, v_asset.description);
  end loop;

  if not exists (select 1 from _ppe_dep_charges) then
    return jsonb_build_object(
      'success', true,
      'period_start', v_start,
      'period_end', v_end,
      'charged_count', 0,
      'skipped_count', v_skipped_count,
      'total_cents', 0,
      'journal_ids', '[]'::jsonb
    );
  end if;

  for v_group in
    select expense_account_id, accum_account_id, sum(amount_cents) as amount_cents
    from _ppe_dep_charges
    group by expense_account_id, accum_account_id
  loop
    insert into journals (
      organization_id, number, entry_date, description, status, source, created_by
    ) values (
      v_organization_id,
      ppe_next_journal_number(v_organization_id, v_end),
      v_end,
      format('Depreciation %s', to_char(v_start, 'Mon YYYY')),
      'Draft',
      'depreciation',
      v_user_id
    )
    returning id into v_journal_id;

    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
    values
      (
        v_organization_id, v_journal_id, v_group.expense_account_id,
        v_group.amount_cents, 0,
        format('Depreciation %s', to_char(v_start, 'Mon YYYY'))
      ),
      (
        v_organization_id, v_journal_id, v_group.accum_account_id,
        0, v_group.amount_cents,
        format('Depreciation %s', to_char(v_start, 'Mon YYYY'))
      );

    perform ppe_post_or_raise(v_journal_id, v_user_id);
    v_journals := array_append(v_journals, v_journal_id);

    insert into fixed_asset_depreciation_runs (
      organization_id, asset_id, period_start, period_end, amount_cents, journal_id
    )
    select v_organization_id, asset_id, v_start, v_end, amount_cents, v_journal_id
    from _ppe_dep_charges
    where expense_account_id = v_group.expense_account_id
      and accum_account_id = v_group.accum_account_id;

    update fixed_assets fa
    set
      accum_dep_cents = fa.accum_dep_cents + c.amount_cents,
      updated_at = now()
    from _ppe_dep_charges c
    where fa.id = c.asset_id
      and c.expense_account_id = v_group.expense_account_id
      and c.accum_account_id = v_group.accum_account_id;
  end loop;

  select count(*), coalesce(sum(amount_cents), 0), jsonb_agg(jsonb_build_object(
    'asset_id', asset_id,
    'amount_cents', amount_cents
  ))
  into v_charged_count, v_total, v_charges
  from _ppe_dep_charges;

  perform log_audit_event(
    'fixed_asset',
    v_organization_id,
    'depreciation_run',
    jsonb_build_object(
      'period_start', v_start,
      'period_end', v_end,
      'total_cents', v_total,
      'charged_count', v_charged_count
    )
  );

  return jsonb_build_object(
    'success', true,
    'period_start', v_start,
    'period_end', v_end,
    'charged_count', v_charged_count,
    'skipped_count', v_skipped_count,
    'total_cents', v_total,
    'journal_ids', to_jsonb(v_journals),
    'charges', coalesce(v_charges, '[]'::jsonb)
  );
exception
  when others then
    return jsonb_build_object('success', false, 'error', sqlerrm);
end;
$$;

-- ============================================================================
-- DISPOSE
-- ============================================================================

create or replace function dispose_fixed_asset(
  p_asset_id uuid,
  p_disposal_date date,
  p_proceeds_cents bigint default 0,
  p_cash_account_id uuid default null,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organization_id uuid;
  v_user_id uuid;
  v_asset fixed_assets;
  v_month_start date;
  v_month_end date;
  v_month_charge bigint := 0;
  v_accum bigint;
  v_nbv bigint;
  v_proceeds bigint := coalesce(p_proceeds_cents, 0);
  v_gain bigint;
  v_loss bigint;
  v_gain_loss_id uuid;
  v_journal_id uuid;
  v_cash accounts;
begin
  perform assume_request_user(p_user_id);
  v_user_id := auth.uid();
  if v_user_id is null then
    return jsonb_build_object('success', false, 'error', 'Not authenticated');
  end if;

  v_organization_id := current_org_id();
  if v_organization_id is null then
    return jsonb_build_object('success', false, 'error', 'No organization found');
  end if;
  if not has_role('bookkeeper') then
    return jsonb_build_object('success', false, 'error', 'Permission denied: bookkeeper role or higher required');
  end if;
  if p_asset_id is null or p_disposal_date is null then
    return jsonb_build_object('success', false, 'error', 'asset_id and disposal_date are required');
  end if;
  if v_proceeds < 0 then
    return jsonb_build_object('success', false, 'error', 'proceeds_cents cannot be negative');
  end if;

  select * into v_asset
  from fixed_assets
  where id = p_asset_id
    and organization_id = v_organization_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Asset not found');
  end if;
  if v_asset.status = 'disposed' then
    return jsonb_build_object('success', false, 'error', format('Asset %s is already disposed', v_asset.number));
  end if;
  if p_disposal_date < v_asset.acquisition_date then
    return jsonb_build_object('success', false, 'error', 'disposal_date cannot be before acquisition_date');
  end if;

  if v_proceeds > 0 then
    if p_cash_account_id is null then
      return jsonb_build_object('success', false, 'error', 'cash_account_id is required when proceeds_cents is greater than zero');
    end if;
    v_cash := ppe_require_org_account(
      v_organization_id, p_cash_account_id, array['Asset']::account_type[], 'cash_account_id'
    );
    if not v_cash.is_cash then
      return jsonb_build_object('success', false, 'error', 'cash_account_id must be an active cash account');
    end if;
  end if;

  perform ensure_ppe_accounts(v_organization_id);
  select id into v_gain_loss_id
  from accounts
  where organization_id = v_organization_id and code = '6110' and is_active;
  if v_gain_loss_id is null then
    return jsonb_build_object('success', false, 'error', 'Account 6110 Gain or loss on asset disposal is missing');
  end if;

  v_month_start := date_trunc('month', p_disposal_date)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;

  if v_asset.in_service_date <= p_disposal_date
    and not exists (
      select 1 from fixed_asset_depreciation_runs
      where asset_id = v_asset.id and period_start = v_month_start
    )
  then
    v_month_charge := ppe_charge_cents(
      v_asset.cost_cents,
      v_asset.residual_cents,
      v_asset.useful_life_months,
      v_asset.accum_dep_cents,
      v_asset.in_service_date,
      v_month_start
    );
  end if;

  v_accum := v_asset.accum_dep_cents + v_month_charge;
  v_nbv := v_asset.cost_cents - v_accum;
  if v_proceeds > v_nbv then
    v_gain := v_proceeds - v_nbv;
    v_loss := 0;
  else
    v_loss := v_nbv - v_proceeds;
    v_gain := 0;
  end if;

  insert into journals (
    organization_id, number, entry_date, description, status, source, created_by
  ) values (
    v_organization_id,
    ppe_next_journal_number(v_organization_id, p_disposal_date),
    p_disposal_date,
    format('Dispose %s %s', v_asset.number, v_asset.description),
    'Draft',
    'disposal',
    v_user_id
  )
  returning id into v_journal_id;

  if v_month_charge > 0 then
    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
    values
      (v_organization_id, v_journal_id, v_asset.dep_expense_account_id, v_month_charge, 0, 'Depreciation to disposal'),
      (v_organization_id, v_journal_id, v_asset.accum_dep_account_id, 0, v_month_charge, 'Depreciation to disposal');
  end if;

  if v_accum > 0 then
    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
    values (v_organization_id, v_journal_id, v_asset.accum_dep_account_id, v_accum, 0, 'Clear accumulated depreciation');
  end if;

  if v_proceeds > 0 then
    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
    values (v_organization_id, v_journal_id, p_cash_account_id, v_proceeds, 0, 'Disposal proceeds');
  end if;

  if v_loss > 0 then
    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
    values (v_organization_id, v_journal_id, v_gain_loss_id, v_loss, 0, 'Loss on disposal');
  end if;

  if v_gain > 0 then
    insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
    values (v_organization_id, v_journal_id, v_gain_loss_id, 0, v_gain, 'Gain on disposal');
  end if;

  insert into journal_lines (organization_id, journal_id, account_id, debit_cents, credit_cents, memo)
  values (v_organization_id, v_journal_id, v_asset.asset_account_id, 0, v_asset.cost_cents, 'Remove asset cost');

  perform ppe_post_or_raise(v_journal_id, v_user_id);

  if v_month_charge > 0 then
    insert into fixed_asset_depreciation_runs (
      organization_id, asset_id, period_start, period_end, amount_cents, journal_id
    ) values (
      v_organization_id, v_asset.id, v_month_start, v_month_end, v_month_charge, v_journal_id
    );
  end if;

  update fixed_assets
  set
    status = 'disposed',
    accum_dep_cents = v_accum,
    disposal_date = p_disposal_date,
    disposal_proceeds_cents = v_proceeds,
    disposal_journal_id = v_journal_id,
    updated_at = now()
  where id = v_asset.id;

  perform log_audit_event(
    'fixed_asset',
    v_asset.id,
    'asset_disposed',
    jsonb_build_object(
      'number', v_asset.number,
      'proceeds_cents', v_proceeds,
      'nbv_cents', v_nbv,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'asset_id', v_asset.id,
    'journal_id', v_journal_id,
    'nbv_cents', v_nbv,
    'proceeds_cents', v_proceeds,
    'gain_cents', v_gain,
    'loss_cents', v_loss,
    'month_depreciation_cents', v_month_charge
  );
exception
  when others then
    return jsonb_build_object('success', false, 'error', sqlerrm);
end;
$$;

-- ============================================================================
-- ROLLFORWARD (IAS 16.73)
-- ============================================================================

create or replace function get_ppe_rollforward(
  p_organization_id uuid,
  p_start_date date,
  p_end_date date
)
returns table (
  asset_class text,
  measurement_basis text,
  depreciation_method text,
  useful_lives text,
  opening_gross_cents bigint,
  additions_cents bigint,
  disposals_gross_cents bigint,
  closing_gross_cents bigint,
  opening_accum_cents bigint,
  depreciation_cents bigint,
  disposals_accum_cents bigint,
  closing_accum_cents bigint,
  opening_nbv_cents bigint,
  closing_nbv_cents bigint,
  pledged_cents bigint,
  idle_cents bigint,
  fully_depreciated_in_use_cents bigint
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if p_organization_id is null or p_organization_id is distinct from current_org_id() then
    if auth.uid() is not null and current_org_id() is distinct from p_organization_id then
      raise exception 'Permission denied';
    end if;
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'start_date and end_date are required, and end_date must be on or after start_date';
  end if;

  return query
  with assets as (
    select fa.*
    from fixed_assets fa
    where fa.organization_id = p_organization_id
  ),
  run_to_date as (
    select
      r.asset_id,
      coalesce(sum(r.amount_cents) filter (where r.period_end < p_start_date), 0)::bigint as opening_runs,
      coalesce(sum(r.amount_cents) filter (where r.period_start >= p_start_date and r.period_start <= p_end_date), 0)::bigint as period_runs
    from fixed_asset_depreciation_runs r
    where r.organization_id = p_organization_id
    group by r.asset_id
  ),
  classified as (
    select
      a.class::text as class_name,
      a.method::text as method_name,
      a.useful_life_months,
      a.cost_cents,
      a.residual_cents,
      a.pledged,
      a.idle,
      a.status,
      a.acquisition_date,
      a.disposal_date,
      coalesce(r.opening_runs, 0) as opening_accum,
      coalesce(r.period_runs, 0) as period_dep,
      case
        when a.disposal_date is not null and a.disposal_date >= p_start_date and a.disposal_date <= p_end_date
          then coalesce(r.opening_runs, 0) + coalesce(r.period_runs, 0)
        else 0
      end as disposal_accum,
      (a.acquisition_date < p_start_date and (a.disposal_date is null or a.disposal_date >= p_start_date)) as is_opening,
      (a.acquisition_date >= p_start_date and a.acquisition_date <= p_end_date) as is_addition,
      (a.disposal_date is not null and a.disposal_date >= p_start_date and a.disposal_date <= p_end_date) as is_disposal,
      (a.acquisition_date <= p_end_date and (a.disposal_date is null or a.disposal_date > p_end_date)) as is_closing
    from assets a
    left join run_to_date r on r.asset_id = a.id
  )
  select
    c.class_name,
    'cost'::text,
    case
      when min(c.method_name) = max(c.method_name) then replace(min(c.method_name), '_', '-')
      else 'mixed'
    end,
    case
      when min(c.useful_life_months) = max(c.useful_life_months)
        then min(c.useful_life_months)::text || ' months'
      else min(c.useful_life_months)::text || '-' || max(c.useful_life_months)::text || ' months'
    end,
    coalesce(sum(c.cost_cents) filter (where c.is_opening), 0)::bigint,
    coalesce(sum(c.cost_cents) filter (where c.is_addition), 0)::bigint,
    coalesce(sum(c.cost_cents) filter (where c.is_disposal), 0)::bigint,
    coalesce(sum(c.cost_cents) filter (where c.is_closing), 0)::bigint,
    coalesce(sum(c.opening_accum) filter (where c.is_opening), 0)::bigint,
    coalesce(sum(c.period_dep), 0)::bigint,
    coalesce(sum(c.disposal_accum), 0)::bigint,
    coalesce(sum(c.opening_accum + c.period_dep) filter (where c.is_closing), 0)::bigint,
    coalesce(sum(c.cost_cents - c.opening_accum) filter (where c.is_opening), 0)::bigint,
    coalesce(sum(c.cost_cents - c.opening_accum - c.period_dep) filter (where c.is_closing), 0)::bigint,
    coalesce(sum(c.cost_cents - c.opening_accum - c.period_dep) filter (where c.is_closing and c.pledged), 0)::bigint,
    coalesce(sum(c.cost_cents - c.opening_accum - c.period_dep) filter (where c.is_closing and c.idle), 0)::bigint,
    coalesce(sum(c.cost_cents) filter (
      where c.is_closing
        and c.status = 'in_use'
        and c.opening_accum + c.period_dep >= c.cost_cents - c.residual_cents
    ), 0)::bigint
  from classified c
  group by c.class_name
  order by c.class_name;
end;
$$;

grant execute on function register_fixed_asset(
  text, text, bigint, int, date, date, bigint, uuid, uuid, uuid, uuid, boolean, uuid, bigint, date, uuid, uuid, uuid, text, text, text, boolean, boolean, uuid, uuid
) to authenticated, service_role;

grant execute on function run_depreciation(date, uuid) to authenticated, service_role;
grant execute on function dispose_fixed_asset(uuid, date, bigint, uuid, uuid) to authenticated, service_role;
grant execute on function get_ppe_rollforward(uuid, date, date) to authenticated, service_role;

revoke all on function ppe_next_journal_number(uuid, date) from public, anon, authenticated;
revoke all on function ppe_next_asset_number(uuid, date) from public, anon, authenticated;
revoke all on function ppe_default_accounts(uuid, fixed_asset_class) from public, anon, authenticated;
revoke all on function ppe_charge_cents(bigint, bigint, int, bigint, date, date) from public, anon, authenticated;
revoke all on function ppe_require_org_account(uuid, uuid, account_type[], text) from public, anon, authenticated;
revoke all on function ppe_post_or_raise(uuid, uuid) from public, anon, authenticated;
