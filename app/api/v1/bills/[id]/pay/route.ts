import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { payBill } from '@/lib/ledger'

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'post')
  if (permError) {
    await logAPIUsage(auth, 'POST', `/api/v1/bills/${id}/pay`, 403)
    return errorResponse(permError, 403)
  }

  const idempotencyKey = request.headers.get('idempotency-key')
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/bills/${id}/pay`)
    if (cached) return cached
  }

  try {
    const body = await request.json()
    const { payment_date, amount_cents, cash_account_id, notes } = body

    if (!payment_date || !amount_cents || !cash_account_id) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'payment_date, amount_cents, and cash_account_id are required',
        },
      }, 400)
    }

    const result = await payBill(
      auth.organizationId,
      {
        bill_id: id,
        payment_date,
        amount_cents,
        cash_account_id,
        notes,
      },
      auth.userId
    )

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/bills/${id}/pay`, 200, result)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/bills/${id}/pay`, 200, undefined, idempotencyKey || undefined)
    return NextResponse.json(result)
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', `/api/v1/bills/${id}/pay`, 400, undefined, idempotencyKey || undefined)
    return errorResponse({
      error: {
        code: 'pay_failed',
        message: error.message,
      },
    }, 400)
  }
}
