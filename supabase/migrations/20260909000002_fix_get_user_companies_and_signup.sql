-- Fix get_user_companies() to return role as TEXT (not enum) and set search_path
-- Add trigger to seed user_settings from membership inserts
-- Fix handle_new_user() to create user_settings with active_company_id
-- Align with live READY DB changes made by Engineering

-- ============================================================================
-- FIX GET_USER_COMPANIES RPC - RETURN ROLE AS TEXT
-- ============================================================================

-- Drop existing function first to change return type
drop function if exists get_user_companies();

create or replace function get_user_companies()
returns table (
  organization_id uuid,
  organization_name text,
  role text,
  is_active boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select 
    m.organization_id,
    o.name as organization_name,
    m.role::text,
    (m.organization_id = current_org_id()) as is_active
  from memberships m
  join organizations o on o.id = m.organization_id
  where m.user_id = auth.uid()
  order by o.name;
$$;

comment on function get_user_companies is 'Returns all companies the current user can access, with active flag. Role returned as text for PostgREST compatibility. Security definer with explicit search_path.';

-- ============================================================================
-- ADD TRIGGER TO SEED USER_SETTINGS FROM MEMBERSHIP INSERTS
-- ============================================================================

create or replace function seed_user_settings_from_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Seed user_settings when a new membership is created
  -- ON CONFLICT DO NOTHING ensures we don't overwrite existing active_company_id
  insert into user_settings (user_id, active_company_id)
  values (new.user_id, new.organization_id)
  on conflict (user_id) do nothing;
  
  return new;
end;
$$;

comment on function seed_user_settings_from_membership is 'Trigger function to seed user_settings.active_company_id from new memberships';

-- Create trigger on memberships table
drop trigger if exists seed_user_settings_on_membership_insert on memberships;

create trigger seed_user_settings_on_membership_insert
  after insert on memberships
  for each row
  execute function seed_user_settings_from_membership();

comment on trigger seed_user_settings_on_membership_insert on memberships is 'Seeds user_settings with active_company_id from new membership inserts';

-- ============================================================================
-- BACKFILL EXISTING USER_SETTINGS FROM MEMBERSHIPS
-- ============================================================================

-- Backfill user_settings for any users who have memberships but no settings
insert into user_settings (user_id, active_company_id)
select distinct on (m.user_id)
  m.user_id,
  m.organization_id
from memberships m
left join user_settings us on us.user_id = m.user_id
where us.user_id is null
order by m.user_id, m.created_at asc
on conflict (user_id) do nothing;

-- ============================================================================
-- FIX HANDLE_NEW_USER TO CREATE USER_SETTINGS
-- ============================================================================

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_org_name text;
begin
  -- Check if user already has a membership
  if exists(select 1 from memberships where user_id = new.id) then
    return new;
  end if;

  -- Extract name from email or metadata
  v_org_name := coalesce(
    new.raw_user_meta_data->>'company_name',
    split_part(new.email, '@', 1) || '''s Organization'
  );

  -- Create organization
  insert into organizations (name, currency_code, timezone)
  values (v_org_name, 'USD', 'America/New_York')
  returning id into v_org_id;

  -- Add user as owner (trigger will seed user_settings automatically)
  insert into memberships (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  -- Create locked US Chart of Accounts (no journals, no opening balances)
  -- Same as public Acme seed chart, system accounts (is_system = true) cannot be archived or have type changed
  insert into accounts (organization_id, code, name, type, category, is_header, is_cash, is_system, is_active) values
  -- 1000 Cash
  (v_org_id, '1000', 'Cash', 'Asset', 'Cash', true, false, false, true),
  (v_org_id, '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1020', 'Savings / reserves', 'Asset', 'Cash', false, true, false, true),
  
  -- 1200-1500 Other Assets
  (v_org_id, '1200', 'Prepaid expenses', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '1400', 'Due from parent', 'Asset', 'AR', false, false, false, true),
  (v_org_id, '1500', 'Computer and equipment', 'Asset', 'Other', false, false, false, true),
  
  -- 2000 Liabilities
  (v_org_id, '2000', 'Accounts payable', 'Liability', 'AP', false, false, true, true),
  (v_org_id, '2100', 'Accrued expenses', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '2200', 'Due to parent', 'Liability', 'AP', false, false, false, true),
  (v_org_id, '2300', 'Credit cards', 'Liability', 'Other', false, false, false, true),
  
  -- 3000 Equity
  (v_org_id, '3000', 'Common stock', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3100', 'Additional paid-in capital', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3200', 'Retained earnings', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3900', 'Opening balance equity', 'Equity', 'Equity', false, false, true, true),
  
  -- 4000 Revenue
  (v_org_id, '4000', 'Revenue', 'Revenue', 'Revenue', true, false, false, true),
  (v_org_id, '4010', 'Product / service revenue', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '4100', 'Other income', 'Revenue', 'Revenue', false, false, false, true),
  
  -- 5000 Operating Expenses
  (v_org_id, '5000', 'Operating expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '5010', 'Contractors and professional', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5020', 'Legal and formation', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5030', 'Software and subscriptions', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5040', 'Banking and payments', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5050', 'Travel', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5060', 'Insurance', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5070', 'Payroll and benefits', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5080', 'Office and admin', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5090', 'Tax expense', 'Expense', 'Expense', false, false, false, true),
  
  -- 6000 Other Expenses
  (v_org_id, '6000', 'Other expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '6100', 'FX and rounding', 'Expense', 'Expense', false, false, false, true);

  return new;
end;
$$;

comment on function handle_new_user is 'Creates an organization, owner membership (which triggers user_settings creation), and locked US Chart of Accounts for new users';

-- ============================================================================
-- FIX SWITCH_COMPANY TO SET SEARCH_PATH
-- ============================================================================

create or replace function switch_company(p_company_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
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

comment on function switch_company is 'Switch the active company for the current user. Security definer with explicit search_path.';

-- ============================================================================
-- FIX CURRENT_ORG_ID TO SET SEARCH_PATH
-- ============================================================================

create or replace function current_org_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select active_company_id from user_settings where user_id = auth.uid()),
    (select organization_id from memberships where user_id = auth.uid() limit 1)
  );
$$;

comment on function current_org_id is 'Returns the active company for the current user from user_settings, or first membership if not set. Security definer with explicit search_path.';
