'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { ArrowLeft, Plus, Trash2 } from 'lucide-react'
import { getLocalDateString, formatDate, companyToday } from '@/lib/format-date'
import { guardedPost } from '@/lib/guarded-post'
import { formatCurrency } from '@/lib/money'

export default function NewBillPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [orgId, setOrgId] = useState<string | null>(null)
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [orgTimezone, setOrgTimezone] = useState<string>('America/New_York')
  const [contacts, setContacts] = useState<any[]>([])
  const [expenseAccounts, setExpenseAccounts] = useState<any[]>([])
  const [apAccount, setApAccount] = useState<any>(null)
  
  const [vendorId, setVendorId] = useState('')
  const [billNumber, setBillNumber] = useState('')
  const [billDate, setBillDate] = useState('')
  const [dueDate, setDueDate] = useState('')
  const [memo, setMemo] = useState('')
  const [lines, setLines] = useState<any[]>([
    { account_id: '', amount: '', description: '' },
  ])
  const [saving, setSaving] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({})

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    const { data: orgData } = await supabase.rpc('current_org_id')
    const { data: roleData } = await supabase.rpc('current_role')
    setOrgId(orgData)
    setCurrentRole(roleData)

    // Get organization timezone
    const { data: orgInfo } = await supabase
      .from('organizations')
      .select('timezone')
      .single()
    
    const tz = orgInfo?.timezone || 'America/New_York'
    setOrgTimezone(tz)
    
    // Set default dates using company-local timezone
    const today = companyToday(tz)
    setBillDate(today)

    const { data: contactsData } = await supabase
      .from('contacts')
      .select('*')
      .eq('is_active', true)
      .in('type', ['Vendor', 'Other'])
      .order('name')
    if (contactsData) setContacts(contactsData)

    const { data: accountsData } = await supabase
      .from('accounts')
      .select('*')
      .eq('type', 'Expense')
      .eq('is_active', true)
      .eq('is_header', false)
      .order('code')
    if (accountsData) setExpenseAccounts(accountsData)

    const { data: apData } = await supabase
      .from('accounts')
      .select('*')
      .eq('code', '2000')
      .single()
    if (apData) setApAccount(apData)
    
    setLoading(false)
  }

  function addLine() {
    setLines([...lines, { account_id: '', amount: '', description: '' }])
  }

  function removeLine(index: number) {
    if (lines.length > 1) {
      setLines(lines.filter((_, i) => i !== index))
    }
  }

  function updateLine(index: number, field: string, value: string) {
    const newLines = [...lines]
    newLines[index] = { ...newLines[index], [field]: value }
    setLines(newLines)
  }

  const totalAmount = lines.reduce((sum, line) => sum + (parseFloat(line.amount) || 0), 0)

  async function handleSave() {
    if (!orgId || !apAccount) return
    
    // Clear previous errors
    setError(null)
    setFieldErrors({})
    
    // Validate due date
    if (!dueDate) {
      setFieldErrors({ dueDate: 'Add a due date.' })
      return
    }
    
    setSaving(true)

    try {
      // Get current user
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      let billId: string

      await guardedPost(supabase, orgId, billDate, null, async (track) => {
        // Create bill (Draft status)
        const { data: bill, error: billError } = await supabase
          .from('bills')
          .insert({
            organization_id: orgId,
            vendor_id: vendorId,
            number: billNumber,
            bill_date: billDate,
            due_date: dueDate || null,
            total_cents: Math.round(totalAmount * 100),
            status: 'Draft',
            notes: memo || null,
            created_by: user.id,
          })
          .select()
          .single()

        if (billError) throw billError
        track('bills', bill.id)
        billId = bill.id

        // Create bill lines
        const billLines = lines
          .filter(l => l.account_id && l.amount)
          .map((line) => ({
            organization_id: orgId,
            bill_id: bill.id,
            account_id: line.account_id,
            amount_cents: Math.round((parseFloat(line.amount) || 0) * 100),
            description: line.description || '',
          }))

        const { data: insertedLines, error: linesError } = await supabase
          .from('bill_lines')
          .insert(billLines)
          .select()

        if (linesError) throw linesError
        insertedLines?.forEach(line => track('bill_lines', line.id))

        // Create AP recognition journal (Draft, number assigned at post time)
        const { data: journal, error: journalError } = await supabase
          .from('journals')
          .insert({
            organization_id: orgId,
            number: null,
            entry_date: billDate,
            description: `Bill ${billNumber} - ${contacts.find(c => c.id === vendorId)?.name}`,
            status: 'Draft',
            source: 'bill',
            created_by: user.id,
          })
          .select()
          .single()

        if (journalError) throw journalError
        track('journals', journal.id)

        // Create journal lines (Dr Expense, Cr AP)
        const journalLines = [
          ...billLines.map(line => ({
            organization_id: orgId,
            journal_id: journal.id,
            account_id: line.account_id,
            debit_cents: line.amount_cents,
            credit_cents: 0,
            memo: line.description,
          })),
          {
            organization_id: orgId,
            journal_id: journal.id,
            account_id: apAccount.id,
            debit_cents: 0,
            credit_cents: Math.round(totalAmount * 100),
            memo: `Bill ${billNumber}`,
          },
        ]

        const { data: insertedJournalLines, error: journalLinesError } = await supabase
          .from('journal_lines')
          .insert(journalLines)
          .select()

        if (journalLinesError) throw journalLinesError
        insertedJournalLines?.forEach(line => track('journal_lines', line.id))

        // Post the journal via RPC (respects period locks)
        const { data: postResult, error: postError } = await supabase.rpc('post_journal', {
          p_journal_id: journal.id,
          p_user_id: user.id,
        })

        if (postError) throw postError
        if (!postResult?.success) {
          throw new Error(postResult?.error || 'Unknown error')
        }

        // Update bill with recognition_journal_id and status to Open (only if post succeeded)
        const { error: billUpdateError } = await supabase
          .from('bills')
          .update({ 
            recognition_journal_id: journal.id,
            status: 'Open'
          })
          .eq('id', bill.id)

        if (billUpdateError) throw billUpdateError
      })

      router.push(`/bills/${billId!}`)
    } catch (error: any) {
      setError(error.message || 'An error occurred while saving the bill.')
    } finally {
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
        <p className="text-neutral-600">You don't have permission to create bills.</p>
      </div>
    )
  }

  return (
    <div className="p-8">
      <div className="mb-8">
        <h1 className="text-3xl font-semibold tracking-tight">New Bill</h1>
        <p className="text-muted-foreground">Create a vendor bill</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Bill Details</CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          {error && (
            <div className="p-4 rounded-md bg-red-50 border border-red-200">
              <p className="text-sm font-medium text-red-800">{error}</p>
            </div>
          )}
          
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-2">
              <label htmlFor="bill-vendor" className="text-sm font-medium">Vendor</label>
              <select
                id="bill-vendor"
                value={vendorId}
                onChange={(e) => setVendorId(e.target.value)}
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              >
                <option value="">Select vendor...</option>
                {contacts.map(contact => (
                  <option key={contact.id} value={contact.id}>
                    {contact.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <label htmlFor="bill-number" className="text-sm font-medium">Bill Number</label>
              <input
                id="bill-number"
                type="text"
                value={billNumber}
                onChange={(e) => setBillNumber(e.target.value)}
                placeholder="INV-001"
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              />
            </div>
            <div className="space-y-2">
              <label htmlFor="bill-date" className="text-sm font-medium">Bill Date</label>
              <input
                id="bill-date"
                type="date"
                value={billDate}
                onChange={(e) => setBillDate(e.target.value)}
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              />
            </div>
            <div className="space-y-2">
              <label htmlFor="due-date" className="text-sm font-medium">Due Date</label>
              <input
                id="due-date"
                type="date"
                value={dueDate}
                onChange={(e) => {
                  setDueDate(e.target.value)
                  if (e.target.value) {
                    setFieldErrors(prev => {
                      const next = { ...prev }
                      delete next.dueDate
                      return next
                    })
                  }
                }}
                className={`w-full rounded-md border px-3 py-2 text-sm ${
                  fieldErrors.dueDate ? 'border-red-500' : 'border-neutral-300'
                }`}
              />
              {fieldErrors.dueDate && (
                <p className="text-sm text-red-600">{fieldErrors.dueDate}</p>
              )}
            </div>
          </div>

          <div className="space-y-2">
            <label htmlFor="bill-memo" className="text-sm font-medium">Memo</label>
            <input
              id="bill-memo"
              type="text"
              value={memo}
              onChange={(e) => setMemo(e.target.value)}
              placeholder="Optional memo"
              className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
            />
          </div>

          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <h3 className="font-medium">Line Items</h3>
              <Button variant="outline" size="sm" onClick={addLine}>
                <Plus className="h-4 w-4 mr-2" />
                Add Line
              </Button>
            </div>

            {lines.map((line, index) => (
              <div key={index} className="grid gap-3 md:grid-cols-12 items-start">
                <div className="md:col-span-5">
                  <select
                    aria-label={`Line ${index + 1} expense account`}
                    value={line.account_id}
                    onChange={(e) => updateLine(index, 'account_id', e.target.value)}
                    className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                  >
                    <option value="">Select expense account...</option>
                    {expenseAccounts.map(acc => (
                      <option key={acc.id} value={acc.id}>
                        {acc.code} - {acc.name}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="md:col-span-2">
                  <input
                    aria-label={`Line ${index + 1} amount`}
                    type="number"
                    step="0.01"
                    value={line.amount}
                    onChange={(e) => updateLine(index, 'amount', e.target.value)}
                    placeholder="Amount $"
                    className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                  />
                </div>
                <div className="md:col-span-4">
                  <input
                    aria-label={`Line ${index + 1} description`}
                    type="text"
                    value={line.description}
                    onChange={(e) => updateLine(index, 'description', e.target.value)}
                    placeholder="Description (optional)"
                    className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                  />
                </div>
                <div className="md:col-span-1">
                  {lines.length > 1 && (
                    <Button
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
            ))}
          </div>

          <div className="border-t pt-4">
            <div className="flex justify-between text-sm font-medium">
              <span>Total:</span>
              <span>{formatCurrency(Math.round(totalAmount * 100))}</span>
            </div>
          </div>

          <div className="flex gap-3">
            <Button
              onClick={handleSave}
              disabled={saving || !vendorId || !billNumber || !lines.filter(l => l.account_id && l.amount).length}
            >
              {saving ? 'Saving...' : 'Save Bill'}
            </Button>
            <Button variant="ghost" onClick={() => router.back()}>
              Cancel
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
