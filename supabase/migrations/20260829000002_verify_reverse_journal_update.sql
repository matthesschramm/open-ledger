-- Verify reverse_journal UPDATE actually modifies the original journal
-- Bug fix: reverse_journal returned success even when RLS blocked the Posted→Reversed UPDATE

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

  -- Check if reversal period is locked
  v_period_locked := is_period_locked(v_organization_id, p_reversal_date);

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
    v_current_user_id::uuid
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

  -- Verify the update actually modified the row
  get diagnostics v_rows_updated = row_count;

  if v_rows_updated = 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Failed to update original journal to Reversed status - possibly blocked by RLS or concurrent modification'
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'original_journal_id', p_journal_id,
    'reversal_journal_id', v_reversal_journal_id
  );
end;
$$;

comment on function reverse_journal is 'Reverses a posted journal by creating a reversing entry with swapped debits/credits. Verifies the original journal was successfully marked as Reversed.';
