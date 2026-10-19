-- Fix Account Ledger: Use plpgsql accumulator instead of SQL-language window
-- SQL-language window functions have scoping issues with ORDER BY columns
-- Use plpgsql loop to accumulate running balance procedurally

create or replace function public.get_account_ledger(
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
language plpgsql
stable
as $$
declare
  v_run bigint;
  r record;
begin
  v_run := coalesce((
    select sum(jl0.debit_cents - jl0.credit_cents)
    from journal_lines jl0
    join journals j0 on j0.id = jl0.journal_id
    where jl0.account_id = p_account_id
      and jl0.organization_id = p_organization_id
      and j0.status in ('Posted', 'Reversed')
      and p_start_date is not null
      and j0.entry_date < p_start_date
  ), 0);

  for r in
    select
      j.id as jid,
      j.number as jnum,
      j.entry_date as edate,
      j.description as jdesc,
      jl.memo as lmemo,
      j.status as jstatus,
      jl.debit_cents as d_cents,
      jl.credit_cents as c_cents
    from journal_lines jl
    join journals j on j.id = jl.journal_id
    where jl.account_id = p_account_id
      and jl.organization_id = p_organization_id
      and j.status in ('Posted', 'Reversed')
      and (p_start_date is null or j.entry_date >= p_start_date)
      and (p_end_date is null or j.entry_date <= p_end_date)
    order by
      j.entry_date,
      j.created_at,
      case when j.number like 'REV-%' then 1 else 0 end,
      jl.id
  loop
    v_run := v_run + r.d_cents - r.c_cents;
    journal_id := r.jid;
    journal_number := r.jnum;
    entry_date := r.edate;
    journal_description := r.jdesc;
    line_memo := r.lmemo;
    status := r.jstatus;
    debit_cents := r.d_cents;
    credit_cents := r.c_cents;
    running_balance_cents := v_run;
    return next;
  end loop;
end;
$$;

comment on function public.get_account_ledger is 'Every posted line in one account with plpgsql accumulator for reliable running balance (originals before reversals)';
