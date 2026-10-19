-- Backfill invoice numbers in existing journal descriptions and line memos
-- Changes "Posted Invoice 1" to "Posted Invoice INV-2026-0001" based on entry_date
-- Does NOT change debit/credit amounts or account assignments

-- Helper function to format invoice references in text
create or replace function format_journal_text_backfill(
  p_text text,
  p_entry_date date
)
returns text
language plpgsql
immutable
as $$
declare
  v_year text;
  v_result text;
begin
  if p_text is null or p_entry_date is null then
    return p_text;
  end if;

  v_year := extract(year from p_entry_date)::text;
  
  -- Replace "Invoice 123" or "invoice 123" with formatted version
  -- Pattern matches word boundary, "invoice" (case insensitive), whitespace, digits, word boundary
  v_result := regexp_replace(
    p_text,
    '\m(invoice)\s+(\d+)\M',
    'Invoice INV-' || v_year || '-' || lpad('\2', 4, '0'),
    'gi'
  );
  
  return v_result;
end;
$$;

comment on function format_journal_text_backfill is 'Format invoice references in journal text for backfill migration. Converts "Invoice 1" to "Invoice INV-YYYY-0001" using entry_date year.';

-- Update journal descriptions
update journals
set description = format_journal_text_backfill(description, entry_date)
where description ~* '\m(invoice)\s+\d+\M';

-- Update journal line memos
update journal_lines jl
set memo = format_journal_text_backfill(jl.memo, j.entry_date)
from journals j
where jl.journal_id = j.id
  and jl.memo ~* '\m(invoice)\s+\d+\M';

-- Drop the helper function (only needed for migration)
drop function format_journal_text_backfill;

-- Verify the format_invoice_number function is still available for future use
-- (This is from the previous migration 20260831000001)
comment on function format_invoice_number is 'Format invoice number for display. Used in new journal creation and audit logging.';
