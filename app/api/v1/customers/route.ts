import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { listContacts, createContact } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'read')
  if (permError) return errorResponse(permError, 403)

  try {
    const searchParams = request.nextUrl.searchParams
    const type = searchParams.get('type') || undefined

    const customers = await listContacts(auth.organizationId, {
      type: type === 'Customer' ? 'Customer' : 'Customer',
      is_active: true,
    })

    await logAPIUsage(auth, 'GET', '/api/v1/customers', 200)
    return NextResponse.json({ customers })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/customers', 500)
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
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/customers')
    if (cached) return cached
  }

  try {
    const body = await request.json()
    const { name, email, phone, address, notes } = body

    if (!name) {
      return errorResponse({ error: { code: 'validation_error', message: 'name is required' } }, 400)
    }

    const result = await createContact(auth.organizationId, {
      type: 'Customer',
      name,
      email,
      phone,
      address,
      notes,
    })

    const response = { customer_id: result.contact_id }
    
    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/customers', 201, response)
    }

    await logAPIUsage(auth, 'POST', '/api/v1/customers', 201, undefined, idempotencyKey || undefined)
    return NextResponse.json(response, { status: 201 })
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', '/api/v1/customers', 500, undefined, idempotencyKey || undefined)
    return errorResponse({ error: { code: 'internal_error', message: error.message } }, 500)
  }
}
