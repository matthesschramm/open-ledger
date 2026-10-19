import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { getJournal, deleteJournal } from '@/lib/ledger'
import { validateUUID } from '@/lib/validate-uuid'
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

async function createBrowserClient() {
  const cookieStore = await cookies()
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY) {
    throw new Error('Missing required Supabase environment variables')
  }
  
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) => {
            cookieStore.set(name, value, options)
          })
        },
      },
    }
  )
}

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', `/api/v1/journals/${id}`, 403)
    return errorResponse(permError, 403)
  }

  // Validate UUID format
  const uuidValidation = validateUUID(id, 'journal_id')
  if (!uuidValidation.valid) {
    await logAPIUsage(auth, 'GET', `/api/v1/journals/${id}`, 400)
    return errorResponse({ error: uuidValidation.error }, 400)
  }

  try {
    const journal = await getJournal(auth.organizationId, id)

    await logAPIUsage(auth, 'GET', `/api/v1/journals/${id}`, 200)

    return NextResponse.json({ journal })
  } catch (error: any) {
    const isNotFound = error.message === 'Journal not found'
    const status = isNotFound ? 404 : 500
    const code = isNotFound ? 'not_found' : 'internal_error'
    const message = isNotFound ? error.message : 'Database error'
    
    await logAPIUsage(auth, 'GET', `/api/v1/journals/${id}`, status)
    return errorResponse({
      error: {
        code,
        message,
      },
    }, status)
  }
}

export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  
  // Try API key auth first
  const authHeader = request.headers.get('authorization')
  let auth: any
  let organizationId: string
  let userId: string
  let isAPIKeyAuth = false
  
  if (authHeader) {
    // API key authentication
    auth = await validateAPIKey(authHeader)
    if ('error' in auth) return errorResponse(auth, 401)

    const permError = checkPermission(auth, 'write')
    if (permError) {
      await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${id}`, 403)
      return errorResponse(permError, 403)
    }
    
    // Validate UUID format
    const uuidValidation = validateUUID(id, 'journal_id')
    if (!uuidValidation.valid) {
      await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${id}`, 400)
      return errorResponse({ error: uuidValidation.error }, 400)
    }
    
    organizationId = auth.organizationId
    userId = auth.userId
    isAPIKeyAuth = true
  } else {
    // Session cookie authentication
    const supabase = await createBrowserClient()
    const { data: { user } } = await supabase.auth.getUser()
    
    if (!user) {
      return NextResponse.json(
        { error: { code: 'unauthorized', message: 'Authentication required' } },
        { status: 401 }
      )
    }
    
    // Validate UUID format
    const uuidValidation = validateUUID(id, 'journal_id')
    if (!uuidValidation.valid) {
      return NextResponse.json(
        { error: uuidValidation.error },
        { status: 400 }
      )
    }
    
    // Get organization from session
    const { data: orgData } = await supabase.rpc('current_org_id')
    if (!orgData) {
      return NextResponse.json(
        { error: { code: 'no_organization', message: 'No organization found' } },
        { status: 403 }
      )
    }
    
    // Check role
    const { data: roleData } = await supabase.rpc('current_role')
    if (!roleData || !['owner', 'bookkeeper'].includes(roleData)) {
      return NextResponse.json(
        { error: { code: 'insufficient_permissions', message: 'Insufficient permissions' } },
        { status: 403 }
      )
    }
    
    organizationId = orgData
    userId = user.id
    isAPIKeyAuth = false
  }

  try {
    const result = await deleteJournal(organizationId, id, userId)

    if (isAPIKeyAuth) {
      await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${id}`, 204)
    }

    return new NextResponse(null, { status: 204 })
  } catch (error: any) {
    // Map error messages to proper status codes
    const errorMsg = error.message || ''
    let status = 500
    let code = 'internal_error'
    let message = 'Database error'
    
    if (errorMsg === 'Journal not found') {
      status = 404
      code = 'not_found'
      message = 'Journal not found.'
    } else if (errorMsg === 'Only drafts can be deleted') {
      status = 409
      code = 'not_draft'
      message = 'Only drafts can be deleted.'
    }
    
    if (isAPIKeyAuth) {
      await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${id}`, status)
    }
    
    return NextResponse.json(
      { error: { code, message } },
      { status }
    )
  }
}
