-- Open Ledger RPC Functions
-- Phase 3: Security definer functions for journal posting, reversals, and period locking

-- ============================================================================
-- POST JOURNAL
-- ============================================================================

create or replace function post_journal(p_journal_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_journal journals;
  v_total_debit_cents bigint;
  v_total_credit_cents bigint;
  v_line_count int;
  v_has_header_accounts boolean;
  v_period_locked boolean;
  v_organization_id uuid;
begin
  -- Get journal with lock
  select * into v_journal
  from journals
  where id = p_journal_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal not found'
    );
  end if;

  -- Check if already posted
  if v_journal.status = 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal already posted'
    );
  end if;

  -- Check if reversed
  if v_journal.status = 'Reversed' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a reversed journal'
    );
  end if;

  v_organization_id := v_journal.organization_id;

  -- Count lines
  select count(*) into v_line_count
  from journal_lines
  where journal_id = p_journal_id;

  if v_line_count < 2 then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal must have at least 2 lines'
    );
  end if;

  -- Calculate totals
  select
    coalesce(sum(debit_cents), 0),
    coalesce(sum(credit_cents), 0)
  into v_total_debit_cents, v_total_credit_cents
  from journal_lines
  where journal_id = p_journal_id;

  -- Check if balanced
  if v_total_debit_cents != v_total_credit_cents then
    return jsonb_build_object(
      'success', false,
      'error', format('Journal not balanced: debit %s != credit %s', v_total_debit_cents, v_total_credit_cents)
    );
  end if;

  -- Check for header accounts
  select exists(
    select 1
    from journal_lines jl
    join accounts a on a.id = jl.account_id
    where jl.journal_id = p_journal_id
      and a.is_header = true
  ) into v_has_header_accounts;

  if v_has_header_accounts then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post to header accounts'
    );
  end if;

  -- Check if period is locked
  select exists(
    select 1
    from accounting_periods
    where organization_id = v_organization_id
      and v_journal.entry_date between start_date and end_date
      and is_locked = true
  ) into v_period_locked;

  if v_period_locked then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post to a locked period'
    );
  end if;

  -- Post the journal
  update journals
  set
    status = 'Posted',
    posted_at = now(),
    posted_by = current_setting('request.jwt.claims', true)::jsonb->>'sub'
  where id = p_journal_id;

  return jsonb_build_object(
    'success', true,
    'journal_id', p_journal_id
  );
end;
$$;

comment on function post_journal is 'Posts a journal entry after validating balance, lines, header accounts, and period lock';

-- ============================================================================
-- REVERSE JOURNAL
-- ============================================================================

create or replace function reverse_journal(
  p_journal_id uuid,
  p_reversal_date date,
  p_reversal_description text default null
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_journal journals;
  v_reversal_journal_id uuid;
  v_reversal_number text;
  v_reversal_description text;
  v_line record;
  v_period_locked boolean;
  v_organization_id uuid;
  v_current_user_id text;
begin
  -- Get current user
  v_current_user_id := current_setting('request.jwt.claims', true)::jsonb->>'sub';

  -- Get journal with lock
  select * into v_journal
  from journals
  where id = p_journal_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal not found'
    );
  end if;

  -- Check if already reversed
  if v_journal.reversed_by_journal_id is not null then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal already reversed'
    );
  end if;

  -- Can only reverse posted journals
  if v_journal.status != 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only reverse posted journals'
    );
  end if;

  v_organization_id := v_journal.organization_id;

  -- Check if reversal period is locked
  select exists(
    select 1
    from accounting_periods
    where organization_id = v_organization_id
      and p_reversal_date between start_date and end_date
      and is_locked = true
  ) into v_period_locked;

  if v_period_locked then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post reversal to a locked period'
    );
  end if;

  -- Generate reversal number and description
  v_reversal_number := 'REV-' || v_journal.number;
  v_reversal_description := coalesce(p_reversal_description, 'REVERSAL: ' || v_journal.description);

  -- Create reversal journal
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    reverses_journal_id,
    created_by
  ) values (
    v_organization_id,
    v_reversal_number,
    p_reversal_date,
    v_reversal_description,
    'Draft',
    'reversal',
    p_journal_id,
    v_current_user_id
  )
  returning id into v_reversal_journal_id;

  -- Copy lines with swapped debits and credits
  for v_line in
    select account_id, debit_cents, credit_cents, memo
    from journal_lines
    where journal_id = p_journal_id
  loop
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_organization_id,
      v_reversal_journal_id,
      v_line.account_id,
      v_line.credit_cents,  -- swap
      v_line.debit_cents,   -- swap
      case
        when v_line.memo is not null then 'Reversing: ' || v_line.memo
        else 'Reversal'
      end
    );
  end loop;

  -- Post the reversal journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_reversal_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      -- Rollback will happen automatically
      return v_post_result;
    end if;
  end;

  -- Update original journal status to Reversed
  update journals
  set
    status = 'Reversed',
    reversed_by_journal_id = v_reversal_journal_id
  where id = p_journal_id;

  return jsonb_build_object(
    'success', true,
    'original_journal_id', p_journal_id,
    'reversal_journal_id', v_reversal_journal_id
  );
end;
$$;

comment on function reverse_journal is 'Reverses a posted journal by creating a reversing entry with swapped debits/credits';

-- ============================================================================
-- LOCK PERIOD
-- ============================================================================

create or replace function lock_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_period accounting_periods;
  v_current_user_id text;
begin
  -- Get current user
  v_current_user_id := current_setting('request.jwt.claims', true)::jsonb->>'sub';

  -- Get period with lock
  select * into v_period
  from accounting_periods
  where id = p_period_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Period not found'
    );
  end if;

  -- Check if already locked
  if v_period.is_locked then
    return jsonb_build_object(
      'success', false,
      'error', 'Period already locked'
    );
  end if;

  -- Lock the period
  update accounting_periods
  set
    is_locked = true,
    locked_at = now(),
    locked_by = v_current_user_id
  where id = p_period_id;

  return jsonb_build_object(
    'success', true,
    'period_id', p_period_id
  );
end;
$$;

comment on function lock_period is 'Locks an accounting period to prevent posting/reversing journals in that period';

-- ============================================================================
-- VOID BILL (through journal reversal)
-- ============================================================================

create or replace function void_bill(p_bill_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_bill bills;
  v_reversal_result jsonb;
begin
  -- Get bill with lock
  select * into v_bill
  from bills
  where id = p_bill_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill not found'
    );
  end if;

  -- Check if already void
  if v_bill.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Bill already void'
    );
  end if;

  -- Check if bill has recognition journal
  if v_bill.recognition_journal_id is null then
    -- Just mark as void if no journal yet
    update bills
    set status = 'Void'
    where id = p_bill_id;

    return jsonb_build_object(
      'success', true,
      'bill_id', p_bill_id
    );
  end if;

  -- Reverse the recognition journal
  v_reversal_result := reverse_journal(
    v_bill.recognition_journal_id,
    current_date,
    'Void bill: ' || v_bill.number
  );

  if not (v_reversal_result->>'success')::boolean then
    return v_reversal_result;
  end if;

  -- Mark bill as void
  update bills
  set status = 'Void'
  where id = p_bill_id;

  return jsonb_build_object(
    'success', true,
    'bill_id', p_bill_id,
    'reversal_result', v_reversal_result
  );
end;
$$;

comment on function void_bill is 'Voids a bill by reversing its recognition journal and marking it void';
