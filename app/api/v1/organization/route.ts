import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getOrganization, updateCapitalizationThreshold } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/organization', 403)
    return errorResponse(permError, 403)
  }

  try {
    const organization = await getOrganization(auth.organizationId)

    await logAPIUsage(auth, 'GET', '/api/v1/organization', 200)

    return NextResponse.json({ organization })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/organization', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}

export async function PATCH(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'write')
  if (permError) {
    await logAPIUsage(auth, 'PATCH', '/api/v1/organization', 403)
    return errorResponse(permError, 403)
  }

  try {
    const body = await request.json()
    if (body.capitalization_threshold_cents === undefined) {
      return errorResponse({
        error: {
          code: 'validation_error',
          message: 'capitalization_threshold_cents is required',
        },
      }, 400)
    }

    await updateCapitalizationThreshold(auth.organizationId, body.capitalization_threshold_cents)
    const organization = await getOrganization(auth.organizationId)
    await logAPIUsage(auth, 'PATCH', '/api/v1/organization', 200)
    return NextResponse.json({ organization })
  } catch (error: unknown) {
    await logAPIUsage(auth, 'PATCH', '/api/v1/organization', 400)
    const message = error instanceof Error ? error.message : 'Failed to update organization'
    return errorResponse({ error: { code: 'update_failed', message } }, 400)
  }
}
