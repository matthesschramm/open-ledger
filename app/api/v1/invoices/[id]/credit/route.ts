import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { issueCreditNote } from '@/lib/ledger'

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'post')
  if (permError) return errorResponse(permError, 403)

  const idempotencyKey = request.headers.get('idempotency-key')
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/credit`)
    if (cached) return cached
  }

  try {
    const body = await request.json()
    const { credit_date, amount_cents, reason } = body

    if (!credit_date || !amount_cents || !reason) {
      return errorResponse(
        { error: { code: 'validation_error', message: 'credit_date, amount_cents, and reason are required' } },
        400
      )
    }

    const result = await issueCreditNote(auth.organizationId, {
      invoice_id: id,
      credit_date,
      amount_cents,
      reason,
    }, auth.userId)
    
    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/credit`, 200, result)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/credit`, 200, undefined, idempotencyKey || undefined)
    return NextResponse.json(result)
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/credit`, 400, undefined, idempotencyKey || undefined)
    return errorResponse({ error: { code: 'credit_failed', message: error.message } }, 400)
  }
}
