import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { recordReceipt } from '@/lib/ledger'

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
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/receipt`)
    if (cached) return cached
  }

  try {
    const body = await request.json()
    const { receipt_date, amount_cents, cash_account_id, notes } = body

    if (!receipt_date || !amount_cents || !cash_account_id) {
      return errorResponse(
        { error: { code: 'validation_error', message: 'receipt_date, amount_cents, and cash_account_id are required' } },
        400
      )
    }

    const result = await recordReceipt(auth.organizationId, {
      invoice_id: id,
      receipt_date,
      amount_cents,
      cash_account_id,
      notes,
    }, auth.userId)
    
    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/receipt`, 200, result)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/receipt`, 200, undefined, idempotencyKey || undefined)
    return NextResponse.json(result)
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/receipt`, 400, undefined, idempotencyKey || undefined)
    return errorResponse({ error: { code: 'receipt_failed', message: error.message } }, 400)
  }
}
