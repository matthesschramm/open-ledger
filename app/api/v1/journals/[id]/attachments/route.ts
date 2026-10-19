import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { listJournalAttachments, uploadJournalAttachment, ATTACHMENT_MAX_BYTES } from '@/lib/journal-attachments'
import { createServerClient } from '@supabase/ssr'

function createSupabaseClient(organizationId: string) {
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('Missing Supabase environment variables')
  }
  
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY,
    {
      cookies: {
        getAll() { return [] },
        setAll() { },
      },
    }
  )
}

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id: journalId } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments`, 403)
    return errorResponse(permError, 403)
  }

  try {
    const supabase = createSupabaseClient(auth.organizationId)
    
    // Verify journal belongs to organization
    const { data: journal, error: journalError } = await supabase
      .from('journals')
      .select('id')
      .eq('id', journalId)
      .eq('organization_id', auth.organizationId)
      .maybeSingle()

    if (journalError) throw new Error(journalError.message)
    if (!journal) {
      await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments`, 404)
      return errorResponse({
        error: {
          code: 'not_found',
          message: 'Journal not found',
        },
      }, 404)
    }

    const attachments = await listJournalAttachments(supabase, journalId)

    await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments`, 200)

    return NextResponse.json({
      attachments: attachments.map(att => ({
        id: att.id,
        file_name: att.file_name,
        file_size: att.file_size,
        content_type: att.content_type,
        created_at: att.created_at,
      })),
    })
  } catch (error: any) {
    console.error('List journal attachments error:', error)
    await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments`, 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'Failed to list attachments',
      },
    }, 500)
  }
}

/**
 * POST /api/v1/journals/:id/attachments
 * 
 * ACCOUNTING INVARIANT: This endpoint NEVER creates, posts, reverses, or modifies journals.
 * It only writes to storage.objects and attachments table via uploadJournalAttachment.
 */
export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id: journalId } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'write')
  if (permError) {
    await logAPIUsage(auth, 'POST', `/api/v1/journals/${journalId}/attachments`, 403)
    return errorResponse(permError, 403)
  }

  try {
    const supabase = createSupabaseClient(auth.organizationId)
    
    // Verify journal belongs to organization
    const { data: journal, error: journalError } = await supabase
      .from('journals')
      .select('id')
      .eq('id', journalId)
      .eq('organization_id', auth.organizationId)
      .maybeSingle()

    if (journalError) throw new Error(journalError.message)
    if (!journal) {
      await logAPIUsage(auth, 'POST', `/api/v1/journals/${journalId}/attachments`, 404)
      return errorResponse({
        error: {
          code: 'not_found',
          message: 'Journal not found',
        },
      }, 404)
    }

    const contentType = request.headers.get('content-type')
    if (!contentType?.startsWith('multipart/form-data')) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'Content-Type must be multipart/form-data',
        },
      }, 400)
    }

    const formData = await request.formData()
    const file = formData.get('file')

    if (!file || !(file instanceof File)) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'Missing required file field',
        },
      }, 400)
    }

    if (file.size > ATTACHMENT_MAX_BYTES) {
      return errorResponse({
        error: {
          code: 'invalid_request',
          message: 'File size exceeds 10 MB limit',
        },
      }, 400)
    }

    const result = await uploadJournalAttachment({
      supabase,
      organizationId: auth.organizationId,
      journalId,
      file,
      userId: auth.userId,
    })

    if (!result.ok) {
      return errorResponse({
        error: {
          code: 'upload_failed',
          message: result.error,
        },
      }, 400)
    }

    await logAPIUsage(auth, 'POST', `/api/v1/journals/${journalId}/attachments`, 201)

    return NextResponse.json({
      attachment: {
        id: result.attachment.id,
        file_name: result.attachment.file_name,
        file_size: result.attachment.file_size,
        content_type: result.attachment.content_type,
        created_at: result.attachment.created_at,
      },
    }, { status: 201 })
  } catch (error: any) {
    console.error('Upload journal attachment error:', error)
    await logAPIUsage(auth, 'POST', `/api/v1/journals/${journalId}/attachments`, 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'Failed to upload attachment',
      },
    }, 500)
  }
}
