import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getAccount, deleteAccount } from '@/lib/ledger'
import { validateUUID } from '@/lib/validate-uuid'

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', `/api/v1/accounts/${id}`, 403)
    return errorResponse(permError, 403)
  }

  // Validate UUID format
  const uuidValidation = validateUUID(id, 'account_id')
  if (!uuidValidation.valid) {
    await logAPIUsage(auth, 'GET', `/api/v1/accounts/${id}`, 400)
    return errorResponse({ error: uuidValidation.error }, 400)
  }

  try {
    const account = await getAccount(auth.organizationId, id)

    await logAPIUsage(auth, 'GET', `/api/v1/accounts/${id}`, 200)

    return NextResponse.json({ account })
  } catch (error: any) {
    const isNotFound = error.message === 'Account not found'
    const status = isNotFound ? 404 : 500
    const code = isNotFound ? 'not_found' : 'internal_error'
    const message = isNotFound ? error.message : 'Database error'
    
    await logAPIUsage(auth, 'GET', `/api/v1/accounts/${id}`, status)
    return errorResponse({
      error: {
        code,
        message,
      },
    }, status)
  }
}

export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'write')
  if (permError) {
    await logAPIUsage(auth, 'DELETE', `/api/v1/accounts/${id}`, 403)
    return errorResponse(permError, 403)
  }

  // Validate UUID format
  const uuidValidation = validateUUID(id, 'account_id')
  if (!uuidValidation.valid) {
    await logAPIUsage(auth, 'DELETE', `/api/v1/accounts/${id}`, 400)
    return errorResponse({ error: uuidValidation.error }, 400)
  }

  try {
    const result = await deleteAccount(auth.organizationId, id)
    await logAPIUsage(auth, 'DELETE', `/api/v1/accounts/${id}`, 200)
    return NextResponse.json(result)
  } catch (error: any) {
    await logAPIUsage(auth, 'DELETE', `/api/v1/accounts/${id}`, 400)
    return errorResponse({
      error: {
        code: 'delete_failed',
        message: error.message,
      },
    }, 400)
  }
}
