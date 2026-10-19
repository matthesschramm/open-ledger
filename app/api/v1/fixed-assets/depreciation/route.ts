import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { runDepreciation } from '@/lib/ledger'

export async function POST(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'post')
  if (permError) {
    await logAPIUsage(auth, 'POST', '/api/v1/fixed-assets/depreciation', 403)
    return errorResponse(permError, 403)
  }

  const idempotencyKey = request.headers.get('idempotency-key')
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/fixed-assets/depreciation')
    if (cached) return cached
  }

  try {
    const body = await request.json()
    if (!body.period_start) {
      return errorResponse({
        error: { code: 'validation_error', message: 'period_start is required (YYYY-MM-DD)' },
      }, 400)
    }

    const result = await runDepreciation(auth.organizationId, body.period_start, auth.userId)

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/fixed-assets/depreciation', 200, result)
    }
    await logAPIUsage(auth, 'POST', '/api/v1/fixed-assets/depreciation', 200, undefined, idempotencyKey || undefined)
    return NextResponse.json(result)
  } catch (error: unknown) {
    await logAPIUsage(auth, 'POST', '/api/v1/fixed-assets/depreciation', 400, undefined, idempotencyKey || undefined)
    const message = error instanceof Error ? error.message : 'Failed to run depreciation'
    return errorResponse({ error: { code: 'depreciation_failed', message } }, 400)
  }
}
