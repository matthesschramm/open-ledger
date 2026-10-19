import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getCashMovement } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/cash-movement', 403)
    return errorResponse(permError, 403)
  }

  try {
    const { searchParams } = new URL(request.url)
    const startDate = searchParams.get('start_date')
    const endDate = searchParams.get('end_date')

    if (!startDate || !endDate) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'Missing required parameters: start_date, end_date',
        },
      }, 400)
    }

    const report = await getCashMovement(auth.organizationId, startDate, endDate)

    await logAPIUsage(auth, 'GET', '/api/v1/reports/cash-movement', 200)

    return NextResponse.json({ report })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/cash-movement', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}
