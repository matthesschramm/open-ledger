import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getBalanceSheet } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/balance-sheet', 403)
    return errorResponse(permError, 403)
  }

  try {
    const { searchParams } = new URL(request.url)
    const asOfDate = searchParams.get('as_of_date') || new Date().toISOString().split('T')[0]

    const report = await getBalanceSheet(auth.organizationId, asOfDate)

    await logAPIUsage(auth, 'GET', '/api/v1/reports/balance-sheet', 200)

    return NextResponse.json({ report })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/balance-sheet', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}
