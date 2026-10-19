import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { sendInvoiceReminder, getInvoice } from '@/lib/ledger'
import { generateInvoicePDF, getInvoicePDFFilename } from '@/lib/generate-invoice-pdf'
import { Resend } from 'resend'
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

function createServiceClient() {
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('Missing required Supabase environment variables')
  }
  
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY,
    {
      cookies: {
        getAll() { return [] },
        setAll() { },
      },
    }
  )
}

async function createBrowserClient() {
  const cookieStore = await cookies()
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY) {
    throw new Error('Missing required Supabase environment variables')
  }
  
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) => {
            cookieStore.set(name, value, options)
          })
        },
      },
    }
  )
}

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  
  // Try API key auth first
  const authHeader = request.headers.get('authorization')
  let auth: any
  let organizationId: string
  let userId: string
  let isAPIKeyAuth = false
  
  if (authHeader) {
    // API key authentication
    auth = await validateAPIKey(authHeader)
    if ('error' in auth) return errorResponse(auth, 401)

    const permError = checkPermission(auth, 'write')
    if (permError) return errorResponse(permError, 403)
    
    organizationId = auth.organizationId
    userId = auth.userId
    isAPIKeyAuth = true
  } else {
    // Session cookie authentication
    const supabase = await createBrowserClient()
    const { data: { user } } = await supabase.auth.getUser()
    
    if (!user) {
      return NextResponse.json(
        { error: { code: 'unauthorized', message: 'Authentication required' } },
        { status: 401 }
      )
    }
    
    // Get organization from session
    const { data: orgData } = await supabase.rpc('current_org_id')
    if (!orgData) {
      return NextResponse.json(
        { error: { code: 'no_organization', message: 'No organization found' } },
        { status: 403 }
      )
    }
    
    // Check role
    const { data: roleData } = await supabase.rpc('current_role')
    if (!roleData || !['owner', 'bookkeeper'].includes(roleData)) {
      return NextResponse.json(
        { error: { code: 'insufficient_permissions', message: 'Insufficient permissions' } },
        { status: 403 }
      )
    }
    
    organizationId = orgData
    userId = user.id
    isAPIKeyAuth = false
  }

  const idempotencyKey = isAPIKeyAuth ? request.headers.get('idempotency-key') : undefined
  if (idempotencyKey && isAPIKeyAuth) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/reminder`)
    if (cached) return cached
  }

  try {
    const body = await request.json().catch(() => ({}))
    // Accept multiple aliases for recipient email (first non-empty wins)
    const toEmail = body.to_email || body.email || body.to || body.recipient_email || undefined

    // Check RESEND_API_KEY first (fail early before any processing)
    if (!process.env.RESEND_API_KEY) {
      if (isAPIKeyAuth) await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 503)
      return NextResponse.json(
        { error: { code: 'service_unavailable', message: 'Email service is not configured. Set RESEND_API_KEY environment variable.' } },
        { status: 503 }
      )
    }

    // Validate and get invoice data (but don't record reminder yet)
    let reminderResult
    try {
      reminderResult = await sendInvoiceReminder(organizationId, id, userId, toEmail)
    } catch (error: any) {
      console.error('Send reminder validation error:', error)
      
      // Map authentication errors to 401
      if (error.message?.includes('Authentication required') || error.message?.includes('Not authenticated')) {
        if (isAPIKeyAuth) await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 401)
        return NextResponse.json(
          { error: { code: 'unauthorized', message: 'Authentication required' } },
          { status: 401 }
        )
      }
      
      // Schema cache / function errors to 503
      if (error.message?.includes('schema cache') || error.message?.includes('function') || error.message?.includes('not available')) {
        if (isAPIKeyAuth) await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 503)
        return NextResponse.json(
          { error: { code: 'service_unavailable', message: 'Invoice reminder feature is not available. Contact support.' } },
          { status: 503 }
        )
      }
      
      throw error
    }
    
    if (!reminderResult.success) {
      // Return validation error from RPC
      return NextResponse.json(
        { error: { code: 'validation_failed', message: reminderResult.error || 'Validation failed' } },
        { status: 400 }
      )
    }

    const invoice = await getInvoice(organizationId, id)
    
    const supabase = createServiceClient()
    const { data: customer } = await supabase
      .from('contacts')
      .select('name, email, address')
      .eq('id', invoice.customer_id)
      .single()

    const { data: lines } = await supabase
      .from('invoice_lines')
      .select('description, amount_cents')
      .eq('invoice_id', id)
      .order('line_number')

    // Generate PDF
    const pdfBuffer = await generateInvoicePDF({
      invoice: {
        number: reminderResult.invoice_number,
        invoice_date: invoice.invoice_date,
        due_date: invoice.due_date,
        total_cents: parseInt(invoice.total.amount) * 100,
        received_cents: parseInt(invoice.received.amount) * 100,
        notes: invoice.notes,
      },
      customer: {
        name: customer?.name || reminderResult.customer_name,
        email: customer?.email || reminderResult.to_email,
        address: customer?.address || undefined,
      },
      lines: lines?.map(line => ({
        description: line.description,
        quantity: 1,
        amount_cents: line.amount_cents,
      })) || [],
      organization: {
        legal_name: reminderResult.org_legal_name,
        registration_id: reminderResult.org_registration_id,
        address: reminderResult.org_address,
        email: reminderResult.org_email,
        phone: reminderResult.org_phone,
        payment_details: reminderResult.org_payment_details,
      },
    })

    // Get organization for sender identity
    const supabaseForOrg = createServiceClient()
    
    // Try to get per-company email columns (graceful fallback if migration not applied)
    let orgData: any = null
    let orgName: string = reminderResult.org_legal_name
    let invoiceFromEmail: string | null = null
    let invoiceReplyToEmail: string | null = null
    
    try {
      const { data, error } = await supabaseForOrg
        .from('organizations')
        .select('name, invoice_from_email, invoice_reply_to_email')
        .eq('id', organizationId)
        .single()
      
      if (error) throw error
      orgData = data
      orgName = orgData.name || reminderResult.org_legal_name
      invoiceFromEmail = orgData.invoice_from_email
      invoiceReplyToEmail = orgData.invoice_reply_to_email
    } catch (error: any) {
      // If columns don't exist (migration not applied), fall back to basic org name
      if (error.message?.includes('column') || error.code === 'PGRST116') {
        const { data } = await supabaseForOrg
          .from('organizations')
          .select('name')
          .eq('id', organizationId)
          .single()
        orgName = data?.name || reminderResult.org_legal_name
      } else {
        throw new Error('Organization not found')
      }
    }

    // Determine From email: per-company override or platform default
    let fromEmail: string
    
    if (invoiceFromEmail) {
      // Per-company override
      fromEmail = `${orgName} <${invoiceFromEmail}>`
    } else {
      // Platform default for all companies
      const platformDefault = process.env.RESEND_PLATFORM_FROM || process.env.RESEND_FROM_EMAIL
      if (!platformDefault) {
        if (isAPIKeyAuth) await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 503)
        return NextResponse.json(
          { error: { code: 'service_unavailable', message: 'Email sender is not configured. Set RESEND_PLATFORM_FROM or RESEND_FROM_EMAIL environment variable.' } },
          { status: 503 }
        )
      }
      fromEmail = `${orgName} <${platformDefault}>`
    }

    // Reply-To: org contact/billing email if set, otherwise omit
    const replyTo = invoiceReplyToEmail?.trim() || undefined
    
    // Send email (fail-fast if email fails - reminder not yet recorded)
    const resend = new Resend(process.env.RESEND_API_KEY)
    let emailResult
    try {
      emailResult = await resend.emails.send({
        from: fromEmail,
        to: reminderResult.to_email,
        replyTo: replyTo,
        subject: `Payment Reminder: Invoice ${reminderResult.invoice_number} from ${reminderResult.org_legal_name}`,
        text: `This is a payment reminder for invoice ${reminderResult.invoice_number} for ${reminderResult.customer_name}.`,
        attachments: [
          {
            filename: getInvoicePDFFilename(reminderResult.invoice_number),
            content: pdfBuffer,
          },
        ],
      })

      if (emailResult.error) {
        // Map Resend errors to calm messages (don't expose Resend internals)
        console.error('Resend error:', emailResult.error)
        if (isAPIKeyAuth) await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 400)
        return NextResponse.json(
          { error: { code: 'email_failed', message: 'Failed to send reminder email. Check the recipient email address.' } },
          { status: 400 }
        )
      }
    } catch (emailError: any) {
      // Catch network/API errors from Resend
      console.error('Email send error:', emailError)
      if (isAPIKeyAuth) await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 400)
      return NextResponse.json(
        { error: { code: 'email_failed', message: 'Failed to send reminder email. Check the recipient email address.' } },
        { status: 400 }
      )
    }

    // Record reminder AFTER email succeeds
    const { error: insertError } = await supabase
      .from('invoice_reminders')
      .insert({
        organization_id: organizationId,
        invoice_id: id,
        reminded_by: userId,
        reminded_to_email: reminderResult.to_email,
        message_id: emailResult.data?.id,
      })

    if (insertError) {
      console.error('Failed to record reminder after successful email send:', insertError)
      // Email was sent successfully, so we don't fail the request
    }

    // Log audit event AFTER email succeeds
    // Direct insert (not RPC) because service_role client has no auth.uid() context
    const { error: auditError } = await supabase
      .from('audit_events')
      .insert({
        organization_id: organizationId,
        entity_type: 'invoice',
        entity_id: id,
        action: 'invoice_reminder_sent',
        actor_id: userId,
        changes: {
          invoice_number: reminderResult.invoice_number,
          invoice_date: invoice.invoice_date,
          customer_name: customer?.name || reminderResult.customer_name,
          to_email: reminderResult.to_email,
        },
      })

    if (auditError) {
      console.error('Failed to log audit event after successful email send:', auditError)
      // Email was sent successfully, so we don't fail the request but log the error
    }

    // Get last reminder timestamp
    const { data: lastReminderData } = await supabase
      .from('invoice_reminders')
      .select('reminded_at')
      .eq('invoice_id', id)
      .eq('organization_id', organizationId)
      .order('reminded_at', { ascending: false })
      .limit(1)
      .maybeSingle()

    const result = {
      success: true,
      invoice_id: id,
      invoice_number: reminderResult.invoice_number,
      to_email: reminderResult.to_email,
      message_id: emailResult.data?.id,
      last_reminded: lastReminderData?.reminded_at || new Date().toISOString(),
    }

    if (idempotencyKey && isAPIKeyAuth) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/reminder`, 200, result)
    }

    if (isAPIKeyAuth) {
      await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 200, undefined, idempotencyKey || undefined)
    }
    return NextResponse.json(result)
  } catch (error: any) {
    if (isAPIKeyAuth) {
      await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/reminder`, 400, undefined, idempotencyKey || undefined)
    }
    return errorResponse({ error: { code: 'reminder_failed', message: error.message } }, 400)
  }
}
