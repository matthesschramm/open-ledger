'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter, useParams } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { ArrowLeft } from 'lucide-react'
import { formatDate, companyToday, formatTimestamp } from '@/lib/format-date'
import { formatMelbourneTimestamp } from '@/lib/local-date'
import { formatCurrency } from '@/lib/money'
import { formatJournalText } from '@/lib/format-journal-text'
import { journalSourceLabel } from '@/lib/journal-source'
import { JournalEvidence } from '@/components/app/journal-evidence'

export default function JournalDetailPage() {
  const router = useRouter()
  const params = useParams()
  const supabase = createClient()
  
  const [journal, setJournal] = useState<any>(null)
  const [lines, setLines] = useState<any[]>([])
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [orgTimezone, setOrgTimezone] = useState<string | null>(null)
  const [posting, setPosting] = useState(false)
  const [reversing, setReversing] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [showReverseConfirm, setShowReverseConfirm] = useState(false)
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false)
  const [actionMessage, setActionMessage] = useState<{ type: 'success' | 'error', text: string } | null>(null)
  const [reversingJournalNumber, setReversingJournalNumber] = useState<string | null>(null)
  const [reversedJournalNumber, setReversedJournalNumber] = useState<string | null>(null)

  const journalId = params?.id as string

  useEffect(() => {
    if (journalId) {
      loadJournal()
    }
  }, [journalId])

  async function loadJournal() {
    try {
      setLoading(true)
      setError(null)

      const { data: roleData } = await supabase.rpc('current_role')
      setCurrentRole(roleData)

      const { data: journalData, error: journalError } = await supabase
        .from('journals')
        .select('*')
        .eq('id', journalId)
        .single()

      if (journalError) throw journalError
      if (journalData) {
        setJournal(journalData)
        // Load organization timezone
        const { data: org } = await supabase
          .from('organizations')
          .select('timezone')
          .eq('id', journalData.organization_id)
          .single()
        setOrgTimezone(org?.timezone || 'UTC')
      }

      const { data: linesData, error: linesError } = await supabase
        .from('journal_lines')
        .select(`
          *,
          account:accounts(code, name)
        `)
        .eq('journal_id', journalId)
        .order('created_at')

      if (linesError) throw linesError
      if (linesData) setLines(linesData)

      if (journalData?.reverses_journal_id) {
        const { data: reversedJournal } = await supabase
          .from('journals')
          .select('number')
          .eq('id', journalData.reverses_journal_id)
          .single()
        if (reversedJournal) setReversedJournalNumber(reversedJournal.number)
      }

      if (journalData?.reversed_by_journal_id) {
        const { data: reversingJournal } = await supabase
          .from('journals')
          .select('number')
          .eq('id', journalData.reversed_by_journal_id)
          .single()
        if (reversingJournal) setReversingJournalNumber(reversingJournal.number)
      }

      if (typeof window !== 'undefined') {
        const evidenceFlag = new URLSearchParams(window.location.search).get('evidence')
        if (evidenceFlag === 'failed') {
          setActionMessage({
            type: 'error',
            text: 'The journal was saved, but the files could not be attached. Try again under Supporting documents.',
          })
        }
      }
    } catch (err: any) {
      setError(err.message || 'Failed to load journal')
    } finally {
      setLoading(false)
    }
  }

  async function handlePost() {
    if (!currentRole || !['owner', 'bookkeeper'].includes(currentRole)) return
    
    setPosting(true)
    setActionMessage(null)
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      const { data, error } = await supabase.rpc('post_journal', {
        p_journal_id: journalId,
        p_user_id: user.id,
      })

      if (error) throw error
      if (data && !data.success) {
        // For lock errors, show the message directly without "Failed to post:" prefix
        const errorText = data.error?.includes('locked period') 
          ? data.error 
          : `Failed to post: ${data.error}`
        setActionMessage({ type: 'error', text: errorText })
      } else {
        await loadJournal()
        const journalNumber = data?.journal_number || 'journal'
        setActionMessage({ type: 'success', text: `Posted as ${journalNumber}.` })
      }
    } catch (error: any) {
      setActionMessage({ type: 'error', text: `Error: ${error.message}` })
    } finally {
      setPosting(false)
    }
  }

  function initiateReverse() {
    setActionMessage(null)
    setShowReverseConfirm(true)
  }

  async function confirmReverse() {
    setShowReverseConfirm(false)
    setReversing(true)
    setActionMessage(null)
    
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      const { data, error } = await supabase.rpc('reverse_journal', {
        p_journal_id: journalId,
        p_reversal_date: companyToday(orgTimezone ?? 'UTC'),
        p_reversal_description: null,
        p_user_id: user.id,
      })

      if (error) {
        setActionMessage({ type: 'error', text: `Error: ${error.message}` })
        return
      }
      
      if (!data) {
        setActionMessage({ type: 'error', text: 'Failed to reverse: No response from server' })
        return
      }
      
      if (!data.success) {
        setActionMessage({ type: 'error', text: `Failed to reverse: ${data.error}` })
        return
      }
      
      await loadJournal()
      setActionMessage({ type: 'success', text: 'Journal reversed successfully' })
    } catch (error: any) {
      setActionMessage({ type: 'error', text: `Error: ${error.message}` })
    } finally {
      setReversing(false)
    }
  }

  function cancelReverse() {
    setShowReverseConfirm(false)
  }

  function initiateDelete() {
    setActionMessage(null)
    setShowDeleteConfirm(true)
  }

  async function confirmDelete() {
    setShowDeleteConfirm(false)
    setDeleting(true)
    setActionMessage(null)
    
    try {
      const response = await fetch(`/api/v1/journals/${journalId}`, {
        method: 'DELETE',
      })

      if (!response.ok) {
        // Try to parse error message
        const data = await response.json().catch(() => null)
        const errorMessage = data?.error?.message || 'Failed to delete journal'
        setActionMessage({ type: 'error', text: errorMessage })
        return
      }
      
      // Success - navigate back to journals list with success toast
      // Note: API returns 204 No Content, so no JSON to parse
      router.push('/journals?deleted=true')
    } catch (error: any) {
      setActionMessage({ type: 'error', text: `Error: ${error.message}` })
    } finally {
      setDeleting(false)
    }
  }

  function cancelDelete() {
    setShowDeleteConfirm(false)
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  if (error || !journal) {
    return (
      <div className="p-8">
        <Button variant="ghost" onClick={() => router.back()} className="mb-4">
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back
        </Button>
        <p className="text-red-600">{error || 'Journal not found'}</p>
      </div>
    )
  }

  const totalDebit = lines.reduce((sum, line) => sum + line.debit_cents, 0) / 100
  const totalCredit = lines.reduce((sum, line) => sum + line.credit_cents, 0) / 100

  const canPost = currentRole && ['owner', 'bookkeeper'].includes(currentRole) && journal.status === 'Draft'
  const canReverse = currentRole && ['owner', 'bookkeeper'].includes(currentRole) && journal.status === 'Posted'
  const canDelete = currentRole && ['owner', 'bookkeeper'].includes(currentRole) && journal.status === 'Draft'

  return (
    <div className="p-8">
      <div className="mb-8">
        <Button variant="ghost" onClick={() => router.back()} className="mb-4">
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back
        </Button>

        {actionMessage && (
          <div className={`mb-4 p-4 rounded-md ${
            actionMessage.type === 'success' 
              ? 'bg-green-50 text-green-800 border border-green-200' 
              : 'bg-red-50 text-red-800 border border-red-200'
          }`}>
            <p className="text-sm font-medium">{actionMessage.text}</p>
          </div>
        )}

        {showReverseConfirm && (
          <div className="mb-4 p-4 rounded-md bg-yellow-50 border border-yellow-200">
            <p className="text-sm font-medium text-yellow-900 mb-3">
              Reverse this journal entry? This creates a new reversing entry with swapped debits and credits.
            </p>
            <div className="flex gap-3">
              <Button onClick={confirmReverse} disabled={reversing} size="sm">
                {reversing ? 'Reversing...' : 'Confirm Reverse'}
              </Button>
              <Button onClick={cancelReverse} variant="outline" size="sm" disabled={reversing}>
                Cancel
              </Button>
            </div>
          </div>
        )}

        <Dialog open={showDeleteConfirm} onOpenChange={setShowDeleteConfirm}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Delete draft?</DialogTitle>
              <DialogDescription>
                This will permanently delete journal {journal.number || 'Draft'}. This action cannot be undone.
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <Button onClick={cancelDelete} variant="outline" disabled={deleting}>
                Cancel
              </Button>
              <Button onClick={confirmDelete} disabled={deleting}>
                {deleting ? 'Deleting...' : 'Delete'}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>

        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">{journal.number || 'Draft journal'}</h1>
            <p className="text-muted-foreground">{formatJournalText(journal.description, journal.entry_date)}</p>
          </div>
          <Badge variant={
            journal.status === 'Posted' ? 'default' :
            journal.status === 'Reversed' ? 'secondary' : 'outline'
          }>
            {journal.status}
          </Badge>
        </div>
      </div>

      <Card className="mb-6">
        <CardHeader>
          <CardTitle>Journal Lines</CardTitle>
          <CardDescription>
            Effective date: {formatDate(journal.entry_date)} · 
            Source: {journalSourceLabel(journal.source)}
            {journal.posted_at && orgTimezone && ` · Posted: ${formatTimestamp(journal.posted_at, orgTimezone)}`}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="space-y-3">
            {lines.map((line: any) => (
              <div key={line.id} className="grid grid-cols-12 gap-4 text-sm border-b pb-3">
                <div className="col-span-5">
                  <span className="font-medium">{line.account.code}</span>
                  <span className="text-muted-foreground ml-2">{line.account.name}</span>
                  {line.memo && (
                    <p className="text-xs text-muted-foreground mt-1">{formatJournalText(line.memo, journal.entry_date)}</p>
                  )}
                </div>
                <div className="col-span-3 text-right">
                  {line.debit_cents > 0 && (
                    <span>{formatCurrency(line.debit_cents)}</span>
                  )}
                </div>
                <div className="col-span-3 text-right">
                  {line.credit_cents > 0 && (
                    <span>{formatCurrency(line.credit_cents)}</span>
                  )}
                </div>
              </div>
            ))}
          </div>

          <div className="border-t pt-4 mt-4">
            <div className="grid grid-cols-12 gap-4 text-sm font-medium">
              <div className="col-span-5">Total</div>
              <div className="col-span-3 text-right">{formatCurrency(Math.round(totalDebit * 100))}</div>
              <div className="col-span-3 text-right">{formatCurrency(Math.round(totalCredit * 100))}</div>
            </div>
          </div>

          <div className="flex gap-3 mt-6">
            {canPost && (
              <Button onClick={handlePost} disabled={posting}>
                {posting ? 'Posting...' : 'Post Journal'}
              </Button>
            )}
            {canReverse && (
              <Button onClick={initiateReverse} disabled={reversing || showReverseConfirm} variant="outline">
                Reverse Journal
              </Button>
            )}
            {canDelete && (
              <Button onClick={initiateDelete} disabled={deleting || showDeleteConfirm} variant="outline">
                Delete
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      {typeof journal.organization_id === 'string' && (
        <div className="mb-6">
          <JournalEvidence
            journalId={journal.id}
            organizationId={journal.organization_id}
            canEdit={Boolean(currentRole && ['owner', 'bookkeeper'].includes(currentRole))}
          />
        </div>
      )}

      {journal.reverses_journal_id && (
        <Card>
          <CardContent className="pt-6">
            <p className="text-sm text-muted-foreground">
              This entry reverses journal{' '}
              <button
                onClick={() => router.push(`/journals/${journal.reverses_journal_id}`)}
                className="text-blue-600 hover:underline"
              >
                {reversedJournalNumber || `#${journal.reverses_journal_id.slice(0, 8)}`}
              </button>
            </p>
          </CardContent>
        </Card>
      )}

      {journal.reversed_by_journal_id && (
        <Card>
          <CardContent className="pt-6">
            <p className="text-sm text-muted-foreground">
              This entry was reversed by{' '}
              <button
                onClick={() => router.push(`/journals/${journal.reversed_by_journal_id}`)}
                className="text-blue-600 hover:underline"
              >
                {reversingJournalNumber || `#${journal.reversed_by_journal_id.slice(0, 8)}`}
              </button>
            </p>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
