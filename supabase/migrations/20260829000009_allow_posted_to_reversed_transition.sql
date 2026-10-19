-- Allow post_journal and reverse_journal RPCs to change journal status
-- Bug fix: reverse_journal (and post_journal) were silently failing because RLS blocked status transitions
--
-- The existing "Bookkeeper+ can update draft journals" policy only allows updating Draft journals
-- and requires they stay Draft. This blocks the RPCs from changing status.
--
-- Solution: Add specific policies for the allowed status transitions:
-- 1. Draft → Posted (for post_journal RPC)
-- 2. Posted → Reversed (for reverse_journal RPC)

-- Allow Draft → Posted transition (post_journal RPC)
create policy "Allow Draft to Posted transition for posting"
  on journals for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  )
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Posted'
    and posted_at is not null
    and posted_by is not null
  );

-- Allow Posted → Reversed transition (reverse_journal RPC)
create policy "Allow Posted to Reversed transition for reversal"
  on journals for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Posted'
  )
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Reversed'
    and reversed_by_journal_id is not null
  );

comment on policy "Allow Draft to Posted transition for posting" on journals is 
  'Allows post_journal RPC to update Draft journals to Posted status';

comment on policy "Allow Posted to Reversed transition for reversal" on journals is 
  'Allows reverse_journal RPC to update Posted journals to Reversed status';
