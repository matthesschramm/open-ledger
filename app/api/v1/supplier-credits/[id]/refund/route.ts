import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { refundSupplierCredit } from '@/lib/ledger'

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
  
  // Validate idempotency-key is a valid UUID if provided
  if (idempotencyKey) {
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    if (!uuidRegex.test(idempotencyKey)) {
      return errorResponse(
        { error: { code: 'invalid_idempotency_key', message: 'Idempotency-Key must be a UUID, like 3f6c1e2a-b4c7-4d8e-9f1a-2b3c4d5e6f7a' } },
        400
      )
    }
    
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/supplier-credits/${id}/refund`)
    if (cached) return cached
  }

  try {
    const body = await request.json()
    const { amount_cents, cash_account_id, refund_date, idempotency_key } = body

    if (!amount_cents) {
      return errorResponse(
        { error: { code: 'validation_error', message: 'amount_cents is required' } },
        400
      )
    }

    const result = await refundSupplierCredit(auth.organizationId, {
      credit_id: id,
      amount_cents,
      cash_account_id: cash_account_id || undefined,
      refund_date: refund_date || undefined,
      idempotency_key: idempotency_key || undefined,
    }, auth.userId)
    
    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/supplier-credits/${id}/refund`, 200, result)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/supplier-credits/${id}/refund`, 200, undefined, idempotencyKey || undefined)
    return NextResponse.json(result)
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', `/api/v1/supplier-credits/${id}/refund`, error.code === 'INSUFFICIENT_PERMISSIONS' ? 403 : 400, undefined, idempotencyKey || undefined)
    
    // Map error codes to friendly messages
    if (error.code === 'PERIOD_LOCKED') {
      return errorResponse({
        error: {
          code: 'period_locked',
          message: 'This date is in a locked accounting period. Choose a date that is not locked.',
        },
      }, 400)
    }
    
    if (error.code === 'INSUFFICIENT_PERMISSIONS') {
      return errorResponse({
        error: {
          code: 'insufficient_permissions',
          message: 'You don\'t have permission to refund this credit.',
        },
      }, 403)
    }
    
    return errorResponse({ error: { code: 'refund_failed', message: error.message } }, 400)
  }
}
