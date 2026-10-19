import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getTrialBalance } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  try {
    const authHeader = request.headers.get('authorization')
    const auth = await validateAPIKey(authHeader)

    if ('error' in auth) {
      return errorResponse(auth, 401)
    }

    const permError = checkPermission(auth, 'read')
    if (permError) {
      await logAPIUsage(auth, 'GET', '/api/v1/reports/trial-balance', 403)
      return errorResponse(permError, 403)
    }

    try {
      const { searchParams } = new URL(request.url)
      const asOfDate = searchParams.get('as_of_date') || new Date().toISOString().split('T')[0]

      const report = await getTrialBalance(auth.organizationId, asOfDate)

      await logAPIUsage(auth, 'GET', '/api/v1/reports/trial-balance', 200)

      return NextResponse.json({ report })
    } catch (error: any) {
      console.error('Trial balance error:', error)
      await logAPIUsage(auth, 'GET', '/api/v1/reports/trial-balance', 500)
      return errorResponse({
        error: {
          code: 'internal_error',
          message: error?.message || 'Failed to generate trial balance report',
        },
      }, 500)
    }
  } catch (error: any) {
    console.error('Top-level trial balance route error:', error)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'An error occurred processing your request',
      },
    }, 500)
  }
}
