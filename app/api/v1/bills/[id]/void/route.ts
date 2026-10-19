import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { voidBill } from '@/lib/ledger'

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
    await logAPIUsage(auth, 'POST', `/api/v1/bills/${id}/void`, 403)
    return errorResponse(permError, 403)
  }

  try {
    const idempotencyKey = request.headers.get('idempotency-key')
    if (idempotencyKey) {
      const cachedResponse = await checkIdempotency(auth, idempotencyKey, 'POST', `/api/v1/bills/${id}/void`)
      if (cachedResponse) {
        return cachedResponse
      }
    }

    const body = await request.json().catch(() => ({}))
    const voidDate = body.void_date || null

    // Validate void_date format if provided
    if (voidDate && !/^\d{4}-\d{2}-\d{2}$/.test(voidDate)) {
      return errorResponse({
        error: {
          code: 'invalid_parameter',
          message: 'void_date must be in yyyy-mm-dd format',
        },
      }, 400)
    }

    const result = await voidBill(auth.organizationId, id, auth.userId, voidDate)

    const responseBody = result

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', `/api/v1/bills/${id}/void`, 200, responseBody)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/bills/${id}/void`, 200, undefined, idempotencyKey || undefined)

    return NextResponse.json(responseBody)
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', `/api/v1/bills/${id}/void`, error.code === 'INSUFFICIENT_PERMISSIONS' ? 403 : 400)
    
    // Map error codes to friendly messages
    if (error.code === 'PERIOD_LOCKED') {
      // Extract lock date from error message and format as "Mon D, YYYY"
      const lockDateMatch = error.message?.match(/after (\d{4}-\d{2}-\d{2})/)
      let lockDateFormatted = 'the lock date'
      if (lockDateMatch) {
        try {
          const [year, month, day] = lockDateMatch[1].split('-').map(Number)
          const date = new Date(Date.UTC(year, month - 1, day))
          lockDateFormatted = new Intl.DateTimeFormat('en-US', { 
            month: 'short',
            day: 'numeric',
            year: 'numeric',
            timeZone: 'UTC'
          }).format(date)
        } catch {
          lockDateFormatted = lockDateMatch[1]
        }
      }
      return errorResponse({
        error: {
          code: 'period_locked',
          message: `This date is in a locked period. Choose a date after ${lockDateFormatted}.`,
        },
      }, 400)
    }
    
    if (error.code === 'INSUFFICIENT_PERMISSIONS') {
      return errorResponse({
        error: {
          code: 'insufficient_permissions',
          message: 'You don\'t have permission to void this bill.',
        },
      }, 403)
    }
    
    return errorResponse({
      error: {
        code: 'void_failed',
        message: error.message,
      },
    }, 400)
  }
}
