-- Fix Account Ledger: Calculate running balance correctly
-- Previously the function returned 0 for all running_balance_cents values

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
