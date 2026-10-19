-- Fix send_invoice and send_invoice_reminder to use API key's organization_id
-- 
-- Root cause: current_org_id() reads user_settings.active_company_id, which is
-- the user's currently selected company in the UI. For API key authentication,
-- the organization should come from the API key's organization_id, not the user's
-- active company setting.
--
-- Multi-org scenario:
-- 1. User has access to Demo (org A) and Org B (org B)
-- 2. User's active_company_id is set to Demo
-- 3. API key belongs to Org B
-- 4. RPC calls current_org_id() → returns Demo (wrong!)
-- 5. Invoice lookup in Demo org fails → "Invoice not found"
--
-- Fix: Add p_organization_id parameter. When provided (API key auth), use it
-- instead of current_org_id(). Browser JWT auth path continues using current_org_id().

drop function if exists send_invoice(uuid, text, uuid);

create or replace function send_invoice(
  p_invoice_id uuid,
  p_to_email text default null,
  p_user_id uuid default null,
  p_organization_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
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
  -- Support API-key authentication via assume_request_user
  perform assume_request_user(p_user_id);
  
  -- Get current user and org
  select auth.uid() into v_user_id;
  if v_user_id is null then
    return jsonb_build_object('success', false, 'error', 'Not authenticated');
  end if;

  -- Use provided organization_id (API key auth) or fall back to current_org_id() (browser auth)
  v_org_id := coalesce(p_organization_id, current_org_id());
  if v_org_id is null then
    return jsonb_build_object('success', false, 'error', 'Organization not found');
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
  if v_invoice.number ~ '^[0-9]+$' then
    v_invoice_number := 'INV-' || to_char(v_invoice.invoice_date::date, 'YYYY') || '-' || lpad(v_invoice.number, 4, '0');
  else
    v_invoice_number := v_invoice.number;
  end if;

  -- Record the send
  insert into invoice_sends (
    organization_id,
    invoice_id,
    sent_at,
    sent_by,
    sent_to_email,
    message_id
  ) values (
    v_org_id,
    p_invoice_id,
    now(),
    v_user_id,
    v_to_email,
    null  -- Will be updated by API layer after Resend returns message_id
  )
  returning sent_at, sent_to_email into v_last_send;

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

  -- Return success with data needed for PDF generation and email
  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'invoice_number', v_invoice_number,
    'customer_name', v_customer.name,
    'to_email', v_to_email,
    'org_legal_name', coalesce(v_org.legal_name, v_org.name),
    'org_registration_id', v_org.registration_id,
    'org_address', v_org.address,
    'org_email', v_org.email,
    'org_phone', v_org.phone,
    'org_payment_details', v_org.payment_details,
    'last_sent', jsonb_build_object(
      'date', v_last_send.sent_at,
      'email', v_last_send.sent_to_email
    )
  );
end;
$$;

grant execute on function send_invoice(uuid, text, uuid, uuid) to authenticated, anon, service_role;

comment on function send_invoice is 'Send an invoice via email. Does NOT post to GL. Supports both browser (JWT) and API-key (service_role + p_user_id + p_organization_id) authentication. API key auth must pass p_organization_id to avoid wrong-org lookup via current_org_id().';

-- ============================================================================
-- send_invoice_reminder: Add p_organization_id parameter
-- ============================================================================

drop function if exists send_invoice_reminder(uuid, text, uuid);

create or replace function send_invoice_reminder(
  p_invoice_id uuid,
  p_to_email text default null,
  p_user_id uuid default null,
  p_organization_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_user_id uuid;
  v_invoice record;
  v_customer record;
  v_org record;
  v_to_email text;
  v_invoice_number text;
  v_open_balance_cents bigint;
begin
  -- Support API-key authentication via assume_request_user
  perform assume_request_user(p_user_id);
  
  -- Get current user and org
  select auth.uid() into v_user_id;
  if v_user_id is null then
    return jsonb_build_object('success', false, 'error', 'Not authenticated');
  end if;

  -- Use provided organization_id (API key auth) or fall back to current_org_id() (browser auth)
  v_org_id := coalesce(p_organization_id, current_org_id());
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
  if v_invoice.number ~ '^[0-9]+$' then
    v_invoice_number := 'INV-' || to_char(v_invoice.invoice_date::date, 'YYYY') || '-' || lpad(v_invoice.number, 4, '0');
  else
    v_invoice_number := v_invoice.number;
  end if;

  -- Return success with data needed for PDF generation and email
  -- Note: Reminder record is inserted by API layer after email succeeds
  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'invoice_number', v_invoice_number,
    'customer_name', v_customer.name,
    'to_email', v_to_email,
    'org_legal_name', coalesce(v_org.legal_name, v_org.name),
    'org_registration_id', v_org.registration_id,
    'org_address', v_org.address,
    'org_email', v_org.email,
    'org_phone', v_org.phone,
    'org_payment_details', v_org.payment_details
  );
end;
$$;

grant execute on function send_invoice_reminder(uuid, text, uuid, uuid) to authenticated, anon, service_role;

comment on function send_invoice_reminder is 'Validate invoice reminder eligibility and return data for email/PDF generation. Supports both browser (JWT) and API-key (service_role + p_user_id + p_organization_id) authentication. API key auth must pass p_organization_id to avoid wrong-org lookup via current_org_id(). Does NOT post to GL or record reminder (API layer does that after email succeeds).';

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';
