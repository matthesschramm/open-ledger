-- Fix Account Ledger: Use subquery to ensure window function has all ordering columns
-- SQL-language functions can have issues when window ORDER BY uses columns not in SELECT
-- Use CTE/subquery with all columns, calculate running balance, then select output columns

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
  with opening_balance as (
    -- Calculate balance from all transactions before start_date
    select coalesce(sum(jl.debit_cents - jl.credit_cents), 0) as opening_cents
    from journal_lines jl
    join journals j on j.id = jl.journal_id
    where jl.account_id = p_account_id
      and jl.organization_id = p_organization_id
      and j.status in ('Posted', 'Reversed')
      and p_start_date is not null
      and j.entry_date < p_start_date
  ),
  ledger_with_running as (
    select
      j.id as journal_id,
      j.number as journal_number,
      j.entry_date,
      j.description as journal_description,
      jl.memo as line_memo,
      j.status,
      jl.debit_cents,
      jl.credit_cents,
      j.created_at,
      jl.id as line_id,
      (regexp_replace(j.number, '\D', '', 'g'))::bigint as journal_seq,
      case when j.number like 'REV-%' then 1 else 0 end as is_reversal,
      -- Calculate running balance with opening
      coalesce((select opening_cents from opening_balance), 0) + 
      sum(jl.debit_cents - jl.credit_cents) over (
        order by 
          j.entry_date,
          (regexp_replace(j.number, '\D', '', 'g'))::bigint,
          case when j.number like 'REV-%' then 1 else 0 end,
          j.created_at,
          jl.id
        rows between unbounded preceding and current row
      ) as running_balance_cents
    from journal_lines jl
    join journals j on j.id = jl.journal_id
    where jl.account_id = p_account_id
      and jl.organization_id = p_organization_id
      and j.status in ('Posted', 'Reversed')
      and (p_start_date is null or j.entry_date >= p_start_date)
      and (p_end_date is null or j.entry_date <= p_end_date)
  )
  select
    journal_id,
    journal_number,
    entry_date,
    journal_description,
    line_memo,
    status,
    debit_cents,
    credit_cents,
    running_balance_cents
  from ledger_with_running
  order by 
    entry_date,
    journal_seq,
    is_reversal,
    created_at,
    line_id;
$$;

comment on function get_account_ledger is 'Every posted line in one account with numeric sequence ordering (originals before reversals), opening balance, using subquery for reliable window calculation';
