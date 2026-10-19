'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Plus, Trash2 } from 'lucide-react'
import { getLocalDateString, companyToday } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

// Module-level lock (survives remount)
let moduleSubmitLock = false

function parseCreatedJournalId(result: unknown): string {
  if (!result || typeof result !== 'object') {
    throw new Error('Failed to create journal')
  }
  if (!('success' in result) || result.success !== true) {
    const message =
      'error' in result && typeof result.error === 'string'
        ? result.error
        : 'Failed to create journal'
    throw new Error(message)
  }
  if (!('journal_id' in result) || typeof result.journal_id !== 'string') {
    throw new Error('Failed to create journal')
  }
  return result.journal_id
}

export default function NewJournalPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [orgId, setOrgId] = useState<string | null>(null)
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [orgTimezone, setOrgTimezone] = useState<string>('UTC')
  const [accounts, setAccounts] = useState<any[]>([])
  const [date, setDate] = useState('')
  const [description, setDescription] = useState('')
  const [lines, setLines] = useState<any[]>([
    { account_id: '', debit: '', credit: '', memo: '' },
    { account_id: '', debit: '', credit: '', memo: '' },
  ])
  const [saving, setSaving] = useState(false)
  const [loading, setLoading] = useState(true)
  const [dateError, setDateError] = useState('')

  useEffect(() => {
    // Clear both locks on mount
    moduleSubmitLock = false
    sessionStorage.removeItem('journal-submit-lock')
    loadData()
    
    // Cleanup: clear locks on unmount
    return () => {
      moduleSubmitLock = false
      sessionStorage.removeItem('journal-submit-lock')
    }
  }, [])

  async function loadData() {
    const { data: orgData } = await supabase.rpc('current_org_id')
    const { data: roleData } = await supabase.rpc('current_role')
    setOrgId(orgData)
    setCurrentRole(roleData)

    // Load organization timezone
    if (orgData) {
      const { data: org } = await supabase
        .from('organizations')
        .select('timezone')
        .eq('id', orgData)
        .single()
      const tz = org?.timezone || 'UTC'
      setOrgTimezone(tz)
      setDate(companyToday(tz))
    }

    const { data: accountsData } = await supabase
      .from('accounts')
      .select('*')
      .eq('is_header', false)
      .eq('is_active', true)
      .order('code')
    if (accountsData) setAccounts(accountsData)
    
    setLoading(false)
  }

  function addLine() {
    setLines([...lines, { account_id: '', debit: '', credit: '', memo: '' }])
  }

  function removeLine(index: number) {
    if (lines.length > 2) {
      setLines(lines.filter((_, i) => i !== index))
    }
  }

  function updateLine(index: number, field: string, value: string) {
    const newLines = [...lines]
    
    if (field === 'debit' && value) {
      newLines[index] = { ...newLines[index], debit: value, credit: '' }
    } else if (field === 'credit' && value) {
      newLines[index] = { ...newLines[index], credit: value, debit: '' }
    } else {
      newLines[index] = { ...newLines[index], [field]: value }
    }
    
    setLines(newLines)
  }

  const totalDebit = lines.reduce((sum, line) => sum + (parseFloat(line.debit) || 0), 0)
  const totalCredit = lines.reduce((sum, line) => sum + (parseFloat(line.credit) || 0), 0)
  const isBalanced = totalDebit === totalCredit && totalDebit > 0
  
  // Validate lines: each line with an account must have exactly one non-zero side
  const validLines = lines.filter(l => {
    if (!l.account_id) return false // Ignore blank lines
    const hasDebit = l.debit && parseFloat(l.debit) !== 0
    const hasCredit = l.credit && parseFloat(l.credit) !== 0
    // Valid if has exactly one side (XOR)
    return (hasDebit && !hasCredit) || (!hasDebit && hasCredit)
  })
  
  // Find lines with validation errors
  const linesWithErrors = lines.map((l, idx) => {
    if (!l.account_id) return null // Blank lines are fine
    const hasDebit = l.debit && parseFloat(l.debit) !== 0
    const hasCredit = l.credit && parseFloat(l.credit) !== 0
    if (!hasDebit && !hasCredit) return { index: idx, error: 'Amount required' }
    if (hasDebit && hasCredit) return { index: idx, error: 'Only one side allowed' }
    return null
  }).filter(Boolean)
  
  const hasMinLines = validLines.length >= 2
  const canSaveDraft = description && validLines.length >= 2

  async function handleSave(draft: boolean = true) {
    if (!orgId) return
    
    // Clear any previous date errors
    setDateError('')
    
    // Module-level lock check (survives remount)
    if (moduleSubmitLock) {
      console.log('Submit blocked by module lock')
      return
    }
    
    // SessionStorage lock check (survives component lifecycle)
    const storageKey = 'journal-submit-lock'
    if (sessionStorage.getItem(storageKey) === 'true') {
      console.log('Submit blocked by sessionStorage lock')
      return
    }
    
    // Set both locks synchronously before any await
    moduleSubmitLock = true
    sessionStorage.setItem(storageKey, 'true')
    setSaving(true)

    try {
      // Prepare lines in RPC format with fingerprint ordering
      const journalLines = lines
        .filter(l => l.account_id && (l.debit || l.credit))
        .map(line => ({
          account_id: line.account_id,
          debit_cents: Math.round((parseFloat(line.debit) || 0) * 100),
          credit_cents: Math.round((parseFloat(line.credit) || 0) * 100),
          memo: line.memo || null,
        }))
        .sort((a, b) => {
          // Sort for consistent fingerprint
          if (a.account_id !== b.account_id) return a.account_id.localeCompare(b.account_id)
          if (a.debit_cents !== b.debit_cents) return a.debit_cents - b.debit_cents
          return a.credit_cents - b.credit_cents
        })

      // Call atomic RPC
      const { data: result, error: rpcError } = await supabase.rpc('create_manual_journal', {
        p_organization_id: orgId,
        p_entry_date: date,
        p_description: description,
        p_lines: journalLines,
        p_should_post: !draft,
      })

      if (rpcError) {
        // Check if this is a period lock error
        if (rpcError.message.includes('This date is in a locked period')) {
          // Extract the full error message which includes the formatted date
          const match = rpcError.message.match(/This date is in a locked period\. Choose a date after ([^.]+)\./)
          if (match) {
            setDateError(`This date is in a locked period. Choose a date after ${match[1]}.`)
          } else {
            setDateError('This date is in a locked period.')
          }
        } else {
          setDateError(rpcError.message)
        }
        // Only clear locks on error (success navigates away)
        moduleSubmitLock = false
        sessionStorage.removeItem(storageKey)
        setSaving(false)
        return
      }
      
      const journalId = parseCreatedJournalId(result)

      // Clear locks before navigation (success path)
      moduleSubmitLock = false
      sessionStorage.removeItem(storageKey)
      
      router.push(`/journals/${journalId}`)
    } catch (error: any) {
      // Check if this is a period lock error
      if (error.message.includes('This date is in a locked period')) {
        // Extract the full error message which includes the formatted date
        const match = error.message.match(/This date is in a locked period\. Choose a date after ([^.]+)\./)
        if (match) {
          setDateError(`This date is in a locked period. Choose a date after ${match[1]}.`)
        } else {
          setDateError('This date is in a locked period.')
        }
      } else {
        setDateError(error.message)
      }
      // Only clear locks on error (success navigates away)
      moduleSubmitLock = false
      sessionStorage.removeItem(storageKey)
      setSaving(false)
    }
  }

  const canCreate = currentRole && ['owner', 'bookkeeper'].includes(currentRole)

  if (loading) {
    return (
      <div className="p-8">
        <p className="text-neutral-600">Loading...</p>
      </div>
    )
  }

  if (!canCreate) {
    return (
      <div className="p-8">
        <p className="text-neutral-600">You don't have permission to create journals.</p>
      </div>
    )
  }

  return (
    <div className="p-8">
      <div className="mb-8">
        <h1 className="text-3xl font-semibold tracking-tight">New Journal Entry</h1>
        <p className="text-muted-foreground">Create a manual journal entry</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Journal Details</CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-2">
              <label htmlFor="journal-date" className="text-sm font-medium">Effective date</label>
              <input
                id="journal-date"
                type="date"
                value={date}
                onChange={(e) => {
                  setDate(e.target.value)
                  setDateError('')
                }}
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              />
              {dateError && (
                <p className="text-xs text-red-600">{dateError}</p>
              )}
            </div>
            <div className="space-y-2">
              <label htmlFor="journal-description" className="text-sm font-medium">
                Description <span className="text-red-600">*</span>
              </label>
              <input
                id="journal-description"
                type="text"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Parent funding, Expense payment, etc."
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <h3 className="font-medium">Journal Lines</h3>
              <Button type="button" variant="outline" size="sm" onClick={addLine}>
                <Plus className="h-4 w-4 mr-2" />
                Add Line
              </Button>
            </div>

            {lines.map((line, index) => {
              const lineError = linesWithErrors.find(e => e && e.index === index)
              return (
                <div key={index} className="space-y-1">
                  <div className="grid gap-3 md:grid-cols-12 items-start">
                    <div className="md:col-span-4">
                      <select
                        aria-label={`Line ${index + 1} account`}
                        value={line.account_id}
                        onChange={(e) => updateLine(index, 'account_id', e.target.value)}
                        className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                      >
                        <option value="">Select account...</option>
                        {accounts.map(acc => (
                          <option key={acc.id} value={acc.id}>
                            {acc.code} - {acc.name}
                          </option>
                        ))}
                      </select>
                    </div>
                    <div className="md:col-span-2">
                      <input
                        aria-label={`Line ${index + 1} debit`}
                        type="number"
                        step="0.01"
                        value={line.debit}
                        onChange={(e) => updateLine(index, 'debit', e.target.value)}
                        placeholder="Debit $"
                        className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                      />
                    </div>
                    <div className="md:col-span-2">
                      <input
                        aria-label={`Line ${index + 1} credit`}
                        type="number"
                        step="0.01"
                        value={line.credit}
                        onChange={(e) => updateLine(index, 'credit', e.target.value)}
                        placeholder="Credit $"
                        className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                      />
                    </div>
                    <div className="md:col-span-3">
                      <input
                        aria-label={`Line ${index + 1} memo`}
                        type="text"
                        value={line.memo}
                        onChange={(e) => updateLine(index, 'memo', e.target.value)}
                        placeholder="Memo (optional)"
                        className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                      />
                    </div>
                    <div className="md:col-span-1">
                      {lines.length > 2 && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => removeLine(index)}
                          aria-label={`Remove line ${index + 1}`}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      )}
                    </div>
                  </div>
                  {lineError && (
                    <p className="text-xs text-red-600 md:col-span-12">
                      {lineError.error}
                    </p>
                  )}
                </div>
              )
            })}
          </div>

          <div className="border-t pt-4">
            <div className="flex justify-between text-sm mb-2">
              <span>Total Debits:</span>
              <span className="font-medium">{formatCurrency(Math.round(totalDebit * 100))}</span>
            </div>
            <div className="flex justify-between text-sm mb-2">
              <span>Total Credits:</span>
              <span className="font-medium">{formatCurrency(Math.round(totalCredit * 100))}</span>
            </div>
            <div className="flex justify-between text-sm font-medium">
              <span>Difference:</span>
              <span className={totalDebit !== totalCredit ? 'text-red-600' : 'text-green-600'}>
                {formatCurrency(Math.round(Math.abs(totalDebit - totalCredit) * 100))}
              </span>
            </div>
            {!isBalanced && (
              <p className="text-xs text-red-600 mt-2">Entry must balance before posting</p>
            )}
            {!hasMinLines && (
              <p className="text-xs text-red-600 mt-1">At least 2 lines required</p>
            )}
          </div>

          <div className="flex gap-3">
            <Button
              type="button"
              onClick={() => handleSave(true)}
              disabled={saving || !canSaveDraft}
              variant="outline"
            >
              {saving ? 'Saving...' : 'Save Draft'}
            </Button>
            <Button
              type="button"
              onClick={() => handleSave(false)}
              disabled={saving || !isBalanced || !hasMinLines || !description}
            >
              {saving ? 'Saving...' : 'Save and Post'}
            </Button>
            <Button type="button" variant="ghost" onClick={() => router.back()} disabled={saving}>
              Cancel
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
