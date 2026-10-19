-- Delete Draft Journal RPC
-- Allows deletion of draft journals only (not Posted or Reversed)
-- Logs audit event with human-readable sentence

create or replace function delete_journal(
  p_journal_id uuid,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_journal journals;
  v_current_user_id uuid;
  v_user_role membership_role;
begin
  -- Support API-key authentication via assume_request_user
  perform assume_request_user(p_user_id);

  -- Get current user
  v_current_user_id := auth.uid();
  
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

  -- Check user's role in the journal's organization (must be owner/admin/bookkeeper)
  select role into v_user_role
  from memberships
  where user_id = v_current_user_id
    and organization_id = v_journal.organization_id;

  if v_user_role is null or v_user_role not in ('owner', 'admin', 'bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Insufficient permissions'
    );
  end if;

  -- Can only delete draft journals
  if v_journal.status != 'Draft' then
    return jsonb_build_object(
      'success', false,
      'error', 'Only drafts can be deleted'
    );
  end if;

  -- Delete journal lines first (CASCADE should handle this, but be explicit)
  delete from journal_lines
  where journal_id = p_journal_id;

  -- Delete the journal
  delete from journals
  where id = p_journal_id;

  -- Log audit event
  perform log_audit_event(
    'journal',
    p_journal_id,
    'journal_deleted',
    jsonb_build_object(
      'journal_number', v_journal.number,
      'entry_date', v_journal.entry_date,
      'description', v_journal.description
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_number', v_journal.number
  );
end;
$$;

grant execute on function delete_journal(uuid, uuid) to authenticated, service_role;

comment on function delete_journal is 'Deletes a draft journal entry and its lines. Only draft journals can be deleted (not Posted or Reversed). Supports both browser (JWT) and API-key (service_role + p_user_id) authentication. Logs audit event.';
