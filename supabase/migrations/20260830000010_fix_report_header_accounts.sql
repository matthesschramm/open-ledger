-- Fix financial reports to include posted activity on header accounts
-- Bug: Trial balance excludes header accounts with posted lines (e.g., 4000 Revenue is_header=true)
--      causing TB not to balance after posting Dr 1100 / Cr 4000
-- Fix: Remove is_header filter when summing journal lines - pure GL rule
--      Empty headers still excluded via existing non-zero balance filter

-- ============================================================================
-- TRIAL BALANCE
-- ============================================================================

create or replace function get_trial_balance(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  account_id uuid,
  account_code text,
  account_name text,
  account_type account_type,
  debit_cents bigint,
  credit_cents bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
  with account_balances as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      a.is_header,
      coalesce(sum(jl.debit_cents), 0)::bigint as total_debit,
      coalesce(sum(jl.credit_cents), 0)::bigint as total_credit
    from public.accounts a
    left join public.journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join public.journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      -- REMOVED: and a.is_header = false (pure GL must include header accounts with posted lines)
      and (j.id is null or (j.status in ('Posted', 'Reversed') and j.entry_date <= p_as_of_date))
    group by a.id, a.code, a.name, a.type, a.is_header
  )
  select
    ab.account_id,
    ab.account_code,
    ab.account_name,
    ab.account_type,
    case
      when (ab.total_debit - ab.total_credit) > 0 then (ab.total_debit - ab.total_credit)::bigint
      else 0::bigint
    end as debit_cents,
    case
      when (ab.total_debit - ab.total_credit) < 0 then (-(ab.total_debit - ab.total_credit))::bigint
      else 0::bigint
    end as credit_cents
  from account_balances ab
  where ab.total_debit != 0 or ab.total_credit != 0  -- Empty headers still excluded
  order by ab.account_code;
end;
$$;

comment on function get_trial_balance is 'Pure GL trial balance with accounts on their natural balance side. Includes header accounts with posted activity.';

-- ============================================================================
-- BALANCE SHEET
-- ============================================================================

create or replace function get_balance_sheet(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  section text,
  account_id uuid,
  account_code text,
  account_name text,
  account_type account_type,
  balance_cents bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
  with account_balances as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      a.is_header,
      (coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0))::bigint as signed_balance
    from public.accounts a
    left join public.journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join public.journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      -- REMOVED: and a.is_header = false (pure GL must include header accounts with posted lines)
      and (j.id is null or (j.status in ('Posted', 'Reversed') and j.entry_date <= p_as_of_date))
    group by a.id, a.code, a.name, a.type, a.is_header
  ),
  revenue_expense_total as (
    select (-coalesce(sum(signed_balance), 0))::bigint as net_income
    from account_balances
    where account_type in ('Revenue', 'Expense')
  )
  select
    case
      when ab.account_type = 'Asset' then 'Assets'
      when ab.account_type = 'Liability' then 'Liabilities'
      when ab.account_type = 'Equity' then 'Equity'
    end as section,
    ab.account_id,
    ab.account_code,
    ab.account_name,
    ab.account_type,
    case
      when ab.account_type in ('Liability', 'Equity') then (-ab.signed_balance)::bigint
      else ab.signed_balance::bigint
    end as balance_cents
  from account_balances ab
  where ab.account_type in ('Asset', 'Liability', 'Equity')
    and ab.signed_balance != 0  -- Empty headers still excluded
  
  union all
  
  select
    'Equity' as section,
    null as account_id,
    'NI' as account_code,
    'Net Income (Current Period)' as account_name,
    'Equity'::account_type as account_type,
    net_income as balance_cents
  from revenue_expense_total
  where net_income != 0
  
  order by
    case section
      when 'Assets' then 1
      when 'Liabilities' then 2
      when 'Equity' then 3
    end,
    account_code;
end;
$$;

comment on function get_balance_sheet is 'Balance Sheet: Assets = Liabilities + Equity (including net income). Includes header accounts with posted activity.';

-- ============================================================================
-- PROFIT & LOSS
-- ============================================================================

create or replace function get_profit_and_loss(
  p_organization_id uuid,
  p_start_date date,
  p_end_date date
)
returns table (
  section text,
  account_id uuid,
  account_code text,
  account_name text,
  account_type account_type,
  amount_cents bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
  with account_activity as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      (coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0))::bigint as signed_amount
    from public.accounts a
    left join public.journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join public.journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      -- REMOVED: and a.is_header = false (pure GL must include header accounts with posted lines)
      and a.type in ('Revenue', 'Expense')
      and (j.id is null or (
        j.status in ('Posted', 'Reversed')
        and j.entry_date between p_start_date and p_end_date
      ))
    group by a.id, a.code, a.name, a.type
  )
  select
    case
      when aa.account_type = 'Revenue' then 'Revenue'
      when aa.account_type = 'Expense' then 'Expenses'
    end as section,
    aa.account_id,
    aa.account_code,
    aa.account_name,
    aa.account_type,
    case
      when aa.account_type = 'Revenue' then (-aa.signed_amount)::bigint
      else aa.signed_amount::bigint
    end as amount_cents
  from account_activity aa
  where aa.signed_amount != 0  -- Empty headers still excluded
  order by
    case section
      when 'Revenue' then 1
      when 'Expenses' then 2
    end,
    account_code;
end;
$$;

comment on function get_profit_and_loss is 'Profit & Loss (activity for a period): Revenue and Expense accounts. Includes header accounts with posted activity.';
