import type { SupabaseClient } from '@supabase/supabase-js'

export const ATTACHMENTS_BUCKET = 'attachments'
export const ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024
export const ATTACHMENT_MAX_FILES = 10
export const ATTACHMENT_ACCEPT = '.pdf,.png,.jpg,.jpeg,.webp,.heic,.heif'
export const ATTACHMENT_ENTITY_TYPE = 'journal'

const ALLOWED_MIME_TYPES = new Set([
  'application/pdf',
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
  'image/heif',
])

const EXTENSION_MIME: Record<string, string> = {
  pdf: 'application/pdf',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  heic: 'image/heic',
  heif: 'image/heif',
}

export type JournalAttachment = {
  id: string
  file_name: string
  file_size: number
  content_type: string
  storage_path: string
  created_at: string
}

export type AttachmentUploadFailure = {
  ok: false
  fileName: string
  error: string
}

export type AttachmentUploadSuccess = {
  ok: true
  attachment: JournalAttachment
}

export type AttachmentUploadResult = AttachmentUploadSuccess | AttachmentUploadFailure

function parseFileSize(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value
  }
  if (typeof value === 'string' && /^\d+$/.test(value)) {
    return Number(value)
  }
  return null
}

function parseJournalAttachment(value: unknown): JournalAttachment | null {
  if (!value || typeof value !== 'object') {
    return null
  }
  if (!('id' in value) || typeof value.id !== 'string') {
    return null
  }
  if (!('file_name' in value) || typeof value.file_name !== 'string') {
    return null
  }
  if (!('file_size' in value)) {
    return null
  }
  const fileSize = parseFileSize(value.file_size)
  if (fileSize === null) {
    return null
  }
  if (!('content_type' in value) || typeof value.content_type !== 'string') {
    return null
  }
  if (!('storage_path' in value) || typeof value.storage_path !== 'string') {
    return null
  }
  if (!('created_at' in value) || typeof value.created_at !== 'string') {
    return null
  }
  return {
    id: value.id,
    file_name: value.file_name,
    file_size: fileSize,
    content_type: value.content_type,
    storage_path: value.storage_path,
    created_at: value.created_at,
  }
}

export function safeFileName(name: string): string {
  const base = name.split(/[/\\]/).pop()?.trim() || 'file'
  const cleaned = base.replace(/[^\w.\- ()]/g, '_').replace(/_+/g, '_')
  return cleaned.slice(0, 80) || 'file'
}

export function inferAttachmentContentType(file: File): string | null {
  if (file.type && ALLOWED_MIME_TYPES.has(file.type)) {
    return file.type
  }
  const ext = file.name.split('.').pop()?.toLowerCase()
  if (!ext) {
    return null
  }
  return EXTENSION_MIME[ext] ?? null
}

export function attachmentValidationError(file: File): string | null {
  if (file.size <= 0) {
    return `${file.name} is empty.`
  }
  if (file.size > ATTACHMENT_MAX_BYTES) {
    return `${file.name} is over 10 MB.`
  }
  if (!inferAttachmentContentType(file)) {
    return `${file.name} must be a PDF or image.`
  }
  return null
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function journalAttachmentPath(input: {
  organizationId: string
  journalId: string
  fileName: string
}): string {
  return `org/${input.organizationId}/journals/${input.journalId}/${crypto.randomUUID()}-${safeFileName(input.fileName)}`
}

export async function listJournalAttachments(
  supabase: SupabaseClient,
  journalId: string
): Promise<JournalAttachment[]> {
  const { data, error } = await supabase
    .from('attachments')
    .select('id, file_name, file_size, content_type, storage_path, created_at')
    .eq('entity_type', ATTACHMENT_ENTITY_TYPE)
    .eq('entity_id', journalId)
    .order('created_at', { ascending: false })

  if (error) {
    throw new Error(error.message)
  }

  return (data ?? []).flatMap((row) => {
    const parsed = parseJournalAttachment(row)
    return parsed ? [parsed] : []
  })
}

/**
 * ACCOUNTING INVARIANT: This function NEVER creates, posts, reverses, or modifies journals.
 * It only writes to storage.objects and attachments table.
 */
export async function uploadJournalAttachment(input: {
  supabase: SupabaseClient
  organizationId: string
  journalId: string
  file: File
  userId: string
}): Promise<AttachmentUploadResult> {
  const validationError = attachmentValidationError(input.file)
  if (validationError) {
    return { ok: false, fileName: input.file.name, error: validationError }
  }

  const contentType = inferAttachmentContentType(input.file)
  if (!contentType) {
    return { ok: false, fileName: input.file.name, error: `${input.file.name} must be a PDF or image.` }
  }

  const storagePath = journalAttachmentPath({
    organizationId: input.organizationId,
    journalId: input.journalId,
    fileName: input.file.name,
  })

  const { error: uploadError } = await input.supabase.storage
    .from(ATTACHMENTS_BUCKET)
    .upload(storagePath, input.file, {
      contentType,
      upsert: false,
    })

  if (uploadError) {
    return { ok: false, fileName: input.file.name, error: uploadError.message }
  }

  const { data: inserted, error: insertError } = await input.supabase
    .from('attachments')
    .insert({
      organization_id: input.organizationId,
      entity_type: ATTACHMENT_ENTITY_TYPE,
      entity_id: input.journalId,
      file_name: input.file.name,
      file_size: input.file.size,
      content_type: contentType,
      storage_path: storagePath,
      uploaded_by: input.userId,
    })
    .select('id, file_name, file_size, content_type, storage_path, created_at')
    .single()

  const attachment = parseJournalAttachment(inserted)
  if (insertError || !attachment) {
    await input.supabase.storage.from(ATTACHMENTS_BUCKET).remove([storagePath])
    return {
      ok: false,
      fileName: input.file.name,
      error: insertError?.message || 'Could not save the file record.',
    }
  }

  return { ok: true, attachment }
}

export async function uploadJournalAttachments(input: {
  supabase: SupabaseClient
  organizationId: string
  journalId: string
  files: File[]
  userId: string
}): Promise<AttachmentUploadResult[]> {
  const files = input.files.slice(0, ATTACHMENT_MAX_FILES)
  const results: AttachmentUploadResult[] = []
  for (const file of files) {
    results.push(
      await uploadJournalAttachment({
        supabase: input.supabase,
        organizationId: input.organizationId,
        journalId: input.journalId,
        file,
        userId: input.userId,
      })
    )
  }
  return results
}

export async function deleteJournalAttachment(input: {
  supabase: SupabaseClient
  attachment: JournalAttachment
}): Promise<void> {
  const { error: storageError } = await input.supabase.storage
    .from(ATTACHMENTS_BUCKET)
    .remove([input.attachment.storage_path])

  if (storageError) {
    throw new Error(storageError.message)
  }

  const { error: rowError } = await input.supabase
    .from('attachments')
    .delete()
    .eq('id', input.attachment.id)

  if (rowError) {
    throw new Error(rowError.message)
  }
}

export async function createAttachmentSignedUrl(
  supabase: SupabaseClient,
  storagePath: string
): Promise<string> {
  const { data, error } = await supabase.storage
    .from(ATTACHMENTS_BUCKET)
    .createSignedUrl(storagePath, 300)

  if (error || !data?.signedUrl) {
    throw new Error(error?.message || 'Could not create a download link.')
  }

  return data.signedUrl
}

export function mergeSelectedFiles(current: File[], incoming: File[]): File[] {
  const next = [...current]
  for (const file of incoming) {
    const already = next.some(
      (existing) =>
        existing.name === file.name &&
        existing.size === file.size &&
        existing.lastModified === file.lastModified
    )
    if (!already) {
      next.push(file)
    }
  }
  return next.slice(0, ATTACHMENT_MAX_FILES)
}
