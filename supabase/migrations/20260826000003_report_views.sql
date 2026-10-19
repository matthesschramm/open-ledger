-- Open Ledger Report Views and Functions
-- Phase 3: SQL views and functions for financial reports
-- Reports include all non-draft journals: Posted AND Reversed originals

-- ============================================================================
-- HELPER: Get Posted Journal Entries
-- ============================================================================

create or replace view posted_journals as
select *
from journals
where status in ('Posted', 'Reversed');

comment on view posted_journals is 'All non-draft journals: Posted entries and Reversed originals (both appear on reports)';

-- ============================================================================
-- ACCOUNT BALANCE CALCULATION
-- ============================================================================

create or replace function calculate_account_balance(
  p_organization_id uuid,
  p_account_id uuid,
  p_as_of_date date default null
)
returns bigint
language plpgsql
stable
as $$
declare
  v_account accounts;
  v_total_debit bigint;
  v_total_credit bigint;
  v_balance bigint;
begin
  -- Get account type
  select * into v_account
  from accounts
  where id = p_account_id;

  if not found then
    return 0;
  end if;

  -- Calculate totals from journal lines
  select
    coalesce(sum(jl.debit_cents), 0),
    coalesce(sum(jl.credit_cents), 0)
  into v_total_debit, v_total_credit
  from journal_lines jl
  join journals j on j.id = jl.journal_id
  where jl.account_id = p_account_id
    and jl.organization_id = p_organization_id
    and j.status in ('Posted', 'Reversed')
    and (p_as_of_date is null or j.entry_date <= p_as_of_date);

  -- Calculate signed balance (debit-positive)
  v_balance := v_total_debit - v_total_credit;

  return v_balance;
end;
$$;

comment on function calculate_account_balance is 'Returns signed balance (debit-positive) for an account as of a date';

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
as $$
begin
  return query
  with account_balances as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      a.is_header,
      coalesce(sum(jl.debit_cents), 0) as total_debit,
      coalesce(sum(jl.credit_cents), 0) as total_credit
    from accounts a
    left join journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      and a.is_header = false
      and (j.id is null or (j.status in ('Posted', 'Reversed') and j.entry_date <= p_as_of_date))
    group by a.id, a.code, a.name, a.type, a.is_header
  )
  select
    ab.account_id,
    ab.account_code,
    ab.account_name,
    ab.account_type,
    case
      when (ab.total_debit - ab.total_credit) > 0 then (ab.total_debit - ab.total_credit)
      else 0
    end as debit_cents,
    case
      when (ab.total_debit - ab.total_credit) < 0 then -(ab.total_debit - ab.total_credit)
      else 0
    end as credit_cents
  from account_balances ab
  where ab.total_debit != 0 or ab.total_credit != 0
  order by ab.account_code;
end;
$$;

comment on function get_trial_balance is 'Pure GL trial balance with accounts on their natural balance side';

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
as $$
begin
  return query
  with account_balances as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      a.is_header,
      coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0) as signed_balance
    from accounts a
    left join journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      and a.is_header = false
      and (j.id is null or (j.status in ('Posted', 'Reversed') and j.entry_date <= p_as_of_date))
    group by a.id, a.code, a.name, a.type, a.is_header
  ),
  revenue_expense_total as (
    -- Calculate net income from revenue and expense accounts
    -- signed = debit - credit (debit-positive)
    -- Revenue: credit-normal, so negative signed means revenue earned
    -- Expense: debit-normal, so positive signed means expense incurred
    -- Net Income = -sum(signed of all revenue+expense)
    --   = -(negative revenue signed + positive expense signed)
    --   = revenue - expenses
    select -coalesce(sum(signed_balance), 0) as net_income
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
      -- For credit-normal accounts (Liability, Equity), negate to show as positive
      when ab.account_type in ('Liability', 'Equity') then -ab.signed_balance
      else ab.signed_balance
    end as balance_cents
  from account_balances ab
  where ab.account_type in ('Asset', 'Liability', 'Equity')
    and ab.signed_balance != 0
  
  union all
  
  -- Add net income as a computed equity line
  select
    'Equity' as section,
    null as account_id,
    'NI' as account_code,
    'Net Income (Current Period)' as account_name,
    'Equity' as account_type,
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

comment on function get_balance_sheet is 'Balance Sheet: Assets = Liabilities + Equity (including net income)';

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
as $$
begin
  return query
  with account_activity as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0) as signed_amount
    from accounts a
    left join journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      and a.is_header = false
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
      -- Revenue is credit-normal, show as positive when credited
      when aa.account_type = 'Revenue' then -aa.signed_amount
      -- Expense is debit-normal, show as positive when debited
      else aa.signed_amount
    end as amount_cents
  from account_activity aa
  where aa.signed_amount != 0
  order by
    case section
      when 'Revenue' then 1
      when 'Expenses' then 2
    end,
    account_code;
end;
$$;

comment on function get_profit_and_loss is 'Profit & Loss (activity for a period): Revenue and Expense accounts';

-- ============================================================================
-- CASH MOVEMENT
-- ============================================================================

create or replace function get_cash_movement(
  p_organization_id uuid,
  p_start_date date,
  p_end_date date
)
returns table (
  counter_account_id uuid,
  counter_account_code text,
  counter_account_name text,
  counter_account_type account_type,
  net_change_cents bigint
)
language plpgsql
stable
as $$
begin
  return query
  with cash_accounts as (
    select id
    from accounts
    where organization_id = p_organization_id
      and is_cash = true
      and is_active = true
  ),
  cash_lines as (
    -- Get all journal lines involving cash accounts
    select
      jl.journal_id,
      jl.account_id,
      jl.debit_cents,
      jl.credit_cents
    from journal_lines jl
    join journals j on j.id = jl.journal_id
    where jl.organization_id = p_organization_id
      and j.status in ('Posted', 'Reversed')
      and j.entry_date between p_start_date and p_end_date
      and (
        jl.account_id in (select id from cash_accounts)
        or jl.journal_id in (
          select journal_id
          from journal_lines
          where account_id in (select id from cash_accounts)
        )
      )
  )
  select
    a.id as counter_account_id,
    a.code as counter_account_code,
    a.name as counter_account_name,
    a.type as counter_account_type,
    sum(
      case
        -- When counter-account is debited, cash was credited (outflow)
        when cl.account_id not in (select id from cash_accounts) and cl.debit_cents > 0
          then -cl.debit_cents
        -- When counter-account is credited, cash was debited (inflow)
        when cl.account_id not in (select id from cash_accounts) and cl.credit_cents > 0
          then cl.credit_cents
        else 0
      end
    ) as net_change_cents
  from cash_lines cl
  join accounts a on a.id = cl.account_id
  where cl.account_id not in (select id from cash_accounts)
  group by a.id, a.code, a.name, a.type
  having sum(
    case
      when cl.account_id not in (select id from cash_accounts) and cl.debit_cents > 0
        then -cl.debit_cents
      when cl.account_id not in (select id from cash_accounts) and cl.credit_cents > 0
        then cl.credit_cents
      else 0
    end
  ) != 0
  order by a.code;
end;
$$;

comment on function get_cash_movement is 'Cash movement by counter-account for a period';

-- ============================================================================
-- AP AGING
-- ============================================================================

create or replace function get_ap_aging(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  bill_id uuid,
  bill_number text,
  vendor_id uuid,
  vendor_name text,
  bill_date date,
  due_date date,
  total_cents bigint,
  paid_cents bigint,
  balance_cents bigint,
  days_outstanding int,
  aging_bucket text
)
language plpgsql
stable
as $$
begin
  return query
  select
    b.id as bill_id,
    b.number as bill_number,
    c.id as vendor_id,
    c.name as vendor_name,
    b.bill_date,
    b.due_date,
    b.total_cents,
    b.paid_cents,
    (b.total_cents - b.paid_cents) as balance_cents,
    (p_as_of_date - b.due_date)::int as days_outstanding,
    case
      when p_as_of_date - b.due_date < 0 then 'Not Due'
      when p_as_of_date - b.due_date <= 30 then '0-30 days'
      when p_as_of_date - b.due_date <= 60 then '31-60 days'
      when p_as_of_date - b.due_date <= 90 then '61-90 days'
      else '90+ days'
    end as aging_bucket
  from bills b
  join contacts c on c.id = b.vendor_id
  where b.organization_id = p_organization_id
    and b.status = 'Open'
    and b.total_cents > b.paid_cents
  order by b.due_date;
end;
$$;

comment on function get_ap_aging is 'Unpaid bills by age (aging buckets)';

-- ============================================================================
-- ACCOUNT LEDGER
-- ============================================================================

create or replace function get_account_ledger(
  p_organization_id uuid,
  p_account_id uuid,
  p_start_date date default null,
  p_end_date date default null
)
returns table (
  journal_id uuid,
  journal_number text,
  entry_date date,
  journal_description text,
  line_memo text,
  status journal_status,
  debit_cents bigint,
  credit_cents bigint,
  running_balance_cents bigint
)
language sql
stable
as $$
  select
    j.id as journal_id,
    j.number as journal_number,
    j.entry_date,
    j.description as journal_description,
    jl.memo as line_memo,
    j.status,
    jl.debit_cents,
    jl.credit_cents,
    sum(jl.debit_cents - jl.credit_cents) over (
      order by j.entry_date, j.created_at, jl.id
      rows between unbounded preceding and current row
    ) as running_balance_cents
  from journal_lines jl
  join journals j on j.id = jl.journal_id
  where jl.account_id = p_account_id
    and jl.organization_id = p_organization_id
    and j.status in ('Posted', 'Reversed')
    and (p_start_date is null or j.entry_date >= p_start_date)
    and (p_end_date is null or j.entry_date <= p_end_date)
  order by j.entry_date, j.created_at, jl.id;
$$;

comment on function get_account_ledger is 'Every posted line in one account (chronological) with running balance';
