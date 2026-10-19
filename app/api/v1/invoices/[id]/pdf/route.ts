import { NextRequest, NextResponse } from 'next/server'
import { createServerClient } from '@supabase/ssr'
import { generateInvoicePDF, getInvoicePDFFilename } from '@/lib/generate-invoice-pdf'

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

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  
  try {
    const supabase = createServiceClient()

    // Get authenticated user
    const authHeader = request.headers.get('cookie')
    let userId: string | null = null
    
    if (authHeader) {
      const userClient = createServerClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        {
          cookies: {
            getAll() {
              return authHeader.split('; ').map(cookie => {
                const [name, ...valueParts] = cookie.split('=')
                return { name, value: valueParts.join('=') }
              })
            },
            setAll() { },
          },
        }
      )
      const { data: { user } } = await userClient.auth.getUser()
      userId = user?.id || null
    }

    if (!userId) {
      return new NextResponse('Unauthorized', { status: 401 })
    }

    // Fetch invoice
    const { data: invoice, error: invoiceError } = await supabase
      .from('invoices')
      .select('*')
      .eq('id', id)
      .single()

    if (invoiceError || !invoice) {
      return new NextResponse('Invoice not found', { status: 404 })
    }

    // Fetch customer
    const { data: customer } = await supabase
      .from('contacts')
      .select('name, email, address')
      .eq('id', invoice.customer_id)
      .single()

    // Fetch organization
    const { data: org } = await supabase
      .from('organizations')
      .select('id, name, legal_name, registration_id, address, email, phone, payment_details')
      .eq('id', invoice.organization_id)
      .single()

    // Fetch lines
    const { data: lines } = await supabase
      .from('invoice_lines')
      .select('description, amount_cents')
      .eq('invoice_id', id)
      .order('line_number')

    // Format invoice number
    const invoiceNumber = invoice.number.match(/^[0-9]+$/)
      ? `INV-${new Date(invoice.invoice_date).getFullYear()}-${invoice.number.padStart(4, '0')}`
      : invoice.number

    // Generate PDF
    const pdfBuffer = await generateInvoicePDF({
      invoice: {
        number: invoiceNumber,
        invoice_date: invoice.invoice_date,
        due_date: invoice.due_date,
        total_cents: invoice.total_cents,
        received_cents: invoice.received_cents,
        notes: invoice.notes,
      },
      customer: {
        name: customer?.name || 'Customer',
        email: customer?.email || null,
        address: customer?.address || undefined,
      },
      lines: lines?.map(line => ({
        description: line.description,
        quantity: 1,
        amount_cents: line.amount_cents,
      })) || [],
      organization: {
        legal_name: org?.legal_name || org?.name || 'Organization',
        registration_id: org?.registration_id || undefined,
        address: org?.address || undefined,
        email: org?.email || undefined,
        phone: org?.phone || undefined,
        payment_details: org?.payment_details || undefined,
      },
    })

    const filename = getInvoicePDFFilename(invoiceNumber)

    return new NextResponse(new Uint8Array(pdfBuffer), {
      status: 200,
      headers: {
        'Content-Type': 'application/pdf',
        'Content-Disposition': `attachment; filename="${filename}"`,
      },
    })
  } catch (error: any) {
    console.error('PDF generation error:', error)
    return new NextResponse('Failed to generate PDF', { status: 500 })
  }
}
