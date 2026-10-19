import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { listContacts, createContact } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/contacts', 403)
    return errorResponse(permError, 403)
  }

  try {
    const { searchParams } = new URL(request.url)
    const type = searchParams.get('type') || undefined
    const isActiveParam = searchParams.get('is_active')
    const is_active = isActiveParam ? isActiveParam === 'true' : undefined

    const contacts = await listContacts(auth.organizationId, { type, is_active })

    await logAPIUsage(auth, 'GET', '/api/v1/contacts', 200)

    return NextResponse.json({ contacts })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/contacts', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
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
    await logAPIUsage(auth, 'POST', '/api/v1/contacts', 403)
    return errorResponse(permError, 403)
  }

  try {
    const idempotencyKey = request.headers.get('idempotency-key')
    if (idempotencyKey) {
      const cachedResponse = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/contacts')
      if (cachedResponse) {
        return cachedResponse
      }
    }

    const body = await request.json()

    if (!body.type || !body.name) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'Missing required fields: type, name',
        },
      }, 400)
    }

    const result = await createContact(auth.organizationId, {
      type: body.type,
      name: body.name,
      email: body.email,
      phone: body.phone,
      address: body.address,
      notes: body.notes,
    })

    const responseBody = result

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/contacts', 201, responseBody)
    }

    await logAPIUsage(auth, 'POST', '/api/v1/contacts', 201, undefined, idempotencyKey || undefined)

    return NextResponse.json(responseBody, { status: 201 })
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', '/api/v1/contacts', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}
