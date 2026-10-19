import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { disposeFixedAsset } from '@/lib/ledger'

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'post')
  if (permError) {
    await logAPIUsage(auth, 'POST', `/api/v1/fixed-assets/${id}/dispose`, 403)
    return errorResponse(permError, 403)
  }

  const idempotencyKey = request.headers.get('idempotency-key')
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/fixed-assets/${id}/dispose`)
    if (cached) return cached
  }

  try {
    const body = await request.json()
    if (!body.disposal_date) {
      return errorResponse({
        error: { code: 'validation_error', message: 'disposal_date is required' },
      }, 400)
    }

    const result = await disposeFixedAsset(auth.organizationId, {
      asset_id: id,
      disposal_date: body.disposal_date,
      proceeds_cents: body.proceeds_cents,
      cash_account_id: body.cash_account_id,
    }, auth.userId)

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/fixed-assets/${id}/dispose`, 200, result)
    }
    await logAPIUsage(auth, 'POST', `/api/v1/fixed-assets/${id}/dispose`, 200, undefined, idempotencyKey || undefined)
    return NextResponse.json(result)
  } catch (error: unknown) {
    await logAPIUsage(auth, 'POST', `/api/v1/fixed-assets/${id}/dispose`, 400, undefined, idempotencyKey || undefined)
    const message = error instanceof Error ? error.message : 'Failed to dispose fixed asset'
    return errorResponse({ error: { code: 'dispose_failed', message } }, 400)
  }
}
