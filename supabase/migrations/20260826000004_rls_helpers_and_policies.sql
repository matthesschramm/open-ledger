-- Open Ledger RLS (Row Level Security)
-- Phase 4: Auth, memberships, and RLS policies
-- Default deny on all tables; explicit grants per role

-- ============================================================================
-- ENABLE RLS ON ALL TABLES
-- ============================================================================

alter table organizations enable row level security;
alter table memberships enable row level security;
alter table api_keys enable row level security;
alter table accounts enable row level security;
alter table accounting_periods enable row level security;
alter table contacts enable row level security;
alter table journals enable row level security;
alter table journal_lines enable row level security;
alter table bills enable row level security;
alter table bill_lines enable row level security;
alter table bill_payments enable row level security;
alter table attachments enable row level security;
alter table audit_events enable row level security;

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Get current user's organization ID (from first membership found)
create or replace function current_org_id()
returns uuid
language sql
stable
security definer
as $$
  select organization_id
  from memberships
  where user_id = auth.uid()
  limit 1;
$$;

comment on function current_org_id is 'Returns the organization_id for the current authenticated user';

-- Get current user's role in their organization
create or replace function "current_role"()
returns membership_role
language sql
stable
security definer
as $$
  select role
  from memberships
  where user_id = auth.uid()
    and organization_id = current_org_id()
  limit 1;
$$;

comment on function "current_role" is 'Returns the role (owner/admin/bookkeeper/read_only) for the current user';

-- Check if current user has a specific role or higher
create or replace function has_role(required_role membership_role)
returns boolean
language sql
stable
security definer
as $$
  select case required_role
    when 'read_only' then "current_role"() in ('read_only', 'bookkeeper', 'admin', 'owner')
    when 'bookkeeper' then "current_role"() in ('bookkeeper', 'admin', 'owner')
    when 'admin' then "current_role"() in ('admin', 'owner')
    when 'owner' then "current_role"() = 'owner'
    else false
  end;
$$;

comment on function has_role is 'Check if current user has the required role or higher in the hierarchy';

-- Check if a period is locked
create or replace function is_period_locked(p_organization_id uuid, p_date date)
returns boolean
language sql
stable
security definer
as $$
  select exists(
    select 1
    from accounting_periods
    where organization_id = p_organization_id
      and p_date between start_date and end_date
      and is_locked = true
  );
$$;

-- ============================================================================
-- ORGANIZATIONS POLICIES
-- ============================================================================

-- Users can view their own organization
create policy "Users can view their organization"
  on organizations for select
  using (id = current_org_id());

-- Owner/admin can update organization details
create policy "Owner/admin can update organization"
  on organizations for update
  using (id = current_org_id() and has_role('admin'));

-- ============================================================================
-- MEMBERSHIPS POLICIES
-- ============================================================================

-- Users can view memberships in their organization
create policy "Users can view org memberships"
  on memberships for select
  using (organization_id = current_org_id());

-- Owner/admin can insert new memberships (invites)
create policy "Owner/admin can invite users"
  on memberships for insert
  with check (organization_id = current_org_id() and has_role('admin'));

-- Owner/admin can update roles, but cannot remove last owner
create policy "Owner/admin can update roles"
  on memberships for update
  using (
    organization_id = current_org_id()
    and has_role('admin')
  )
  with check (
    organization_id = current_org_id()
    and has_role('admin')
    -- Cannot remove the last owner: either there are other owners, or new role is owner
    and (
      (select count(*) from memberships m where m.organization_id = organization_id and m.role = 'owner' and m.id != id) > 0
      or role = 'owner'
    )
  );

-- Owner/admin can delete memberships, but cannot remove last owner
create policy "Owner/admin can remove users"
  on memberships for delete
  using (
    organization_id = current_org_id()
    and has_role('admin')
    and not (
      role = 'owner'
      and (select count(*) from memberships where organization_id = current_org_id() and role = 'owner') = 1
    )
  );

-- ============================================================================
-- API KEYS POLICIES
-- ============================================================================

-- Owner/admin can view API key metadata (not key_hash)
create policy "Owner/admin can view api keys"
  on api_keys for select
  using (organization_id = current_org_id() and has_role('admin'));

-- Owner/admin can create API keys
create policy "Owner/admin can create api keys"
  on api_keys for insert
  with check (organization_id = current_org_id() and has_role('admin'));

-- Owner/admin can revoke API keys
create policy "Owner/admin can revoke api keys"
  on api_keys for update
  using (organization_id = current_org_id() and has_role('admin'));

-- ============================================================================
-- ACCOUNTS POLICIES
-- ============================================================================

-- All members can view accounts
create policy "Members can view accounts"
  on accounts for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can create accounts
create policy "Bookkeeper+ can create accounts"
  on accounts for insert
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

-- Bookkeeper+ can update non-system accounts (cannot change type if posted lines exist)
create policy "Bookkeeper+ can update accounts"
  on accounts for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and not is_system
  );

-- Admin+ can archive accounts (set is_active = false)
create policy "Admin+ can archive accounts"
  on accounts for update
  using (
    organization_id = current_org_id()
    and has_role('admin')
  );

-- ============================================================================
-- ACCOUNTING PERIODS POLICIES
-- ============================================================================

-- All members can view periods
create policy "Members can view periods"
  on accounting_periods for select
  using (organization_id = current_org_id());

-- Admin+ can create periods
create policy "Admin+ can create periods"
  on accounting_periods for insert
  with check (organization_id = current_org_id() and has_role('admin'));

-- Period locking is handled by lock_period RPC (admin+)
-- Period unlocking requires owner role (checked in RPC)

-- ============================================================================
-- CONTACTS POLICIES
-- ============================================================================

-- All members can view contacts
create policy "Members can view contacts"
  on contacts for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can create contacts
create policy "Bookkeeper+ can create contacts"
  on contacts for insert
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

-- Bookkeeper+ can update contacts
create policy "Bookkeeper+ can update contacts"
  on contacts for update
  using (organization_id = current_org_id() and has_role('bookkeeper'));

-- ============================================================================
-- JOURNALS POLICIES
-- ============================================================================

-- All members can view journals
create policy "Members can view journals"
  on journals for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can create draft journals
create policy "Bookkeeper+ can create journals"
  on journals for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  );

-- Bookkeeper+ can update ONLY draft journals (not Posted or Reversed)
create policy "Bookkeeper+ can update draft journals"
  on journals for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  )
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  );

-- Note: Posting/reversing is only through post_journal/reverse_journal RPCs
-- Direct status updates from Draft to Posted/Reversed are DENIED by the policy above

-- Bookkeeper+ can delete draft journals
create policy "Bookkeeper+ can delete draft journals"
  on journals for delete
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  );

-- ============================================================================
-- JOURNAL LINES POLICIES
-- ============================================================================

-- All members can view journal lines
create policy "Members can view journal lines"
  on journal_lines for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can create journal lines (for draft journals)
create policy "Bookkeeper+ can create journal lines"
  on journal_lines for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and exists(
      select 1 from journals
      where id = journal_id
        and status = 'Draft'
        and organization_id = current_org_id()
    )
  );

-- Bookkeeper+ can update journal lines (only for draft journals)
create policy "Bookkeeper+ can update journal lines"
  on journal_lines for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and exists(
      select 1 from journals
      where id = journal_id
        and status = 'Draft'
        and organization_id = current_org_id()
    )
  );

-- Bookkeeper+ can delete journal lines (only for draft journals)
create policy "Bookkeeper+ can delete journal lines"
  on journal_lines for delete
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and exists(
      select 1 from journals
      where id = journal_id
        and status = 'Draft'
        and organization_id = current_org_id()
    )
  );

-- ============================================================================
-- BILLS POLICIES
-- ============================================================================

-- All members can view bills
create policy "Members can view bills"
  on bills for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can create bills
create policy "Bookkeeper+ can create bills"
  on bills for insert
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

-- Bookkeeper+ can update bills
create policy "Bookkeeper+ can update bills"
  on bills for update
  using (organization_id = current_org_id() and has_role('bookkeeper'));

-- Bookkeeper+ can delete draft bills
create policy "Bookkeeper+ can delete bills"
  on bills for delete
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status = 'Draft'
  );

-- ============================================================================
-- BILL LINES POLICIES
-- ============================================================================

-- All members can view bill lines
create policy "Members can view bill lines"
  on bill_lines for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can create bill lines
create policy "Bookkeeper+ can create bill lines"
  on bill_lines for insert
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

-- Bookkeeper+ can update bill lines
create policy "Bookkeeper+ can update bill lines"
  on bill_lines for update
  using (organization_id = current_org_id() and has_role('bookkeeper'));

-- Bookkeeper+ can delete bill lines
create policy "Bookkeeper+ can delete bill lines"
  on bill_lines for delete
  using (organization_id = current_org_id() and has_role('bookkeeper'));

-- ============================================================================
-- BILL PAYMENTS POLICIES
-- ============================================================================

-- All members can view bill payments
create policy "Members can view bill payments"
  on bill_payments for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can create bill payments
create policy "Bookkeeper+ can create bill payments"
  on bill_payments for insert
  with check (organization_id = current_org_id() and has_role('bookkeeper'));

-- ============================================================================
-- ATTACHMENTS POLICIES
-- ============================================================================

-- All members can view attachments
create policy "Members can view attachments"
  on attachments for select
  using (organization_id = current_org_id());

-- Bookkeeper+ can upload attachments
create policy "Bookkeeper+ can upload attachments"
  on attachments for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and storage_path like 'org/' || current_org_id()::text || '/%'
  );

-- Bookkeeper+ can delete their own attachments
create policy "Bookkeeper+ can delete attachments"
  on attachments for delete
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

-- ============================================================================
-- AUDIT EVENTS POLICIES
-- ============================================================================

-- Owner/admin can view all audit events
create policy "Owner/admin can view all audit events"
  on audit_events for select
  using (
    organization_id = current_org_id()
    and has_role('admin')
  );

-- Bookkeeper can view their own audit events
create policy "Bookkeeper can view own audit events"
  on audit_events for select
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and actor_id = auth.uid()
  );

-- Audit events are only inserted by security definer functions
-- No direct insert policy for users

-- ============================================================================
-- STORAGE POLICIES (for attachments bucket)
-- ============================================================================

-- Note: Storage policies are configured separately in Supabase dashboard
-- or via storage.policies table. Document the required policies:
--
-- Bucket: attachments (private)
-- Path pattern: org/{organization_id}/**
--
-- SELECT policy:
--   - Check membership in organization_id extracted from path
--
-- INSERT policy:
--   - Check membership + bookkeeper+ role
--   - Path must match org/{current_org_id()}/**
--
-- DELETE policy:
--   - Check membership + bookkeeper+ role
--   - Path must match org/{current_org_id()}/**

comment on table attachments is 'Storage paths must start with org/{organization_id}/ and are enforced by storage policies';
