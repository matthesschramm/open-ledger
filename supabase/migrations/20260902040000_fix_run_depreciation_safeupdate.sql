-- PostgREST connects as authenticator, which loads safeupdate
-- (session_preload_libraries=supautils, safeupdate). That blocks
-- DELETE/UPDATE without a WHERE clause, including inside RPCs.
-- run_depreciation cleared a temp table with bare DELETE and returned
-- sqlerrm "DELETE requires a WHERE clause" to the UI.

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
  -- WHERE true satisfies safeupdate while clearing the temp table.
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
exception when others then
  return jsonb_build_object('success', false, 'error', sqlerrm);
end;
$$;

grant execute on function run_depreciation(date, uuid) to authenticated, service_role;
