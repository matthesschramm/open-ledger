import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getAccountLedger } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/account-ledger', 403)
    return errorResponse(permError, 403)
  }

  try {
    const { searchParams } = new URL(request.url)
    const accountId = searchParams.get('account_id')

    if (!accountId) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'Missing required parameter: account_id',
        },
      }, 400)
    }

    // Validate account_id is a UUID
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    if (!uuidRegex.test(accountId)) {
      return errorResponse({
        error: {
          code: 'invalid_account_id',
          message: 'account_id must be a UUID, like 3f6c1e2a-b4c7-4d8e-9f1a-2b3c4d5e6f7a',
        },
      }, 400)
    }

    const startDate = searchParams.get('start_date') || undefined
    const endDate = searchParams.get('end_date') || undefined

    const report = await getAccountLedger(auth.organizationId, accountId, startDate, endDate)

    await logAPIUsage(auth, 'GET', '/api/v1/reports/account-ledger', 200)

    return NextResponse.json({ report })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/reports/account-ledger', error.code === 'ACCOUNT_NOT_FOUND' ? 404 : 500)
    
    if (error.code === 'ACCOUNT_NOT_FOUND') {
      return errorResponse({
        error: {
          code: 'account_not_found',
          message: 'Account not found.',
        },
      }, 404)
    }
    
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}
