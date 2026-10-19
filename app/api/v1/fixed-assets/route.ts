import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { listFixedAssets, registerFixedAsset } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/fixed-assets', 403)
    return errorResponse(permError, 403)
  }

  try {
    const searchParams = request.nextUrl.searchParams
    const assets = await listFixedAssets(auth.organizationId, {
      status: searchParams.get('status') || undefined,
      class: searchParams.get('class') || undefined,
    })
    await logAPIUsage(auth, 'GET', '/api/v1/fixed-assets', 200)
    return NextResponse.json({ assets })
  } catch (error: unknown) {
    await logAPIUsage(auth, 'GET', '/api/v1/fixed-assets', 500)
    const message = error instanceof Error ? error.message : 'Failed to list fixed assets'
    return errorResponse({ error: { code: 'internal_error', message } }, 500)
  }
}

export async function POST(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'post')
  if (permError) {
    await logAPIUsage(auth, 'POST', '/api/v1/fixed-assets', 403)
    return errorResponse(permError, 403)
  }

  const idempotencyKey = request.headers.get('idempotency-key')
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/fixed-assets')
    if (cached) return cached
  }

  try {
    const body = await request.json()
    if (!body.description || !body.class || !body.cost_cents || !body.useful_life_months || !body.acquisition_date || !body.in_service_date) {
      return errorResponse({
        error: {
          code: 'validation_error',
          message: 'description, class, cost_cents, useful_life_months, acquisition_date, and in_service_date are required',
        },
      }, 400)
    }

    const result = await registerFixedAsset(auth.organizationId, body, auth.userId)

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/fixed-assets', 201, result)
    }
    await logAPIUsage(auth, 'POST', '/api/v1/fixed-assets', 201, undefined, idempotencyKey || undefined)
    return NextResponse.json(result, { status: 201 })
  } catch (error: unknown) {
    await logAPIUsage(auth, 'POST', '/api/v1/fixed-assets', 400, undefined, idempotencyKey || undefined)
    const message = error instanceof Error ? error.message : 'Failed to register fixed asset'
    return errorResponse({ error: { code: 'register_failed', message } }, 400)
  }
}
