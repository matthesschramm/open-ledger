-- Open Ledger S2-6: Invoices and AR
-- Add Customer contact type, invoices, invoice lines, and receipt tracking

-- ============================================================================
-- SCHEMA EXTENSION
-- ============================================================================

-- Add 'Customer' to contact_type enum
alter type contact_type add value if not exists 'Customer';

-- Invoice status enum
create type invoice_status as enum ('Quote', 'Draft', 'Posted', 'Paid', 'Void');

-- ============================================================================
-- INVOICES TABLE
-- ============================================================================

create table invoices (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  customer_id uuid not null references contacts(id),
  number text not null,
  invoice_date date not null,
  due_date date,
  status invoice_status not null default 'Draft',
  total_cents bigint not null check (total_cents >= 0),
  received_cents bigint not null default 0 check (received_cents >= 0),
  recognition_journal_id uuid references journals(id),
  notes text,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, number),
  check (received_cents <= total_cents)
);

create index invoices_organization_id_idx on invoices(organization_id);
create index invoices_customer_id_idx on invoices(customer_id);
create index invoices_status_idx on invoices(organization_id, status);
create index invoices_invoice_date_idx on invoices(organization_id, invoice_date);
create index invoices_due_date_idx on invoices(organization_id, due_date);

comment on table invoices is 'Customer invoices for AR tracking';
comment on column invoices.recognition_journal_id is 'The journal that recognized this invoice (Dr AR, Cr revenue)';
comment on column invoices.status is 'Quote = not posted yet, Draft = ready to post, Posted = booked as AR, Paid = fully collected, Void = cancelled';

-- ============================================================================
-- INVOICE LINES
-- ============================================================================

create table invoice_lines (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  invoice_id uuid not null references invoices(id) on delete cascade,
  account_id uuid not null references accounts(id),
  line_number int not null,
  description text not null,
  amount_cents bigint not null check (amount_cents >= 0),
  created_at timestamptz not null default now(),
  unique(invoice_id, line_number)
);

create index invoice_lines_organization_id_idx on invoice_lines(organization_id);
create index invoice_lines_invoice_id_idx on invoice_lines(invoice_id);
create index invoice_lines_account_id_idx on invoice_lines(account_id);

comment on table invoice_lines is 'Line items for invoices, each mapped to a revenue account';

-- ============================================================================
-- INVOICE RECEIPTS
-- ============================================================================

create table invoice_receipts (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  invoice_id uuid not null references invoices(id) on delete cascade,
  receipt_journal_id uuid not null references journals(id),
  receipt_date date not null,
  amount_cents bigint not null check (amount_cents > 0),
  receipt_type text not null default 'payment' check (receipt_type in ('payment', 'credit_note', 'write_off')),
  notes text,
  created_by uuid not null,
  created_at timestamptz not null default now()
);

create index invoice_receipts_organization_id_idx on invoice_receipts(organization_id);
create index invoice_receipts_invoice_id_idx on invoice_receipts(invoice_id);
create index invoice_receipts_receipt_date_idx on invoice_receipts(organization_id, receipt_date);

comment on table invoice_receipts is 'Tracks receipts (payments, credit notes, write-offs) against invoices';
comment on column invoice_receipts.receipt_type is 'payment = cash receipt, credit_note = revenue reversal, write_off = bad debt expense';

-- ============================================================================
-- INVOICE REMINDERS (AUDIT LOG ONLY)
-- ============================================================================

-- Reminders are tracked via audit_events only, no separate table needed
-- Action: 'invoice_reminder_sent' with invoice_id and customer email in changes

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

-- Invoices policies (read all, write bookkeeper+)
alter table invoices enable row level security;

create policy "Users can view invoices in their organization"
  on invoices for select
  using (organization_id = current_org_id());

create policy "Bookkeepers can insert invoices"
  on invoices for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

create policy "Bookkeepers can update invoices"
  on invoices for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

-- Invoice lines policies
alter table invoice_lines enable row level security;

create policy "Users can view invoice lines in their organization"
  on invoice_lines for select
  using (organization_id = current_org_id());

create policy "Bookkeepers can insert invoice lines"
  on invoice_lines for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

create policy "Bookkeepers can update invoice lines"
  on invoice_lines for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

create policy "Bookkeepers can delete invoice lines"
  on invoice_lines for delete
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

-- Invoice receipts policies
alter table invoice_receipts enable row level security;

create policy "Users can view invoice receipts in their organization"
  on invoice_receipts for select
  using (organization_id = current_org_id());

create policy "Bookkeepers can insert invoice receipts"
  on invoice_receipts for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );
