import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getPpeRollforward } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/ppe-rollforward', 403)
    return errorResponse(permError, 403)
  }

  try {
    const startDate = request.nextUrl.searchParams.get('start_date')
    const endDate = request.nextUrl.searchParams.get('end_date')
    if (!startDate || !endDate) {
      return errorResponse({
        error: { code: 'invalid_request', message: 'start_date and end_date are required' },
      }, 400)
    }

    const report = await getPpeRollforward(auth.organizationId, startDate, endDate)
    await logAPIUsage(auth, 'GET', '/api/v1/reports/ppe-rollforward', 200)
    return NextResponse.json({ report })
  } catch (error: unknown) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/ppe-rollforward', 500)
    const message = error instanceof Error ? error.message : 'Failed to load PPE rollforward'
    return errorResponse({ error: { code: 'internal_error', message } }, 500)
  }
}
