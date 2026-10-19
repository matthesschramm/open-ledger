import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getFixedAsset } from '@/lib/ledger'
import { validateUUID } from '@/lib/validate-uuid'

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', `/api/v1/fixed-assets/${id}`, 403)
    return errorResponse(permError, 403)
  }

  // Validate UUID format
  const uuidValidation = validateUUID(id, 'fixed_asset_id')
  if (!uuidValidation.valid) {
    await logAPIUsage(auth, 'GET', `/api/v1/fixed-assets/${id}`, 400)
    return errorResponse({ error: uuidValidation.error }, 400)
  }

  try {
    const asset = await getFixedAsset(auth.organizationId, id)
    await logAPIUsage(auth, 'GET', `/api/v1/fixed-assets/${id}`, 200)
    return NextResponse.json({ asset })
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : 'Fixed asset not found'
    const isNotFound = message === 'Fixed asset not found'
    const status = isNotFound ? 404 : 500
    const code = isNotFound ? 'not_found' : 'internal_error'
    const responseMessage = isNotFound ? message : 'Database error'
    await logAPIUsage(auth, 'GET', `/api/v1/fixed-assets/${id}`, status)
    return errorResponse({
      error: { code, message: responseMessage },
    }, status)
  }
}
