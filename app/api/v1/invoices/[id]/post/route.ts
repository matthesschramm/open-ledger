import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { postInvoice } from '@/lib/ledger'

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
  if (idempotencyKey) {
    const cached = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/post`)
    if (cached) return cached
  }

  try {
    const result = await postInvoice(auth.organizationId, id, auth.userId)
    
    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/invoices/${id}/post`, 200, result)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/post`, 200, undefined, idempotencyKey || undefined)
    return NextResponse.json(result)
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', `/api/v1/invoices/${id}/post`, 400, undefined, idempotencyKey || undefined)
    return errorResponse({ error: { code: 'post_failed', message: error.message } }, 400)
  }
}
