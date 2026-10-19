import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { postJournal } from '@/lib/ledger'

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
    await logAPIUsage(auth, 'POST', `/api/v1/journals/${id}/post`, 403)
    return errorResponse(permError, 403)
  }

  try {
    const idempotencyKey = request.headers.get('idempotency-key')
    if (idempotencyKey) {
      const cachedResponse = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/journals/${id}/post`)
      if (cachedResponse) {
        return cachedResponse
      }
    }

    const result = await postJournal(auth.organizationId, id, auth.userId)

    const responseBody = result

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/journals/${id}/post`, 200, responseBody)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/journals/${id}/post`, 200, undefined, idempotencyKey || undefined)

    return NextResponse.json(responseBody)
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', `/api/v1/journals/${id}/post`, 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}
