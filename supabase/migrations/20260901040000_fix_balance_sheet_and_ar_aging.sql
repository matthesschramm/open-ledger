-- Fix balance sheet UNION ORDER BY (wrap union in a subquery).
-- Recreate get_ar_aging with a return type that matches the select list.

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
  perform assert_caller_org(p_organization_id);

  return query
  select
    bs.section,
    bs.account_id,
    bs.account_code,
    bs.account_name,
    bs.account_type,
    bs.balance_cents
  from (
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
      and ab.signed_balance != 0

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
  ) bs
  order by
    case bs.section
      when 'Assets' then 1
      when 'Liabilities' then 2
      when 'Equity' then 3
    end,
    bs.account_code;
end;
$$;

comment on function get_balance_sheet(uuid, date) is
  'Balance Sheet: Assets = Liabilities + Equity (including net income). UNION wrapped so ORDER BY is valid.';

drop function if exists get_ar_aging(uuid, date);

create function get_ar_aging(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  invoice_id uuid,
  invoice_number text,
  customer_name text,
  invoice_date date,
  due_date date,
  amount_due_cents bigint,
  days_overdue int
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  perform assert_caller_org(p_organization_id);

  return query
  with invoice_receipts_as_of as (
    select
      ir.invoice_id,
      coalesce(sum(ir.amount_cents), 0) as received_as_of_cents
    from invoice_receipts ir
    where ir.organization_id = p_organization_id
      and ir.receipt_date <= p_as_of_date
    group by ir.invoice_id
  )
  select
    i.id::uuid,
    i.number::text,
    c.name::text,
    i.invoice_date::date,
    i.due_date::date,
    (i.total_cents - coalesce(ira.received_as_of_cents, 0))::bigint,
    case
      when i.due_date < p_as_of_date then (p_as_of_date - i.due_date)::int
      else 0
    end
  from invoices i
  join contacts c on c.id = i.customer_id
  left join invoice_receipts_as_of ira on ira.invoice_id = i.id
  where i.organization_id = p_organization_id
    and i.status in ('Posted', 'Paid')
    and i.invoice_date <= p_as_of_date
    and (i.total_cents - coalesce(ira.received_as_of_cents, 0)) > 0
  order by i.due_date nulls last, i.invoice_date;
end;
$$;

grant execute on function get_ar_aging(uuid, date) to authenticated, service_role;

comment on function get_ar_aging(uuid, date) is
  'AR aging as of a date. Remaining = invoice total minus receipts/credits/write-offs dated on or before the as-of date.';
