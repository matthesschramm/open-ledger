import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { listSupplierCredits } from '@/lib/ledger'

export async function GET(request: NextRequest) {
  const auth = await validateAPIKey(request.headers.get('authorization'))
  if ('error' in auth) return errorResponse(auth, 401)

  try {
    const { searchParams } = new URL(request.url)
    const contact_id = searchParams.get('contact_id') || undefined
    const status = searchParams.get('status') || undefined

    const credits = await listSupplierCredits(auth.organizationId, {
      contact_id,
      status,
    })

    await logAPIUsage(auth, 'GET', '/api/v1/supplier-credits', 200)
    return NextResponse.json({ credits })
  } catch (error: any) {
    await logAPIUsage(auth, 'GET', '/api/v1/supplier-credits', 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error.message,
      },
    }, 500)
  }
}
