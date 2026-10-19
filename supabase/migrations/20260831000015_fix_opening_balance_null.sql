-- Fix Account Ledger: Opening balance returns NULL when p_start_date is null
-- When opening_balance CTE has no rows, (select opening_cents) returns NULL
-- This makes entire running_balance_cents NULL, displayed as 0
-- Wrap opening_cents in COALESCE to handle NULL case

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
  )
  select
    j.id as journal_id,
    j.number as journal_number,
    j.entry_date,
    j.description as journal_description,
    jl.memo as line_memo,
    j.status,
    jl.debit_cents,
    jl.credit_cents,
    -- Add opening balance to the running sum, handle NULL when CTE has no rows
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
  order by 
    j.entry_date,
    (regexp_replace(j.number, '\D', '', 'g'))::bigint,
    case when j.number like 'REV-%' then 1 else 0 end,
    j.created_at,
    jl.id;
$$;

comment on function get_account_ledger is 'Every posted line in one account with numeric sequence ordering (originals before reversals), opening balance, and NULL-safe running total';
