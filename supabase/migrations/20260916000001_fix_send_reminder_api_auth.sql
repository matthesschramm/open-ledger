-- Fix send_invoice_reminder to work with API-key authentication
-- Root cause: send_invoice_reminder lacks p_user_id parameter and assume_request_user call,
-- causing current_org_id() to fail under service_role (API key auth), returning "Invoice not found".
-- Solution: Add p_user_id parameter and use assume_request_user pattern (same fix as send_invoice).

drop function if exists send_invoice_reminder(uuid, text);

create or replace function send_invoice_reminder(
  p_invoice_id uuid,
  p_to_email text default null,
  p_user_id uuid default null
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

grant execute on function send_invoice_reminder(uuid, text, uuid) to authenticated, anon, service_role;

comment on function send_invoice_reminder is 'Validate invoice reminder eligibility and return data for email/PDF generation. Supports both browser (JWT) and API-key (service_role + p_user_id) authentication. Does NOT post to GL or record reminder (API layer does that after email succeeds).';

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';
