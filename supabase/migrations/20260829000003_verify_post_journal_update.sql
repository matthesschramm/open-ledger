-- Verify post_journal UPDATE actually modifies the journal
-- Consistency fix: add same verification as reverse_journal

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
  v_current_user_id text;
  v_rows_updated integer;
begin
  -- Get current user
  v_current_user_id := auth.uid()::text;
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

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

  v_organization_id := v_journal.organization_id;

  -- Check membership and role (must be bookkeeper+)
  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
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
  v_period_locked := is_period_locked(v_organization_id, v_journal.entry_date);

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
    posted_by = v_current_user_id::uuid
  where id = p_journal_id;

  -- Verify the update actually modified the row
  get diagnostics v_rows_updated = row_count;

  if v_rows_updated = 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Failed to update journal to Posted status - possibly blocked by RLS or concurrent modification'
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'journal_id', p_journal_id
  );
end;
$$;

comment on function post_journal is 'Posts a journal entry after validating balance, lines, header accounts, and period lock. Verifies the journal was successfully marked as Posted.';
