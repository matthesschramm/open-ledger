-- Apply send_invoice function to shared Supabase project
-- Run this via Supabase Dashboard SQL Editor or supabase db push

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
