-- Fix signed balances to use normal balance conventions
-- BUG-01: Centralize signed balances by normal balance
-- 
-- Normal balance conventions:
-- - Assets & Expenses: Debit-normal (positive = debit - credit)
-- - Liabilities, Equity, Revenue: Credit-normal (positive = credit - debit)

-- ============================================================================
-- HELPER: Apply normal balance sign
-- ============================================================================

create or replace function apply_normal_balance_sign(
  p_account_type account_type,
  p_raw_balance bigint
)
returns bigint
language sql
immutable
as $$
  select case
    -- Debit-normal accounts: Assets and Expenses
    -- Positive balance = debit - credit (increases with debits)
    when p_account_type in ('Asset', 'Expense') then p_raw_balance
    
    -- Credit-normal accounts: Liabilities, Equity, Revenue
    -- Positive balance = credit - debit (increases with credits)
    when p_account_type in ('Liability', 'Equity', 'Revenue') then -p_raw_balance
    
    else p_raw_balance
  end;
$$;

comment on function apply_normal_balance_sign is 'Applies normal balance sign convention: debit-normal (Asset, Expense) positive = debit-credit; credit-normal (Liability, Equity, Revenue) positive = credit-debit';

-- ============================================================================
-- UPDATE: calculate_account_balance to return signed balance
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
  v_raw_balance bigint;
begin
  -- Get account type
  select * into v_account
  from accounts
  where id = p_account_id;

  if not found then
    return 0;
  end if;

  -- Calculate totals from journal lines (Posted and Reversed journals)
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

  -- Calculate raw balance (debit-positive)
  v_raw_balance := v_total_debit - v_total_credit;

  -- Apply normal balance sign convention
  return apply_normal_balance_sign(v_account.type, v_raw_balance);
end;
$$;

comment on function calculate_account_balance is 'Returns signed balance with normal balance conventions: positive for increases, negative for decreases';

-- ============================================================================
-- UPDATE: get_balance_sheet to use signed balances
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
      coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0) as raw_balance
    from accounts a
    left join journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      and a.is_header = false
      and (j.id is null or (j.status in ('Posted', 'Reversed') and j.entry_date <= p_as_of_date))
    group by a.id, a.code, a.name, a.type, a.is_header
  ),
  account_signed_balances as (
    select
      account_id,
      account_code,
      account_name,
      account_type,
      apply_normal_balance_sign(account_type, raw_balance) as signed_balance
    from account_balances
  ),
  revenue_expense_total as (
    -- Calculate net income from revenue and expense accounts
    -- After applying normal balance sign: positive revenue and positive expenses
    -- Net Income = revenue - expenses (both positive after sign correction)
    select
      coalesce(sum(case when account_type = 'Revenue' then signed_balance else 0 end), 0) -
      coalesce(sum(case when account_type = 'Expense' then signed_balance else 0 end), 0) as net_income
    from account_signed_balances
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
    ab.signed_balance as balance_cents
  from account_signed_balances ab
  where ab.account_type in ('Asset', 'Liability', 'Equity')
    and ab.signed_balance != 0
  
  union all
  
  -- Add net income as a computed equity line
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

comment on function get_balance_sheet is 'Balance Sheet with normal balance signs: Assets = Liabilities + Equity (including net income)';

-- ============================================================================
-- UPDATE: get_profit_and_loss to use signed balances
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
      coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0) as raw_amount
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
    apply_normal_balance_sign(aa.account_type, aa.raw_amount) as amount_cents
  from account_activity aa
  where aa.raw_amount != 0
  order by
    case section
      when 'Revenue' then 1
      when 'Expenses' then 2
    end,
    account_code;
end;
$$;

comment on function get_profit_and_loss is 'Profit & Loss with normal balance signs: Revenue and Expenses shown as positive when earned/incurred';

-- ============================================================================
-- UPDATE: get_cash_movement to use signed balances
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
  ),
  counter_account_movements as (
    -- For each counter-account (non-cash), calculate the cash movement
    -- When cash is debited (inflow), counter-account is credited
    -- When cash is credited (outflow), counter-account is debited
    select
      a.id as counter_account_id,
      a.code as counter_account_code,
      a.name as counter_account_name,
      a.type as counter_account_type,
      -- Net movement from cash's perspective (signed with cash normal balance)
      -- Cash is an Asset (debit-normal), so debit = increase, credit = decrease
      sum(
        case
          -- Counter-account debited means cash credited (cash decrease/outflow)
          when cl.account_id not in (select id from cash_accounts) and cl.debit_cents > 0
            then -cl.debit_cents
          -- Counter-account credited means cash debited (cash increase/inflow)
          when cl.account_id not in (select id from cash_accounts) and cl.credit_cents > 0
            then cl.credit_cents
          else 0
        end
      ) as raw_net_change
    from cash_lines cl
    join accounts a on a.id = cl.account_id
    where cl.account_id not in (select id from cash_accounts)
    group by a.id, a.code, a.name, a.type
  )
  select
    cam.counter_account_id,
    cam.counter_account_code,
    cam.counter_account_name,
    cam.counter_account_type,
    cam.raw_net_change as net_change_cents
  from counter_account_movements cam
  where cam.raw_net_change != 0
  order by cam.counter_account_code;
end;
$$;

comment on function get_cash_movement is 'Cash movement by counter-account: positive = cash increase (inflow), negative = cash decrease (outflow)';
