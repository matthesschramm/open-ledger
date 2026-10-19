'use client'

import { useRef, useState } from 'react'
import { Paperclip, Upload } from 'lucide-react'
import {
  ATTACHMENT_ACCEPT,
  ATTACHMENT_MAX_FILES,
  formatFileSize,
  mergeSelectedFiles,
} from '@/lib/journal-attachments'
import { cn } from '@/lib/utils'

export function EvidenceFilePicker({
  id,
  files,
  onFilesChange,
  disabled = false,
  description = `PDF or image, up to 10 MB each. ${ATTACHMENT_MAX_FILES} files at a time.`,
}: {
  id: string
  files: File[]
  onFilesChange: (files: File[]) => void
  disabled?: boolean
  description?: string
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState(false)

  function addIncoming(incoming: File[]) {
    if (disabled || incoming.length === 0) {
      return
    }
    onFilesChange(mergeSelectedFiles(files, incoming))
  }

  function removeFile(file: File) {
    onFilesChange(
      files.filter(
        (existing) =>
          existing.name !== file.name ||
          existing.size !== file.size ||
          existing.lastModified !== file.lastModified
      )
    )
  }

  return (
    <div className="space-y-3">
      <input
        ref={inputRef}
        id={id}
        type="file"
        multiple
        accept={ATTACHMENT_ACCEPT}
        disabled={disabled}
        className="sr-only"
        onChange={(event) => {
          addIncoming(Array.from(event.target.files ?? []))
          event.target.value = ''
        }}
      />

      <label
        htmlFor={disabled ? undefined : id}
        aria-disabled={disabled}
        onDragEnter={(event) => {
          event.preventDefault()
          if (!disabled) {
            setDragging(true)
          }
        }}
        onDragOver={(event) => {
          event.preventDefault()
          if (!disabled) {
            setDragging(true)
          }
        }}
        onDragLeave={(event) => {
          event.preventDefault()
          setDragging(false)
        }}
        onDrop={(event) => {
          event.preventDefault()
          setDragging(false)
          addIncoming(Array.from(event.dataTransfer.files ?? []))
        }}
        className={cn(
          'flex flex-col items-center justify-center gap-3 rounded-[13px] border border-dashed px-4 py-8 text-center transition-colors',
          disabled
            ? 'cursor-not-allowed border-line bg-paper opacity-60'
            : 'cursor-pointer border-line-strong hover:border-ink hover:bg-paper',
          dragging && !disabled && 'border-ink bg-paper'
        )}
      >
        <div className="flex h-10 w-10 items-center justify-center rounded-full bg-coral-soft">
          <Upload className="h-5 w-5 text-coral" />
        </div>
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">
            Drop files here, or click to browse
          </p>
          <p className="text-xs text-ink-soft">{description}</p>
        </div>
        <span className="inline-flex h-8 items-center rounded-lg border border-border bg-background px-2.5 text-sm font-medium">
          Choose files
        </span>
      </label>

      {files.length > 0 && (
        <ul className="space-y-2">
          {files.map((file) => (
            <li
              key={`${file.name}-${file.size}-${file.lastModified}`}
              className="flex items-center justify-between gap-3 rounded-md border border-neutral-200 px-3 py-2 text-sm"
            >
              <div className="flex min-w-0 items-center gap-2">
                <Paperclip className="h-3.5 w-3.5 shrink-0 text-neutral-500" />
                <span className="truncate font-medium">{file.name}</span>
                <span className="shrink-0 text-neutral-600">{formatFileSize(file.size)}</span>
              </div>
              <button
                type="button"
                className="shrink-0 text-xs text-neutral-600 underline"
                disabled={disabled}
                onClick={() => removeFile(file)}
              >
                Remove
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
