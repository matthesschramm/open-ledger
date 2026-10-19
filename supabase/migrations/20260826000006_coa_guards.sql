-- Open Ledger CoA Guards
-- Phase 3 Fix: Triggers and constraints to enforce CoA rules

-- ============================================================================
-- GUARD 1: System accounts cannot be archived or have type changed
-- ============================================================================

create or replace function prevent_system_account_changes()
returns trigger
language plpgsql
as $$
begin
  -- Check if trying to modify a system account
  if old.is_system = true then
    -- Prevent archiving (is_active change)
    if old.is_active = true and new.is_active = false then
      raise exception 'System account % (%) cannot be archived', old.code, old.name;
    end if;
    
    -- Prevent type change
    if old.type != new.type then
      raise exception 'System account % (%) type cannot be changed', old.code, old.name;
    end if;
  end if;
  
  return new;
end;
$$;

create trigger enforce_system_account_guards
  before update on accounts
  for each row
  execute function prevent_system_account_changes();

comment on function prevent_system_account_changes is 'Prevents system accounts from being archived or having their type changed';

-- ============================================================================
-- GUARD 2: Account with posted lines cannot change type
-- ============================================================================

create or replace function prevent_type_change_with_posted_lines()
returns trigger
language plpgsql
as $$
declare
  v_has_posted_lines boolean;
begin
  -- Only check if type is changing
  if old.type != new.type then
    -- Check if account has any posted journal lines
    select exists(
      select 1
      from journal_lines jl
      join journals j on j.id = jl.journal_id
      where jl.account_id = old.id
        and j.status in ('Posted', 'Reversed')
    ) into v_has_posted_lines;
    
    if v_has_posted_lines then
      raise exception 'Account % (%) has posted journal lines and cannot change type from % to %',
        old.code, old.name, old.type, new.type;
    end if;
  end if;
  
  return new;
end;
$$;

create trigger enforce_posted_lines_type_lock
  before update on accounts
  for each row
  execute function prevent_type_change_with_posted_lines();

comment on function prevent_type_change_with_posted_lines is 'Prevents changing account type if the account has posted journal lines';

-- ============================================================================
-- GUARD 3: Account 2300 (Credit cards) must be liability and never is_cash
-- ============================================================================

create or replace function enforce_credit_card_account_rules()
returns trigger
language plpgsql
as $$
begin
  -- Check if this is account 2300 (Credit cards)
  if new.code = '2300' then
    -- Must be Liability type
    if new.type != 'Liability' then
      raise exception 'Account 2300 (Credit cards) must be Liability type, got %', new.type;
    end if;
    
    -- Cannot be is_cash
    if new.is_cash = true then
      raise exception 'Account 2300 (Credit cards) cannot be marked as is_cash';
    end if;
  end if;
  
  return new;
end;
$$;

create trigger enforce_credit_card_account_guards
  before insert or update on accounts
  for each row
  execute function enforce_credit_card_account_rules();

comment on function enforce_credit_card_account_rules is 'Enforces that account 2300 (Credit cards) is always Liability type and never is_cash';

-- ============================================================================
-- ADDITIONAL CONSTRAINT: Cash accounts must be Asset type
-- ============================================================================

-- This is already enforced by the table-level constraint:
-- check (not (is_cash and type != 'Asset'))

-- Verify it exists
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'accounts_check1'
      and conrelid = 'accounts'::regclass
  ) then
    alter table accounts add constraint accounts_is_cash_must_be_asset
      check (not (is_cash and type != 'Asset'));
  end if;
end $$;
