import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, errorResponse, logAPIUsage } from '@/lib/api-auth'
import { createAttachmentSignedUrl, deleteJournalAttachment } from '@/lib/journal-attachments'
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
  { params }: { params: Promise<{ id: string; attachmentId: string }> }
) {
  const { id: journalId, attachmentId } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'read')
  if (permError) {
    await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 403)
    return errorResponse(permError, 403)
  }

  try {
    const supabase = createSupabaseClient(auth.organizationId)
    
    // Verify attachment belongs to journal and organization
    const { data: attachment, error: attachmentError } = await supabase
      .from('attachments')
      .select('id, file_name, file_size, content_type, storage_path, created_at')
      .eq('id', attachmentId)
      .eq('entity_type', 'journal')
      .eq('entity_id', journalId)
      .eq('organization_id', auth.organizationId)
      .maybeSingle()

    if (attachmentError) throw new Error(attachmentError.message)
    if (!attachment) {
      await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 404)
      return errorResponse({
        error: {
          code: 'not_found',
          message: 'Attachment not found',
        },
      }, 404)
    }

    const signedUrl = await createAttachmentSignedUrl(supabase, attachment.storage_path)

    await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 200)

    return NextResponse.json({
      url: signedUrl,
      expires_in: 300,
    })
  } catch (error: any) {
    console.error('Get attachment download URL error:', error)
    await logAPIUsage(auth, 'GET', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'Failed to get download URL',
      },
    }, 500)
  }
}

export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string; attachmentId: string }> }
) {
  const { id: journalId, attachmentId } = await params
  const authHeader = request.headers.get('authorization')
  const auth = await validateAPIKey(authHeader)

  if ('error' in auth) {
    return errorResponse(auth, 401)
  }

  const permError = checkPermission(auth, 'write')
  if (permError) {
    await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 403)
    return errorResponse(permError, 403)
  }

  try {
    const supabase = createSupabaseClient(auth.organizationId)
    
    // Verify attachment belongs to journal and organization
    const { data: attachment, error: attachmentError } = await supabase
      .from('attachments')
      .select('id, file_name, file_size, content_type, storage_path, created_at')
      .eq('id', attachmentId)
      .eq('entity_type', 'journal')
      .eq('entity_id', journalId)
      .eq('organization_id', auth.organizationId)
      .maybeSingle()

    if (attachmentError) throw new Error(attachmentError.message)
    if (!attachment) {
      await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 404)
      return errorResponse({
        error: {
          code: 'not_found',
          message: 'Attachment not found',
        },
      }, 404)
    }

    await deleteJournalAttachment({
      supabase,
      attachment,
    })

    await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 200)

    return NextResponse.json({
      success: true,
      attachment_id: attachmentId,
    })
  } catch (error: any) {
    console.error('Delete journal attachment error:', error)
    await logAPIUsage(auth, 'DELETE', `/api/v1/journals/${journalId}/attachments/${attachmentId}`, 500)
    return errorResponse({
      error: {
        code: 'internal_error',
        message: error?.message || 'Failed to delete attachment',
      },
    }, 500)
  }
}
