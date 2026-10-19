import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { listAccounts, createAccount } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  try {
    const authHeader = request.headers.get('authorization')
    const auth = await validateAPIKey(authHeader)

    if ('error' in auth) {
      return errorResponse(auth, 401)
    }

    const permError = checkPermission(auth, 'read')
    if (permError) {
      await logAPIUsage(auth, 'GET', '/api/v1/accounts', 403)
      return errorResponse(permError, 403)
    }

    try {
      const { searchParams } = new URL(request.url)
      const type = searchParams.get('type') || undefined
      const isActiveParam = searchParams.get('is_active')
      const is_active = isActiveParam ? isActiveParam === 'true' : undefined

      const accounts = await listAccounts(auth.organizationId, { type, is_active })

      await logAPIUsage(auth, 'GET', '/api/v1/accounts', 200)

      return NextResponse.json({ accounts })
    } catch (error: any) {
      console.error('List accounts error:', error)
      await logAPIUsage(auth, 'GET', '/api/v1/accounts', 500)
      return errorResponse({
        error: {
          code: 'internal_error',
          message: error?.message || 'Failed to list accounts',
        },
      }, 500)
    }
  } catch (error: any) {
    console.error('Top-level accounts route error:', error)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'An error occurred processing your request',
      },
    }, 500)
  }
}

export async function POST(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'write')
  if (permError) {
    await logAPIUsage(auth, 'POST', '/api/v1/accounts', 403)
    return errorResponse(permError, 403)
  }

  const idempotencyKey = request.headers.get('idempotency-key')
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/accounts')
    if (cached) return cached
  }

  try {
    const body = await request.json()
    if (!body.code || !body.name || !body.type) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'Missing required fields: code, name, type',
        },
      }, 400)
    }

    const result = await createAccount(auth.organizationId, {
      code: body.code,
      name: body.name,
      type: body.type,
      category: body.category,
      is_cash: body.is_cash,
      parent_id: body.parent_id,
    })

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/accounts', 201, result)
    }

    await logAPIUsage(auth, 'POST', '/api/v1/accounts', 201, undefined, idempotencyKey || undefined)
    return NextResponse.json(result, { status: 201 })
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', '/api/v1/accounts', 400, undefined, idempotencyKey || undefined)
    return errorResponse({
      error: {
        code: 'create_failed',
        message: error.message,
      },
    }, 400)
  }
}
