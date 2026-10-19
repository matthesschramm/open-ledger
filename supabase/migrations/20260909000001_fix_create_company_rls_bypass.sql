-- Fix create_company by disabling RLS within the security definer function
-- Root cause: Both memberships and accounts INSERT policies require organization_id = current_org_id(),
-- which fails for new companies because current_org_id() returns the user's OLD active company.
-- Solution: Use SET LOCAL to disable RLS for the transaction scope within security definer function.

-- Drop and recreate with proper RLS bypass
drop function if exists create_company(text);

create or replace function create_company(p_company_name text)
returns jsonb
language plpgsql
security definer
-- Set search path for security
set search_path = public
as $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_error_detail text;
begin
  -- Get current user
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
  
  -- Disable RLS for this transaction
  -- Safe because function is security definer and only creates resources for auth.uid()
  set local row_security = off;
  
  begin
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
    
  exception
    when others then
      -- Capture detailed error for debugging
      get stacked diagnostics v_error_detail = PG_EXCEPTION_DETAIL;
      
      return jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'detail', v_error_detail
      );
  end;
end;
$$;

comment on function create_company is 'Create a new company with the current user as owner and seed with basic accounts. Uses RLS bypass within security definer for cross-company operations.';
