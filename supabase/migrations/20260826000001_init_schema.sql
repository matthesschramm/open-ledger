-- Open Ledger Schema
-- Phase 3: Database schema for multi-tenant accounting system
-- Money stored as bigint cents (USD), dates as date, audit timestamps as timestamptz
-- Timezone assumption: America/New_York

-- Enable required extensions
create extension if not exists "uuid-ossp";

-- ============================================================================
-- TYPES
-- ============================================================================

create type account_type as enum ('Asset', 'Liability', 'Equity', 'Revenue', 'Expense');
create type account_category as enum ('Cash', 'AR', 'AP', 'Equity', 'Revenue', 'COGS', 'Expense', 'Other');
create type journal_status as enum ('Draft', 'Posted', 'Reversed');
create type journal_source as enum ('manual', 'bill', 'bill_payment', 'opening', 'reversal', 'cash');
create type contact_type as enum ('Vendor', 'Other');
create type bill_status as enum ('Draft', 'Open', 'Paid', 'Void');
create type membership_role as enum ('owner', 'admin', 'bookkeeper', 'read_only');

-- ============================================================================
-- ORGANIZATIONS
-- ============================================================================

create table organizations (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  currency_code text not null default 'USD',
  timezone text not null default 'America/New_York',
  fiscal_year_end_month int not null default 12 check (fiscal_year_end_month between 1 and 12),
  fiscal_year_end_day int not null default 31 check (fiscal_year_end_day between 1 and 31),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index organizations_created_at_idx on organizations(created_at);

-- ============================================================================
-- MEMBERSHIPS
-- ============================================================================

create table memberships (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null,
  role membership_role not null default 'read_only',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, user_id)
);

create index memberships_organization_id_idx on memberships(organization_id);
create index memberships_user_id_idx on memberships(user_id);

-- ============================================================================
-- API KEYS
-- ============================================================================

create table api_keys (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  key_hash text not null unique,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at timestamptz,
  is_active boolean not null default true
);

create index api_keys_organization_id_idx on api_keys(organization_id);
create index api_keys_key_hash_idx on api_keys(key_hash);

-- ============================================================================
-- ACCOUNTS (Chart of Accounts)
-- ============================================================================

create table accounts (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  code text not null,
  name text not null,
  type account_type not null,
  category account_category not null,
  is_header boolean not null default false,
  is_cash boolean not null default false,
  is_system boolean not null default false,
  is_active boolean not null default true,
  parent_id uuid references accounts(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, code),
  check (not (is_header and is_cash)),
  check (not (is_cash and type != 'Asset'))
);

create index accounts_organization_id_idx on accounts(organization_id);
create index accounts_code_idx on accounts(organization_id, code);
create index accounts_type_idx on accounts(organization_id, type);
create index accounts_is_active_idx on accounts(organization_id, is_active);
create index accounts_parent_id_idx on accounts(parent_id);

comment on column accounts.is_header is 'Header accounts cannot have journal lines posted to them';
comment on column accounts.is_cash is 'Cash accounts are included in cash movement reports';
comment on column accounts.is_system is 'System accounts cannot be archived or have type changed';

-- ============================================================================
-- ACCOUNTING PERIODS
-- ============================================================================

create table accounting_periods (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  start_date date not null,
  end_date date not null,
  is_locked boolean not null default false,
  locked_at timestamptz,
  locked_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_date < end_date),
  unique(organization_id, start_date, end_date)
);

create index accounting_periods_organization_id_idx on accounting_periods(organization_id);
create index accounting_periods_dates_idx on accounting_periods(organization_id, start_date, end_date);

-- ============================================================================
-- CONTACTS
-- ============================================================================

create table contacts (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  type contact_type not null,
  name text not null,
  email text,
  phone text,
  address text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index contacts_organization_id_idx on contacts(organization_id);
create index contacts_type_idx on contacts(organization_id, type);
create index contacts_name_idx on contacts(organization_id, name);

-- ============================================================================
-- JOURNALS
-- ============================================================================

create table journals (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  number text not null,
  entry_date date not null,
  description text not null,
  status journal_status not null default 'Draft',
  source journal_source not null default 'manual',
  reverses_journal_id uuid references journals(id),
  reversed_by_journal_id uuid references journals(id),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  posted_at timestamptz,
  posted_by uuid,
  updated_at timestamptz not null default now(),
  unique(organization_id, number)
);

create index journals_organization_id_idx on journals(organization_id);
create index journals_status_idx on journals(organization_id, status);
create index journals_entry_date_idx on journals(organization_id, entry_date);
create index journals_reverses_journal_id_idx on journals(reverses_journal_id);
create index journals_reversed_by_journal_id_idx on journals(reversed_by_journal_id);

comment on column journals.reverses_journal_id is 'Set on the reversal journal, points to the original';
comment on column journals.reversed_by_journal_id is 'Set on the original journal when reversed, points to the reversal';

-- ============================================================================
-- JOURNAL LINES
-- ============================================================================

create table journal_lines (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  journal_id uuid not null references journals(id) on delete cascade,
  account_id uuid not null references accounts(id),
  debit_cents bigint not null default 0 check (debit_cents >= 0),
  credit_cents bigint not null default 0 check (credit_cents >= 0),
  memo text,
  created_at timestamptz not null default now(),
  check ((debit_cents > 0 and credit_cents = 0) or (credit_cents > 0 and debit_cents = 0))
);

create index journal_lines_organization_id_idx on journal_lines(organization_id);
create index journal_lines_journal_id_idx on journal_lines(journal_id);
create index journal_lines_account_id_idx on journal_lines(account_id);

comment on constraint journal_lines_check on journal_lines is 'Exactly one of debit_cents or credit_cents must be > 0';

-- ============================================================================
-- BILLS
-- ============================================================================

create table bills (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  vendor_id uuid not null references contacts(id),
  number text not null,
  bill_date date not null,
  due_date date not null,
  status bill_status not null default 'Draft',
  total_cents bigint not null check (total_cents >= 0),
  paid_cents bigint not null default 0 check (paid_cents >= 0),
  recognition_journal_id uuid references journals(id),
  notes text,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, number),
  check (paid_cents <= total_cents)
);

create index bills_organization_id_idx on bills(organization_id);
create index bills_vendor_id_idx on bills(vendor_id);
create index bills_status_idx on bills(organization_id, status);
create index bills_due_date_idx on bills(organization_id, due_date);

comment on column bills.recognition_journal_id is 'The journal that recognized this bill (Dr expense, Cr AP)';

-- ============================================================================
-- BILL LINES
-- ============================================================================

create table bill_lines (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  bill_id uuid not null references bills(id) on delete cascade,
  account_id uuid not null references accounts(id),
  description text not null,
  amount_cents bigint not null check (amount_cents >= 0),
  created_at timestamptz not null default now()
);

create index bill_lines_organization_id_idx on bill_lines(organization_id);
create index bill_lines_bill_id_idx on bill_lines(bill_id);
create index bill_lines_account_id_idx on bill_lines(account_id);

-- ============================================================================
-- BILL PAYMENTS
-- ============================================================================

create table bill_payments (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  bill_id uuid not null references bills(id) on delete cascade,
  payment_journal_id uuid not null references journals(id),
  payment_date date not null,
  amount_cents bigint not null check (amount_cents > 0),
  created_by uuid not null,
  created_at timestamptz not null default now()
);

create index bill_payments_organization_id_idx on bill_payments(organization_id);
create index bill_payments_bill_id_idx on bill_payments(bill_id);
create index bill_payments_payment_journal_id_idx on bill_payments(payment_journal_id);

comment on column bill_payments.payment_journal_id is 'The journal that paid this bill (Dr AP, Cr cash)';

-- ============================================================================
-- ATTACHMENTS
-- ============================================================================

create table attachments (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  file_name text not null,
  file_size bigint not null,
  content_type text not null,
  storage_path text not null,
  uploaded_by uuid not null,
  created_at timestamptz not null default now()
);

create index attachments_organization_id_idx on attachments(organization_id);
create index attachments_entity_idx on attachments(entity_type, entity_id);

comment on column attachments.storage_path is 'Path in Supabase storage bucket: org/{organization_id}/...';

-- ============================================================================
-- AUDIT EVENTS
-- ============================================================================

create table audit_events (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  actor_id uuid not null,
  changes jsonb,
  created_at timestamptz not null default now()
);

create index audit_events_organization_id_idx on audit_events(organization_id);
create index audit_events_entity_idx on audit_events(entity_type, entity_id);
create index audit_events_created_at_idx on audit_events(organization_id, created_at desc);

-- ============================================================================
-- UPDATED_AT TRIGGER
-- ============================================================================

create or replace function update_updated_at_column()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger update_organizations_updated_at before update on organizations
  for each row execute function update_updated_at_column();

create trigger update_memberships_updated_at before update on memberships
  for each row execute function update_updated_at_column();

create trigger update_accounts_updated_at before update on accounts
  for each row execute function update_updated_at_column();

create trigger update_accounting_periods_updated_at before update on accounting_periods
  for each row execute function update_updated_at_column();

create trigger update_contacts_updated_at before update on contacts
  for each row execute function update_updated_at_column();

create trigger update_journals_updated_at before update on journals
  for each row execute function update_updated_at_column();

create trigger update_bills_updated_at before update on bills
  for each row execute function update_updated_at_column();
