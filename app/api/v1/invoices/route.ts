import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { listInvoices, draftInvoice } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'read')
  if (permError) return errorResponse(permError, 403)

  try {
    const searchParams = request.nextUrl.searchParams
    const status = searchParams.get('status') || undefined
    const customer_id = searchParams.get('customer_id') || undefined

    const invoices = await listInvoices(auth.organizationId, {
      status,
      customer_id,
    })

    await logAPIUsage(auth, 'GET', '/api/v1/invoices', 200)
    return NextResponse.json({ invoices })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/invoices', 500)
    return errorResponse({ error: { code: 'internal_error', message: error.message } }, 500)
  }
}

export async function POST(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'write')
  if (permError) return errorResponse(permError, 403)

  const idempotencyKey = request.headers.get('idempotency-key')
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/invoices')
    if (cached) return cached
  }

  try {
    const body = await request.json()
    const { customer_id, number, invoice_date, due_date, status, lines, notes } = body

    if (!customer_id || !number || !invoice_date || !lines || lines.length === 0) {
      return errorResponse(
        { error: { code: 'validation_error', message: 'customer_id, number, invoice_date, and lines are required' } },
        400
      )
    }

    // Validate status if provided
    if (status && status !== 'Draft' && status !== 'Quote') {
      return errorResponse(
        { error: { code: 'validation_error', message: 'status must be Draft or Quote' } },
        400
      )
    }

    const result = await draftInvoice(
      auth.organizationId,
      {
        customer_id,
        number,
        invoice_date,
        due_date,
        status: status || 'Draft',
        lines,
        notes,
      },
      auth.keyId
    )

    const response = { invoice_id: result.invoice_id }
    
    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/invoices', 201, response)
    }

    await logAPIUsage(auth, 'POST', '/api/v1/invoices', 201, undefined, idempotencyKey || undefined)
    return NextResponse.json(response, { status: 201 })
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', '/api/v1/invoices', 500, undefined, idempotencyKey || undefined)
    return errorResponse({ error: { code: 'internal_error', message: error.message } }, 500)
  }
}
