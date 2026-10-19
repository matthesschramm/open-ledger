import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getInvoice } from '@/lib/ledger'
import { validateUUID } from '@/lib/validate-uuid'

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'read')
  if (permError) return errorResponse(permError, 403)

  // Validate UUID format
  const uuidValidation = validateUUID(id, 'invoice_id')
  if (!uuidValidation.valid) {
    await logAPIUsage(auth, 'GET', `/api/v1/invoices/${id}`, 400)
    return errorResponse({ error: uuidValidation.error }, 400)
  }

  try {
    const invoice = await getInvoice(auth.organizationId, id)
    await logAPIUsage(auth, 'GET', `/api/v1/invoices/${id}`, 200)
    return NextResponse.json(invoice)
  } catch (error: any) {
    const isNotFound = error.message === 'Invoice not found'
    const status = isNotFound ? 404 : 500
    const code = isNotFound ? 'not_found' : 'internal_error'
    const message = isNotFound ? error.message : 'Database error'
    await logAPIUsage(auth, 'GET', `/api/v1/invoices/${id}`, status)
    return errorResponse({ error: { code, message } }, status)
  }
}
