'use client'

import { useEffect, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Trash2 } from 'lucide-react'
import { EvidenceFilePicker } from '@/components/app/evidence-file-picker'
import {
  createAttachmentSignedUrl,
  deleteJournalAttachment,
  formatFileSize,
  listJournalAttachments,
  uploadJournalAttachments,
  type JournalAttachment,
} from '@/lib/journal-attachments'

export function JournalEvidence({
  journalId,
  organizationId,
  canEdit,
  notice,
}: {
  journalId: string
  organizationId: string
  canEdit: boolean
  notice?: string
}) {
  const supabaseRef = useRef(createClient())
  const supabase = supabaseRef.current
  const [attachments, setAttachments] = useState<JournalAttachment[]>([])
  const [pendingFiles, setPendingFiles] = useState<File[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(notice ?? null)

  useEffect(() => {
    let cancelled = false

    async function load() {
      try {
        const rows = await listJournalAttachments(supabase, journalId)
        if (!cancelled) {
          setAttachments(rows)
        }
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Could not load attachments.')
        }
      } finally {
        if (!cancelled) {
          setLoading(false)
        }
      }
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [journalId, supabase])

  // Upload supporting documents to storage + attachments table.
  // ACCOUNTING INVARIANT: This function NEVER creates, posts, reverses, or modifies journals.
  // It only writes to storage.objects and attachments table.
  async function handleUpload() {
    if (!canEdit || pendingFiles.length === 0) {
      return
    }

    setBusy(true)
    setError(null)

    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) {
        throw new Error('Not signed in.')
      }

      const results = await uploadJournalAttachments({
        supabase,
        organizationId,
        journalId,
        files: pendingFiles,
        userId: user.id,
      })

      const uploaded = results.flatMap((result) => (result.ok ? [result.attachment] : []))
      const failed = results.filter((result) => !result.ok)
      setAttachments((current) => [...uploaded, ...current])
      setPendingFiles([])

      if (failed.length > 0) {
        setError(failed.map((result) => result.error).join(' '))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not attach files.')
    } finally {
      setBusy(false)
    }
  }

  async function handleDownload(attachment: JournalAttachment) {
    setError(null)
    try {
      const url = await createAttachmentSignedUrl(supabase, attachment.storage_path)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not open the file.')
    }
  }

  async function handleDelete(attachment: JournalAttachment) {
    if (!canEdit) {
      return
    }
    if (!window.confirm(`Remove ${attachment.file_name}?`)) {
      return
    }

    setBusy(true)
    setError(null)
    try {
      await deleteJournalAttachment({ supabase, attachment })
      setAttachments((current) => current.filter((row) => row.id !== attachment.id))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not remove the file.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Supporting documents</CardTitle>
        <CardDescription>
          Invoices, tax notices, bank advice, or other files that support this journal.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {error && (
          <p className="text-sm text-red-600">{error}</p>
        )}

        {loading ? (
          <p className="text-sm text-neutral-600">Loading...</p>
        ) : attachments.length === 0 ? (
          <p className="text-sm text-neutral-600">No supporting documents yet</p>
        ) : (
          <ul className="space-y-2">
            {attachments.map((attachment) => (
              <li
                key={attachment.id}
                className="flex items-center justify-between gap-3 rounded-md border border-neutral-200 px-3 py-2"
              >
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium">{attachment.file_name}</p>
                  <p className="text-xs text-neutral-600">{formatFileSize(attachment.file_size)}</p>
                </div>
                <div className="flex shrink-0 gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => handleDownload(attachment)}
                  >
                    Open
                  </Button>
                  {canEdit && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      onClick={() => handleDelete(attachment)}
                      disabled={busy}
                      aria-label={`Remove ${attachment.file_name}`}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}

        {canEdit && (
          <div className="space-y-3 border-t pt-4">
            <p className="text-sm font-medium">Upload</p>
            <EvidenceFilePicker
              id="journal-evidence-add"
              files={pendingFiles}
              onFilesChange={setPendingFiles}
              disabled={busy}
            />
            <Button
              type="button"
              onClick={handleUpload}
              disabled={busy || pendingFiles.length === 0}
            >
              {busy ? 'Uploading...' : 'Upload'}
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
