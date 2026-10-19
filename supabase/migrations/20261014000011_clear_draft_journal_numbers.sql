-- ============================================================================
-- MIGRATION 000011: CLEAR DRAFT JOURNAL NUMBERS
-- ============================================================================
-- Draft journals should have NULL number. Numbers are assigned when posted.

-- Clear any existing numbers on Draft journals
update journals 
set number = null 
where status = 'Draft' 
  and number is not null;

comment on column journals.number is 'Journal number assigned at post time (NULL for drafts)';

-- Update next_journal_number to exclude Draft journals when computing max
create or replace function next_journal_number(
  p_organization_id uuid,
  p_entry_date date
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int;
  v_next_number int;
  v_journal_number text;
begin
  -- Lock organization row to serialize number generation
  perform 1 from organizations where id = p_organization_id for update;
  
  v_year := extract(year from p_entry_date);
  
  select coalesce(max(cast(substring(number from 'JE-[0-9]+-([0-9]+)') as int)), 0) + 1
  into v_next_number
  from journals
  where organization_id = p_organization_id
    and number ~ ('^JE-' || v_year || '-[0-9]+$')
    and status <> 'Draft';
  
  v_journal_number := 'JE-' || v_year || '-' || lpad(v_next_number::text, 4, '0');
  
  return v_journal_number;
end;
$$;

revoke all on function next_journal_number(uuid, date) from public, anon, authenticated;
