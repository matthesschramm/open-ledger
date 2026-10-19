-- Add timezone picker support at signup and in settings
-- Allow users to set their company timezone (IANA format)
-- Default to browser-detected timezone, fallback to America/New_York
--
-- CRITICAL ACCOUNTING RULE:
-- Changing the timezone NEVER rewrites journal entry_date values.
-- Journals stay in their original periods regardless of timezone changes.
-- Timezone only affects:
--   1. Display of posted_at timestamps (shown with zone abbreviation)
--   2. What counts as "today" for new entries (companyToday() uses org timezone)
-- Period lock continues to check the journal's own entry_date field (unchanged).

-- ============================================================================
-- UPDATE HANDLE_NEW_USER TO USE BROWSER TIMEZONE FROM METADATA
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
  if exists(select 1 from public.memberships where user_id = new.id) then
    return new;
  end if;

  if apply_invitation_for_user(new.id, new.email) is not null then
    return new;
  end if;

  v_org_name := coalesce(
    new.raw_user_meta_data->>'company_name',
    split_part(new.email, '@', 1) || '''s Organization'
  );

  insert into public.organizations (name, currency_code, timezone)
  values (v_org_name, 'USD', coalesce((select name from pg_timezone_names where name = new.raw_user_meta_data->>'timezone'), 'America/New_York'))
  returning id into v_org_id;

  insert into public.memberships (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  insert into public.accounts (organization_id, code, name, type, category, is_header, is_cash, is_system, is_active) values
  (v_org_id, '1000', 'Cash', 'Asset', 'Cash', true, false, false, true),
  (v_org_id, '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1020', 'Savings / reserves', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1100', 'Accounts receivable', 'Asset', 'AR', false, false, true, true),
  (v_org_id, '1200', 'Prepaid expenses', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '1400', 'Due from parent', 'Asset', 'AR', false, false, false, true),
  (v_org_id, '1500', 'Computer and equipment', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '2000', 'Accounts payable', 'Liability', 'AP', false, false, true, true),
  (v_org_id, '2100', 'Accrued expenses', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '2200', 'Due to parent', 'Liability', 'AP', false, false, false, true),
  (v_org_id, '2300', 'Credit cards', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '3000', 'Common stock', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3100', 'Additional paid-in capital', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3200', 'Retained earnings', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3900', 'Opening balance equity', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '4000', 'Revenue', 'Revenue', 'Revenue', true, false, false, true),
  (v_org_id, '4010', 'Product / service revenue', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '4100', 'Other income', 'Revenue', 'Revenue', false, false, false, true),
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
  (v_org_id, '5110', 'Bad debt', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '6000', 'Other expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '6100', 'FX and rounding', 'Expense', 'Expense', false, false, false, true);

  perform ensure_ppe_accounts(v_org_id);

  return new;
end;
$$;

comment on function handle_new_user is
  'Joins a pending invitation when present; otherwise creates an org with browser-detected timezone, owner membership, US CoA, and PPE accounts';
