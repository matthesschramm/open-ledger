-- Multi-company switcher support
-- Add user_settings table to track active company per user
-- Update current_org_id() to use active_company_id from user_settings

-- ============================================================================
-- USER SETTINGS TABLE
-- ============================================================================

create table user_settings (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null unique,
  active_company_id uuid references organizations(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index user_settings_user_id_idx on user_settings(user_id);
create index user_settings_active_company_id_idx on user_settings(active_company_id);

comment on table user_settings is 'Per-user settings including active company selection for multi-company support';
comment on column user_settings.active_company_id is 'Currently active company for this user; must be a company they have membership in';

-- Enable RLS
alter table user_settings enable row level security;

-- Users can view and update their own settings
create policy "Users can view own settings"
  on user_settings for select
  using (user_id = auth.uid());

create policy "Users can update own settings"
  on user_settings for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- System can insert settings (via trigger on signup or membership creation)
create policy "Users can insert own settings"
  on user_settings for insert
  with check (user_id = auth.uid());

-- Trigger to update updated_at
create trigger update_user_settings_updated_at before update on user_settings
  for each row execute function update_updated_at_column();

-- ============================================================================
-- UPDATE CURRENT_ORG_ID FUNCTION
-- ============================================================================

-- Replace current_org_id() to use active_company_id from user_settings
-- Falls back to first membership if no active company is set
create or replace function current_org_id()
returns uuid
language sql
stable
security definer
as $$
  select coalesce(
    (select active_company_id from user_settings where user_id = auth.uid()),
    (select organization_id from memberships where user_id = auth.uid() limit 1)
  );
$$;

comment on function current_org_id is 'Returns the active company for the current user from user_settings, or first membership if not set';

-- ============================================================================
-- HELPER FUNCTION: GET USER COMPANIES
-- ============================================================================

-- Get all companies the current user has access to
create or replace function get_user_companies()
returns table (
  organization_id uuid,
  organization_name text,
  role membership_role,
  is_active boolean
)
language sql
stable
security definer
as $$
  select 
    m.organization_id,
    o.name as organization_name,
    m.role,
    (m.organization_id = current_org_id()) as is_active
  from memberships m
  join organizations o on o.id = m.organization_id
  where m.user_id = auth.uid()
  order by o.name;
$$;

comment on function get_user_companies is 'Returns all companies the current user can access, with active flag';

-- ============================================================================
-- HELPER FUNCTION: SWITCH COMPANY
-- ============================================================================

-- Switch active company for current user
create or replace function switch_company(p_company_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_has_membership boolean;
begin
  -- Verify user has membership in target company
  select exists(
    select 1 from memberships 
    where user_id = auth.uid() and organization_id = p_company_id
  ) into v_has_membership;
  
  if not v_has_membership then
    return jsonb_build_object(
      'success', false, 
      'error', 'You do not have access to this company'
    );
  end if;
  
  -- Insert or update user_settings
  insert into user_settings (user_id, active_company_id)
  values (auth.uid(), p_company_id)
  on conflict (user_id) 
  do update set 
    active_company_id = p_company_id,
    updated_at = now();
  
  return jsonb_build_object('success', true);
end;
$$;

comment on function switch_company is 'Switch the active company for the current user';

-- ============================================================================
-- HELPER FUNCTION: CREATE COMPANY
-- ============================================================================

-- Create new company with owner membership and seed empty books
create or replace function create_company(p_company_name text)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_org_id uuid;
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  
  if v_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;
  
  if p_company_name is null or trim(p_company_name) = '' then
    return jsonb_build_object(
      'success', false,
      'error', 'Company name is required'
    );
  end if;
  
  -- Create organization
  insert into organizations (name, currency_code, timezone, fiscal_year_end_month, fiscal_year_end_day)
  values (trim(p_company_name), 'USD', 'America/New_York', 12, 31)
  returning id into v_org_id;
  
  -- Create owner membership
  insert into memberships (organization_id, user_id, role)
  values (v_org_id, v_user_id, 'owner');
  
  -- Seed basic chart of accounts (same as signup)
  -- System accounts
  insert into accounts (organization_id, code, name, type, category, is_system) values
    (v_org_id, '2000', 'Accounts payable', 'Liability', 'AP', true),
    (v_org_id, '3000', 'Common stock', 'Equity', 'Equity', true),
    (v_org_id, '3100', 'APIC', 'Equity', 'Equity', true),
    (v_org_id, '3200', 'Retained earnings', 'Equity', 'Equity', true);
  
  -- Standard accounts
  insert into accounts (organization_id, code, name, type, category, is_cash) values
    (v_org_id, '1010', 'Operating cash', 'Asset', 'Cash', true);
  
  insert into accounts (organization_id, code, name, type, category) values
    (v_org_id, '1100', 'Accounts receivable', 'Asset', 'AR'),
    (v_org_id, '5010', 'Contractors and professional', 'Expense', 'Expense'),
    (v_org_id, '5110', 'Bad debt expense', 'Expense', 'Expense');
  
  -- Switch to new company
  insert into user_settings (user_id, active_company_id)
  values (v_user_id, v_org_id)
  on conflict (user_id)
  do update set 
    active_company_id = v_org_id,
    updated_at = now();
  
  return jsonb_build_object(
    'success', true,
    'company_id', v_org_id
  );
end;
$$;

comment on function create_company is 'Create a new company with the current user as owner and seed with basic accounts';
