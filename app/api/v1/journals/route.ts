import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage, checkIdempotency, storeIdempotency } from '@/lib/api-auth'
import { listJournals, draftJournal } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  try {
    const authHeader = request.headers.get('authorization')
    const auth = await validateAPIKey(authHeader)

    if ('error' in auth) {
      return errorResponse(auth, 401)
    }

    const permError = checkPermission(auth, 'read')
    if (permError) {
      await logAPIUsage(auth, 'GET', '/api/v1/journals', 403)
      return errorResponse(permError, 403)
    }

    try {
      const { searchParams } = new URL(request.url)
      const status = searchParams.get('status') || undefined
      const limit = searchParams.get('limit') ? parseInt(searchParams.get('limit')!) : undefined
      const offset = searchParams.get('offset') ? parseInt(searchParams.get('offset')!) : undefined

      const journals = await listJournals(auth.organizationId, { status, limit, offset })

      await logAPIUsage(auth, 'GET', '/api/v1/journals', 200)

      return NextResponse.json({ journals })
    } catch (error: any) {
      console.error('List journals error:', error)
      await logAPIUsage(auth, 'GET', '/api/v1/journals', 500)
      return errorResponse({
        error: {
          code: 'internal_error',
          message: error?.message || 'Failed to list journals',
        },
      }, 500)
    }
  } catch (error: any) {
    console.error('Top-level journals GET route error:', error)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'An error occurred processing your request',
      },
    }, 500)
  }
}

export async function POST(request: NextRequest) {
  try {
    const authHeader = request.headers.get('authorization')
    const auth = await validateAPIKey(authHeader)

    if ('error' in auth) {
      return errorResponse(auth, 401)
    }

    const permError = checkPermission(auth, 'write')
    if (permError) {
      await logAPIUsage(auth, 'POST', '/api/v1/journals', 403)
      return errorResponse(permError, 403)
    }

    try {
      const idempotencyKey = request.headers.get('idempotency-key')
      if (idempotencyKey) {
        const cachedResponse = await checkIdempotency(auth, idempotencyKey, 'POST', '/api/v1/journals')
        if (cachedResponse) {
          return cachedResponse
        }
      }

      const body = await request.json()

      // Validate required fields (number is now optional and ignored for drafts)
      if (!body.entry_date || !body.description || !body.lines) {
        return errorResponse({
          error: {
            code: 'invalid_request',
            message: 'Missing required fields: entry_date, description, lines',
          },
        }, 400)
      }

      const result = await draftJournal(
        auth.organizationId,
        {
          entry_date: body.entry_date,
          description: body.description,
          lines: body.lines.map((line: any) => ({
            account_id: line.account_id,
            debit_cents: line.debit_cents || 0,
            credit_cents: line.credit_cents || 0,
            memo: line.memo,
          })),
        },
        auth.keyId // Use API key ID as creator
      )

      const responseBody = { journal_id: result.journal_id }

      if (idempotencyKey) {
        await storeIdempotency(auth, idempotencyKey, 'POST', '/api/v1/journals', 201, responseBody)
      }

      await logAPIUsage(auth, 'POST', '/api/v1/journals', 201, undefined, idempotencyKey || undefined)

      return NextResponse.json(responseBody, { status: 201 })
    } catch (error: any) {
      console.error('Draft journal error:', error)
      await logAPIUsage(auth, 'POST', '/api/v1/journals', 500)
      return errorResponse({
        error: {
          code: 'internal_error',
          message: error?.message || 'Failed to create journal',
        },
      }, 500)
    }
  } catch (error: any) {
    console.error('Top-level journals POST route error:', error)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'An error occurred processing your request',
      },
    }, 500)
  }
}
