-- Enum values for the fixed-asset register.
-- ADD VALUE cannot be used in the same transaction as the new labels,
-- so this file is separate from tables and RPCs.

alter type journal_source add value if not exists 'fixed_asset';
alter type journal_source add value if not exists 'depreciation';
alter type journal_source add value if not exists 'disposal';

do $$
begin
  if not exists (select 1 from pg_type where typname = 'fixed_asset_status') then
    create type fixed_asset_status as enum ('in_use', 'held_for_sale', 'disposed', 'impaired');
  end if;
  if not exists (select 1 from pg_type where typname = 'depreciation_method') then
    create type depreciation_method as enum ('straight_line');
  end if;
  if not exists (select 1 from pg_type where typname = 'fixed_asset_class') then
    create type fixed_asset_class as enum (
      'equipment',
      'furniture',
      'leasehold_improvements',
      'intangible'
    );
  end if;
end
$$;
