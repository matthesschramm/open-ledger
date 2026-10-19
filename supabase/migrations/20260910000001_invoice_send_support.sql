-- Invoice Send Support
-- Add organization PDF fields and invoice sends tracking

-- ============================================================================
-- ORGANIZATION PDF FIELDS
-- ============================================================================

-- Add fields for PDF generation (identity only, no journal entries)
alter table organizations add column if not exists legal_name text;
alter table organizations add column if not exists registration_id text;
alter table organizations add column if not exists address text;
alter table organizations add column if not exists email text;
alter table organizations add column if not exists phone text;
alter table organizations add column if not exists payment_details text;

comment on column organizations.legal_name is 'Legal name for invoices (defaults to name if not set)';
comment on column organizations.registration_id is 'Registration or tax ID for invoice PDFs';
comment on column organizations.address is 'Organization address for invoice PDFs';
comment on column organizations.email is 'Organization email for invoice PDFs';
comment on column organizations.phone is 'Organization phone for invoice PDFs';
comment on column organizations.payment_details is 'Payment instructions shown on invoice PDFs';

-- ============================================================================
-- INVOICE SENDS TABLE
-- ============================================================================

create table invoice_sends (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  invoice_id uuid not null references invoices(id) on delete cascade,
  sent_at timestamptz not null default now(),
  sent_by uuid not null,
  sent_to_email text not null,
  message_id text,
  created_at timestamptz not null default now()
);

create index invoice_sends_organization_id_idx on invoice_sends(organization_id);
create index invoice_sends_invoice_id_idx on invoice_sends(invoice_id);
create index invoice_sends_sent_at_idx on invoice_sends(organization_id, sent_at);

comment on table invoice_sends is 'Tracks invoice sends via email (no journal entries)';
comment on column invoice_sends.message_id is 'Email provider message ID (e.g., Resend)';
comment on column invoice_sends.sent_to_email is 'Email address the invoice was sent to';

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

alter table invoice_sends enable row level security;

create policy "Users can view invoice sends in their organization"
  on invoice_sends for select
  using (organization_id = current_org_id());

create policy "Bookkeepers can insert invoice sends"
  on invoice_sends for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

-- ============================================================================
-- SEND INVOICE RPC
-- ============================================================================

create or replace function send_invoice(
  p_invoice_id uuid,
  p_to_email text default null
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_invoice record;
  v_customer record;
  v_org record;
  v_to_email text;
  v_last_send record;
  v_invoice_number text;
begin
  -- Get current user and org
  select auth.uid() into v_user_id;
  if v_user_id is null then
    return jsonb_build_object('success', false, 'error', 'Not authenticated');
  end if;

  select current_org_id() into v_org_id;
  if v_org_id is null then
    return jsonb_build_object('success', false, 'error', 'Organization not found');
  end if;

  -- Check permission (bookkeeper or owner)
  if not has_role('bookkeeper') then
    return jsonb_build_object('success', false, 'error', 'Insufficient permissions');
  end if;

  -- Fetch invoice
  select * into v_invoice
  from invoices
  where id = p_invoice_id
    and organization_id = v_org_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Invoice not found');
  end if;

  -- Check invoice status (must be Posted, Paid, or similar - not Draft or Quote)
  if v_invoice.status = 'Draft' then
    return jsonb_build_object('success', false, 'error', 'Post the invoice before sending.');
  end if;

  if v_invoice.status = 'Quote' then
    return jsonb_build_object('success', false, 'error', 'Quotes aren''t sent as invoices.');
  end if;

  -- Fetch customer
  select * into v_customer
  from contacts
  where id = v_invoice.customer_id
    and organization_id = v_org_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Customer not found');
  end if;

  -- Determine target email
  v_to_email := coalesce(p_to_email, v_customer.email);
  
  if v_to_email is null or v_to_email = '' then
    return jsonb_build_object('success', false, 'error', 'Add an email on the customer before sending.');
  end if;

  -- Fetch organization details
  select * into v_org
  from organizations
  where id = v_org_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Organization not found');
  end if;

  -- Check for legal name requirement
  if coalesce(v_org.legal_name, v_org.name) is null or coalesce(v_org.legal_name, v_org.name) = '' then
    return jsonb_build_object('success', false, 'error', 'Add organization details in Settings before sending.');
  end if;

  -- Format invoice number
  v_invoice_number := case
    when v_invoice.number ~ '^[0-9]+$' then
      'INV-' || extract(year from v_invoice.invoice_date)::text || '-' || lpad(v_invoice.number, 4, '0')
    else
      v_invoice.number
  end;

  -- Record the send (placeholder - actual email sending happens in application code)
  -- This function returns success=true, and the application layer handles Resend
  insert into invoice_sends (
    organization_id,
    invoice_id,
    sent_by,
    sent_to_email
  ) values (
    v_org_id,
    p_invoice_id,
    v_user_id,
    v_to_email
  );

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'invoice_sent',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'invoice_date', v_invoice.invoice_date,
      'customer_name', v_customer.name,
      'to_email', v_to_email
    )
  );

  -- Get last send info for response
  select sent_at, sent_to_email into v_last_send
  from invoice_sends
  where invoice_id = p_invoice_id
    and organization_id = v_org_id
  order by sent_at desc
  limit 1;

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'to_email', v_to_email,
    'last_sent', v_last_send.sent_at,
    'invoice_number', v_invoice_number,
    'customer_name', v_customer.name,
    'org_legal_name', coalesce(v_org.legal_name, v_org.name),
    'org_registration_id', v_org.registration_id,
    'org_address', v_org.address,
    'org_email', v_org.email,
    'org_phone', v_org.phone,
    'org_payment_details', v_org.payment_details
  );
end;
$$;

grant execute on function send_invoice to authenticated;
grant execute on function send_invoice to anon;
grant execute on function send_invoice to service_role;

comment on function send_invoice is 'Records invoice send and returns org/invoice data for PDF generation (no GL posting)';

-- Notify PostgREST to reload schema cache
notify pgrst, 'reload schema';
