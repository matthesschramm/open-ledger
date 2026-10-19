'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { ArrowLeft, Plus, Trash2 } from 'lucide-react'
import { getLocalDateString, formatDate, companyToday } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default function NewInvoicePage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [orgId, setOrgId] = useState<string | null>(null)
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [orgTimezone, setOrgTimezone] = useState<string>('America/New_York')
  const [contacts, setContacts] = useState<any[]>([])
  const [revenueAccounts, setRevenueAccounts] = useState<any[]>([])
  
  const [customerId, setCustomerId] = useState('')
  const [invoiceNumber, setInvoiceNumber] = useState('')
  const [invoiceDate, setInvoiceDate] = useState('')
  const [dueDate, setDueDate] = useState('')
  const [memo, setMemo] = useState('')
  const [statusChoice, setStatusChoice] = useState<'Quote' | 'Draft'>('Draft')
  const [lines, setLines] = useState<any[]>([
    { account_id: '', amount: '', description: '' },
  ])
  const [saving, setSaving] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [dueDateError, setDueDateError] = useState('')

  useEffect(() => {
    checkAuthAndLoad()
  }, [])

  async function checkAuthAndLoad() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }
    await loadData()
  }

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
    setInvoiceDate(today)

    const { data: contactsData } = await supabase
      .from('contacts')
      .select('*')
      .eq('is_active', true)
      .eq('type', 'Customer')
      .order('name')
    if (contactsData) setContacts(contactsData)

    const { data: accountsData } = await supabase
      .from('accounts')
      .select('*')
      .eq('type', 'Revenue')
      .eq('is_active', true)
      .eq('is_header', false)
      .order('code')
    if (accountsData) setRevenueAccounts(accountsData)
    
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
    if (!orgId) return
    setSaving(true)
    setError(null)
    setDueDateError('')

    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      if (statusChoice === 'Draft' && !dueDate) {
        setDueDateError('Add a due date.')
        setSaving(false)
        return
      }

      let finalInvoiceNumber = invoiceNumber.trim()
      
      if (!finalInvoiceNumber) {
        const currentYear = new Date().getFullYear()
        const { count } = await supabase
          .from('invoices')
          .select('*', { count: 'exact', head: true })
          .eq('organization_id', orgId)
        
        finalInvoiceNumber = `INV-${currentYear}-${String((count || 0) + 1).padStart(4, '0')}`
      }

      const { data: invoice, error: invoiceError } = await supabase
        .from('invoices')
        .insert({
          organization_id: orgId,
          customer_id: customerId,
          number: finalInvoiceNumber,
          invoice_date: invoiceDate,
          due_date: dueDate || null,
          total_cents: Math.round(totalAmount * 100),
          status: statusChoice,
          notes: memo || null,
          created_by: user.id,
        })
        .select()
        .single()

      if (invoiceError) throw invoiceError

      const invoiceLines = lines
        .filter(l => l.account_id && l.amount)
        .map((line, idx) => ({
          organization_id: orgId,
          invoice_id: invoice.id,
          account_id: line.account_id,
          line_number: idx + 1,
          amount_cents: Math.round((parseFloat(line.amount) || 0) * 100),
          description: line.description || '',
        }))

      const { error: linesError } = await supabase
        .from('invoice_lines')
        .insert(invoiceLines)

      if (linesError) throw linesError

      if (statusChoice === 'Draft') {
        const { data: postResult, error: postError } = await supabase.rpc('post_invoice', {
          p_invoice_id: invoice.id,
        })

        if (postError) throw postError
        if (postResult && !postResult.success) {
          setError(postResult.error)
          setSaving(false)
          return
        }
      }

      router.push(`/invoices/${invoice.id}`)
    } catch (err: any) {
      setError(err.message || 'Failed to save invoice')
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
        <p className="text-neutral-600">You don't have permission to create invoices.</p>
      </div>
    )
  }

  return (
    <div className="p-8">
      <div className="mb-8">
        <h1 className="text-3xl font-semibold tracking-tight">New Invoice</h1>
        <p className="text-muted-foreground">Create a customer invoice</p>
      </div>

      {error && (
        <div className="mb-4 p-4 rounded-md bg-red-50 text-red-800 border border-red-200">
          <p className="text-sm font-medium">{error}</p>
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Invoice Details</CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-2">
              <label htmlFor="invoice-customer" className="text-sm font-medium">Customer</label>
              <select
                id="invoice-customer"
                value={customerId}
                onChange={(e) => setCustomerId(e.target.value)}
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              >
                <option value="">Select customer...</option>
                {contacts.map(contact => (
                  <option key={contact.id} value={contact.id}>
                    {contact.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <label htmlFor="invoice-number" className="text-sm font-medium">Invoice Number</label>
              <input
                id="invoice-number"
                type="text"
                value={invoiceNumber}
                onChange={(e) => setInvoiceNumber(e.target.value)}
                placeholder="INV-2026-0001 (auto if blank)"
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              />
            </div>
            <div className="space-y-2">
              <label htmlFor="invoice-date" className="text-sm font-medium">Invoice Date</label>
              <input
                id="invoice-date"
                type="date"
                value={invoiceDate}
                onChange={(e) => setInvoiceDate(e.target.value)}
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
                  setDueDateError('')
                }}
                className={`w-full rounded-md border px-3 py-2 text-sm ${dueDateError ? 'border-red-500' : 'border-neutral-300'}`}
              />
              {dueDateError && (
                <p className="text-sm text-red-600">{dueDateError}</p>
              )}
            </div>
            <div className="space-y-2">
              <label htmlFor="invoice-status" className="text-sm font-medium">Status</label>
              <select
                id="invoice-status"
                value={statusChoice}
                onChange={(e) => setStatusChoice(e.target.value as 'Quote' | 'Draft')}
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
              >
                <option value="Draft">Invoice (post journal)</option>
                <option value="Quote">Quote (no journal)</option>
              </select>
            </div>
          </div>

          <div className="space-y-2">
            <label htmlFor="invoice-memo" className="text-sm font-medium">Notes</label>
            <input
              id="invoice-memo"
              type="text"
              value={memo}
              onChange={(e) => setMemo(e.target.value)}
              placeholder="Optional notes"
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
                    aria-label={`Line ${index + 1} revenue account`}
                    value={line.account_id}
                    onChange={(e) => updateLine(index, 'account_id', e.target.value)}
                    className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                  >
                    <option value="">Select revenue account...</option>
                    {revenueAccounts.map(acc => (
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
                    placeholder="Description"
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
              disabled={saving || !customerId || !lines.filter(l => l.account_id && l.amount).length}
            >
              {saving ? 'Saving...' : `Save ${statusChoice === 'Quote' ? 'Quote' : 'Invoice'}`}
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
