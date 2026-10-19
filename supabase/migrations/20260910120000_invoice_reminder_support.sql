-- Invoice Reminder Support
-- Separate tracking for reminders (no GL impact, separate from invoice_sends)

-- ============================================================================
-- INVOICE REMINDERS TABLE
-- ============================================================================

create table invoice_reminders (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  invoice_id uuid not null references invoices(id) on delete cascade,
  reminded_at timestamptz not null default now(),
  reminded_by uuid not null,
  reminded_to_email text not null,
  message_id text,
  created_at timestamptz not null default now()
);

create index invoice_reminders_organization_id_idx on invoice_reminders(organization_id);
create index invoice_reminders_invoice_id_idx on invoice_reminders(invoice_id);
create index invoice_reminders_reminded_at_idx on invoice_reminders(organization_id, reminded_at);

comment on table invoice_reminders is 'Tracks invoice reminders via email (no journal entries, separate from sends)';
comment on column invoice_reminders.message_id is 'Email provider message ID (e.g., Resend)';
comment on column invoice_reminders.reminded_to_email is 'Email address the reminder was sent to';

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

alter table invoice_reminders enable row level security;

create policy "Users can view invoice reminders in their organization"
  on invoice_reminders for select
  using (organization_id = current_org_id());

create policy "Bookkeepers can insert invoice reminders"
  on invoice_reminders for insert
  with check (
    organization_id = current_org_id()
    and has_role('bookkeeper')
  );

-- ============================================================================
-- SEND INVOICE REMINDER RPC
-- ============================================================================

create or replace function send_invoice_reminder(
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
  v_last_reminder record;
  v_invoice_number text;
  v_open_balance_cents bigint;
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

  -- Check invoice status (must be Posted or Paid)
  if v_invoice.status = 'Draft' then
    return jsonb_build_object('success', false, 'error', 'Post the invoice before sending.');
  end if;

  if v_invoice.status = 'Quote' then
    return jsonb_build_object('success', false, 'error', 'Quotes aren''t sent as invoices.');
  end if;

  if v_invoice.status = 'Void' then
    return jsonb_build_object('success', false, 'error', 'Cannot send reminder for void invoice.');
  end if;

  -- Check for open balance
  v_open_balance_cents := v_invoice.total_cents - v_invoice.received_cents;
  if v_open_balance_cents <= 0 then
    return jsonb_build_object('success', false, 'error', 'Invoice is paid in full.');
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

  -- Record the reminder (placeholder - actual email sending happens in application code)
  insert into invoice_reminders (
    organization_id,
    invoice_id,
    reminded_by,
    reminded_to_email
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
    'invoice_reminder_sent',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'customer_name', v_customer.name,
      'to_email', v_to_email
    )
  );

  -- Get last reminder info for response
  select reminded_at, reminded_to_email into v_last_reminder
  from invoice_reminders
  where invoice_id = p_invoice_id
    and organization_id = v_org_id
  order by reminded_at desc
  limit 1;

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'to_email', v_to_email,
    'last_reminded', v_last_reminder.reminded_at,
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

grant execute on function send_invoice_reminder to authenticated;
grant execute on function send_invoice_reminder to anon;
grant execute on function send_invoice_reminder to service_role;

comment on function send_invoice_reminder is 'Records invoice reminder and returns org/invoice data for PDF generation (no GL posting, separate from sends)';

-- Notify PostgREST to reload schema cache
notify pgrst, 'reload schema';
