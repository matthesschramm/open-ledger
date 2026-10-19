import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { listBills, draftBill, postBill } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', '/api/v1/bills', 403)
    return errorResponse(permError, 403)
  }

  try {
    const { searchParams } = new URL(request.url)
    const status = searchParams.get('status') || undefined
    const vendor_id = searchParams.get('vendor_id') || undefined

    const bills = await listBills(auth.organizationId, { status, vendor_id })

    await logAPIUsage(auth, 'GET', '/api/v1/bills', 200)

    return NextResponse.json({ bills })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/bills', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}

export async function POST(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'write')
  if (permError) {
    await logAPIUsage(auth, 'POST', '/api/v1/bills', 403)
    return errorResponse(permError, 403)
  }

  try {
    const idempotencyKey = request.headers.get('idempotency-key')
    if (idempotencyKey) {
      const cachedResponse = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/bills')
      if (cachedResponse) {
        return cachedResponse
      }
    }

    const body = await request.json()

    if (!body.vendor_id || !body.number || !body.bill_date || !body.lines) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'Missing required fields: vendor_id, number, bill_date, lines',
        },
      }, 400)
    }

    const result = await draftBill(
      auth.organizationId,
      {
        vendor_id: body.vendor_id,
        number: body.number,
        bill_date: body.bill_date,
        due_date: body.due_date,
        lines: body.lines.map((line: any) => ({
          account_id: line.account_id,
          amount_cents: line.amount_cents,
          description: line.description,
        })),
        notes: body.notes,
      },
      auth.keyId
    )

    const responseBody = result

    if (idempotencyKey) {
      await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/bills', 201, responseBody)
    }

    await logAPIUsage(auth, 'POST', '/api/v1/bills', 201, undefined, idempotencyKey || undefined)

    return NextResponse.json(responseBody, { status: 201 })
  } catch (error: any) {
    await logAPIUsage(auth, 'POST', '/api/v1/bills', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}
