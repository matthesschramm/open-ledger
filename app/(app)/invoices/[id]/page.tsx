'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter, useParams } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { ArrowLeft, ExternalLink } from 'lucide-react'
import { getLocalDateString, formatDate, companyToday } from '@/lib/format-date'
import { formatInvoiceNumber } from '@/lib/format-invoice'
import { formatCurrency } from '@/lib/money'
import Link from 'next/link'

function formatLongDate(dateStr: string): string {
  // Format yyyy-mm-dd as "Mon D, YYYY"
  try {
    const [year, month, day] = dateStr.split('-').map(Number)
    const date = new Date(Date.UTC(year, month - 1, day))
    return new Intl.DateTimeFormat('en-US', { 
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      timeZone: 'UTC'
    }).format(date)
  } catch {
    return dateStr
  }
}

export default function InvoiceDetailPage() {
  const router = useRouter()
  const params = useParams()
  const invoiceId = params.id as string
  const supabase = createClient()
  
  const [invoice, setInvoice] = useState<any>(null)
  const [customer, setCustomer] = useState<any>(null)
  const [lines, setLines] = useState<any[]>([])
  const [receipts, setReceipts] = useState<any[]>([])
  const [cashAccounts, setCashAccounts] = useState<any[]>([])
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [orgTimezone, setOrgTimezone] = useState<string>('America/New_York')
  const [lockDate, setLockDate] = useState<string | null>(null)
  
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [processing, setProcessing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)
  const [showReceiptForm, setShowReceiptForm] = useState(false)
  const [showCreditForm, setShowCreditForm] = useState(false)
  const [showWriteOffForm, setShowWriteOffForm] = useState(false)

  const [receiptDate, setReceiptDate] = useState('')
  const [receiptAmount, setReceiptAmount] = useState('')
  const [cashAccountId, setCashAccountId] = useState('')
  const [receiptNotes, setReceiptNotes] = useState('')

  const [creditDate, setCreditDate] = useState('')
  const [creditAmount, setCreditAmount] = useState('')
  const [creditReason, setCreditReason] = useState('')

  const [writeOffDate, setWriteOffDate] = useState('')
  const [writeOffAmount, setWriteOffAmount] = useState('')
  const [writeOffReason, setWriteOffReason] = useState('')

  const [showSendDialog, setShowSendDialog] = useState(false)
  const [sendToEmail, setSendToEmail] = useState('')
  const [lastSent, setLastSent] = useState<{ date: string; email: string } | null>(null)
  const [downloadingPdf, setDownloadingPdf] = useState(false)
  const [showVoidDialog, setShowVoidDialog] = useState(false)
  const [voiding, setVoiding] = useState(false)
  const [customerCredit, setCustomerCredit] = useState<any>(null)
  const [availableCredits, setAvailableCredits] = useState<any[]>([])
  const [applyingCredit, setApplyingCredit] = useState(false)
  const [showApplyCreditDialog, setShowApplyCreditDialog] = useState(false)
  const [applyCreditId, setApplyCreditId] = useState<string | null>(null)
  const [applyCreditMax, setApplyCreditMax] = useState(0)
  const [applyAmount, setApplyAmount] = useState('')
  const [applyIdempotencyKey, setApplyIdempotencyKey] = useState<string | null>(null)
  
  const [showReminderDialog, setShowReminderDialog] = useState(false)
  const [reminderToEmail, setReminderToEmail] = useState('')
  const [lastReminded, setLastReminded] = useState<{ date: string; email: string } | null>(null)

  function formatLockDate(dateStr: string | null): string {
    if (!dateStr) return 'the lock date'
    try {
      // Parse yyyy-mm-dd without UTC shift - use Date.UTC
      const [year, month, day] = dateStr.split('-').map(Number)
      const date = new Date(Date.UTC(year, month - 1, day))
      return new Intl.DateTimeFormat('en-US', { 
        month: 'short', 
        day: 'numeric', 
        year: 'numeric',
        timeZone: 'UTC'
      }).format(date)
    } catch {
      return dateStr
    }
  }

  function getCompanyLocalDate(): string {
    const now = new Date()
    const localDate = new Intl.DateTimeFormat('en-CA', { 
      timeZone: orgTimezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    }).format(now)
    
    // Format as "14 Oct 2026" - use Date.UTC to avoid shifts
    const [year, month, day] = localDate.split('-').map(Number)
    const date = new Date(Date.UTC(year, month - 1, day))
    return new Intl.DateTimeFormat('en-US', { 
      day: 'numeric',
      month: 'short', 
      year: 'numeric',
      timeZone: 'UTC'
    }).format(date)
  }

  useEffect(() => {
    if (invoiceId) {
      checkAuthAndLoad()
    }
  }, [invoiceId])

  async function checkAuthAndLoad() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }
    await loadInvoice()
  }

  async function loadInvoice() {
    setLoading(true)
    setLoadError(null)

    try {
      const { data: roleData } = await supabase.rpc('current_role')
      setCurrentRole(roleData)

      const { data: orgData } = await supabase
        .from('organizations')
        .select('timezone')
        .single()
      
      if (orgData?.timezone) {
        setOrgTimezone(orgData.timezone)
      }

      // Get the most recent locked period end date
      // Owners can post to soft-closed periods, so only check Locked for them
      const periodStatuses = roleData === 'owner' ? ['Locked'] : ['Locked', 'Soft-closed']
      const { data: periodsData } = await supabase
        .from('accounting_periods')
        .select('end_date')
        .in('status', periodStatuses)
        .order('end_date', { ascending: false })
        .limit(1)
        .maybeSingle()
      
      if (periodsData?.end_date) {
        setLockDate(periodsData.end_date)
      }

      // Fetch invoice first (no embeds)
      const { data: invoiceData, error: invoiceError } = await supabase
        .from('invoices')
        .select('*')
        .eq('id', invoiceId)
        .single()

      if (invoiceError) {
        if (invoiceError.code === 'PGRST116') {
          setLoadError('Invoice not found.')
        } else {
          setLoadError(invoiceError.message || 'Failed to load invoice.')
        }
        setLoading(false)
        return
      }

      if (!invoiceData) {
        setLoadError('Invoice not found.')
        setLoading(false)
        return
      }

      setInvoice(invoiceData)

      // Fetch customer separately
      if (invoiceData.customer_id) {
        const { data: customerData } = await supabase
          .from('contacts')
          .select('name, email')
          .eq('id', invoiceData.customer_id)
          .single()

        if (customerData) {
          setCustomer(customerData)
        }
      }

      const remaining = invoiceData.total_cents - invoiceData.received_cents
      setReceiptAmount((remaining / 100).toFixed(2))
      setCreditAmount((remaining / 100).toFixed(2))
      setWriteOffAmount((remaining / 100).toFixed(2))

      // Fetch lines separately
      const { data: linesData } = await supabase
        .from('invoice_lines')
        .select('*')
        .eq('invoice_id', invoiceId)
        .order('line_number')

      if (linesData) {
        // Fetch accounts for lines separately
        const accountIds = linesData.map(l => l.account_id)
        const { data: accountsData } = await supabase
          .from('accounts')
          .select('id, code, name')
          .in('id', accountIds)

        if (accountsData) {
          const accountsMap = new Map(accountsData.map(a => [a.id, a]))
          const linesWithAccounts = linesData.map(line => ({
            ...line,
            account: accountsMap.get(line.account_id)
          }))
          setLines(linesWithAccounts)
        } else {
          setLines(linesData)
        }
      }

      // Fetch receipts
      const { data: receiptsData } = await supabase
        .from('invoice_receipts')
        .select('*')
        .eq('invoice_id', invoiceId)
        .order('receipt_date', { ascending: false })

      if (receiptsData) setReceipts(receiptsData)

      // Fetch last send
      const { data: lastSendData } = await supabase
        .from('invoice_sends')
        .select('sent_at, sent_to_email')
        .eq('invoice_id', invoiceId)
        .order('sent_at', { ascending: false })
        .limit(1)
        .maybeSingle()

      if (lastSendData) {
        setLastSent({ date: lastSendData.sent_at, email: lastSendData.sent_to_email })
      }

      // Fetch last reminder
      const { data: lastReminderData } = await supabase
        .from('invoice_reminders')
        .select('reminded_at, reminded_to_email')
        .eq('invoice_id', invoiceId)
        .order('reminded_at', { ascending: false })
        .limit(1)
        .maybeSingle()

      if (lastReminderData) {
        setLastReminded({ date: lastReminderData.reminded_at, email: lastReminderData.reminded_to_email })
      }

      // Fetch cash accounts
      const { data: cashData } = await supabase
        .from('accounts')
        .select('*')
        .eq('is_cash', true)
        .eq('is_active', true)
        .order('code')

      if (cashData) setCashAccounts(cashData)

      // Load customer credit if voided
      if (invoiceData && invoiceData.status === 'Void') {
        const { data: creditData } = await supabase
          .from('customer_credits')
          .select('*')
          .eq('source_invoice_id', invoiceId)
          .eq('status', 'open')
          .maybeSingle()

        if (creditData) setCustomerCredit(creditData)
      }

      // Load available credits for this customer
      // Always call setAvailableCredits; use [] unless status is Posted
      if (invoiceData && invoiceData.customer_id && invoiceData.status === 'Posted') {
        const { data: creditsData } = await supabase
          .from('customer_credits')
          .select('*, invoices!customer_credits_source_invoice_id_fkey(number)')
          .eq('contact_id', invoiceData.customer_id)
          .eq('status', 'open')
          .gt('remaining_cents', 0)
          .order('created_at')

        setAvailableCredits(creditsData || [])
      } else {
        setAvailableCredits([])
      }

      setLoading(false)
    } catch (err: any) {
      setLoadError(err.message || 'Failed to load invoice.')
      setLoading(false)
    }
  }

  async function handleRecordReceipt() {
    if (!cashAccountId || !receiptAmount) return
    
    setProcessing(true)
    setError(null)
    setSuccess(null)
    try {
      const amountCents = Math.round(parseFloat(receiptAmount) * 100)

      const { data, error: rpcError } = await supabase.rpc('record_receipt', {
        p_invoice_id: invoiceId,
        p_receipt_date: receiptDate,
        p_amount_cents: amountCents,
        p_cash_account_id: cashAccountId,
        p_notes: receiptNotes || null,
      })

      if (rpcError) {
        const msg = rpcError.message || ''
        if (msg.includes('is Locked') || msg.includes('is Soft-closed')) {
          setError(msg)
        } else {
          setError('Could not record receipt — try again')
        }
        return
      }

      if (data && !data.success) {
        const errorMsg = data.error || ''
        if (errorMsg.includes('is Locked') || errorMsg.includes('is Soft-closed')) {
          setError(errorMsg)
        } else {
          setError('Could not record receipt — try again')
        }
      } else {
        setSuccess('Receipt recorded successfully')
        setShowReceiptForm(false)
        await loadInvoice()
      }
    } catch (err: any) {
      setError('Could not record receipt — try again')
    } finally {
      setProcessing(false)
    }
  }

  async function handleOpenVoidDialog() {
    setShowVoidDialog(true)
  }

  async function handleVoidInvoice() {
    if (!invoiceId) return

    setVoiding(true)
    setShowVoidDialog(false)
    setError(null)
    setSuccess(null)
    try {
      // Compute company-local date
      const now = new Date()
      const localDate = new Intl.DateTimeFormat('en-CA', { 
        timeZone: orgTimezone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit'
      }).format(now)

      const { data, error: rpcError } = await supabase.rpc('void_invoice', {
        p_invoice_id: invoiceId,
        p_void_date: localDate,
      })

      if (rpcError) {
        // Parse error codes for friendly messages
        if (rpcError.message.includes('PERIOD_LOCKED:')) {
          setError(`This date is in a locked period. Choose a date after ${formatLockDate(lockDate)}.`)
        } else {
          setError(rpcError.message || 'Could not void invoice — try again')
        }
        return
      }

      if (data && !data.success) {
        // Map error codes to friendly messages
        if (data?.error_code === 'PERIOD_LOCKED') {
          setError(`This date is in a locked period. Choose a date after ${formatLockDate(lockDate)}.`)
        } else if (data?.error_code === 'INSUFFICIENT_PERMISSIONS') {
          setError('You don\'t have permission to void this invoice.')
        } else {
          setError(data?.error || 'Could not void invoice — try again')
        }
      } else {
        // Refetch the invoice to update UI in place
        await loadInvoice()
        // Force Next.js to refresh router cache so UI updates immediately
        router.refresh()
      }
    } catch (err: any) {
      setError('Could not void invoice — try again')
    } finally {
      setVoiding(false)
    }
  }

  function handleOpenApplyDialog(creditId: string, creditRemaining: number) {
    if (!invoice) return
    const invoiceOpenBalance = invoice.total_cents - invoice.received_cents
    const maxApply = Math.min(creditRemaining, invoiceOpenBalance)
    
    setApplyCreditId(creditId)
    setApplyCreditMax(maxApply)
    setApplyAmount((maxApply / 100).toFixed(2))
    setApplyIdempotencyKey(crypto.randomUUID())
    setShowApplyCreditDialog(true)
  }

  async function handleApplyCredit() {
    if (!invoiceId || !applyCreditId) return

    const amountCents = Math.round(parseFloat(applyAmount) * 100)
    if (isNaN(amountCents) || amountCents <= 0) return

    setApplyingCredit(true)
    setShowApplyCreditDialog(false)
    setError(null)
    setSuccess(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('apply_customer_credit', {
        p_credit_id: applyCreditId,
        p_invoice_id: invoiceId,
        p_amount_cents: amountCents,
        p_idempotency_key: applyIdempotencyKey,
      })

      if (rpcError) {
        // Parse exception error codes for friendly messages
        if (rpcError.message.includes('PERIOD_LOCKED:')) {
          setError(`This date is in a locked period. Choose a date after ${formatLockDate(lockDate)}.`)
        } else if (rpcError.message.includes('INSUFFICIENT_BALANCE:')) {
          const msg = rpcError.message.replace('INSUFFICIENT_BALANCE:', '').trim()
          setError(msg)
        } else if (rpcError.message.includes('VALIDATION_ERROR:')) {
          const msg = rpcError.message.replace('VALIDATION_ERROR:', '').trim()
          setError(msg)
        } else if (rpcError.message.includes('INVALID_STATUS:')) {
          const msg = rpcError.message.replace('INVALID_STATUS:', '').trim()
          setError(msg)
        } else {
          setError(rpcError.message || 'Could not apply credit — try again')
        }
        return
      }

      if (data && !data.success) {
        // Map error codes to friendly messages
        if (data?.error_code === 'PERIOD_LOCKED') {
          setError(`This date is in a locked period. Choose a date after ${formatLockDate(lockDate)}.`)
        } else if (data?.error_code === 'INSUFFICIENT_PERMISSIONS') {
          setError('You don\'t have permission to apply this credit.')
        } else {
          setError(data?.error || 'Could not apply credit — try again')
        }
      } else {
        setSuccess('Credit applied successfully')
        await loadInvoice()
      }
    } catch (err: any) {
      setError('Could not apply credit — try again')
    } finally {
      setApplyingCredit(false)
    }
  }

  async function handleIssueCreditNote() {
    if (!creditAmount || !creditReason) return
    
    setProcessing(true)
    setError(null)
    setSuccess(null)
    try {
      const amountCents = Math.round(parseFloat(creditAmount) * 100)

      const { data, error: rpcError } = await supabase.rpc('issue_credit_note', {
        p_invoice_id: invoiceId,
        p_credit_date: creditDate,
        p_amount_cents: amountCents,
        p_reason: creditReason,
      })

      if (rpcError) {
        const msg = rpcError.message || ''
        if (msg.includes('is Locked') || msg.includes('is Soft-closed')) {
          setError(msg)
        } else {
          setError('Could not issue credit note — try again')
        }
        return
      }

      if (data && !data.success) {
        const errorMsg = data.error || ''
        if (errorMsg.includes('is Locked') || errorMsg.includes('is Soft-closed')) {
          setError(errorMsg)
        } else {
          setError('Could not issue credit note — try again')
        }
      } else {
        setSuccess('Credit note issued successfully')
        setShowCreditForm(false)
        await loadInvoice()
      }
    } catch (err: any) {
      setError('Could not issue credit note — try again')
    } finally {
      setProcessing(false)
    }
  }

  async function handleWriteOff() {
    if (!writeOffAmount || !writeOffReason) return
    
    setProcessing(true)
    setError(null)
    setSuccess(null)
    try {
      const amountCents = Math.round(parseFloat(writeOffAmount) * 100)

      const { data, error: rpcError } = await supabase.rpc('write_off_invoice', {
        p_invoice_id: invoiceId,
        p_write_off_date: writeOffDate,
        p_amount_cents: amountCents,
        p_reason: writeOffReason,
      })

      if (rpcError) {
        const msg = rpcError.message || ''
        if (msg.includes('is Locked') || msg.includes('is Soft-closed')) {
          setError(msg)
        } else {
          setError('Could not write off invoice — try again')
        }
        return
      }

      if (data && !data.success) {
        const errorMsg = data.error || ''
        if (errorMsg.includes('is Locked') || errorMsg.includes('is Soft-closed')) {
          setError(errorMsg)
        } else {
          setError('Could not write off invoice — try again')
        }
      } else {
        setSuccess('Invoice written off successfully')
        setShowWriteOffForm(false)
        await loadInvoice()
      }
    } catch (err: any) {
      setError('Could not write off invoice — try again')
    } finally {
      setProcessing(false)
    }
  }

  async function handleOpenReminderDialog() {
    setReminderToEmail(customer?.email || '')
    setShowReminderDialog(true)
    setError(null)
    setSuccess(null)
  }

  async function handleSendReminder() {
    if (!invoice || !reminderToEmail.trim()) return
    
    setProcessing(true)
    setError(null)
    setSuccess(null)
    setShowReminderDialog(false)
    
    try {
      const response = await fetch(`/api/v1/invoices/${invoiceId}/reminder`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          to: reminderToEmail.trim(),
        }),
      })

      const data = await response.json()

      if (!response.ok) {
        if (response.status === 503) {
          setError('Email service not configured. Contact support.')
        } else if (data?.error?.message) {
          const errorMsg = data.error.message
          if (errorMsg.includes('email') || errorMsg.includes('Add an email')) {
            setError('Add an email on the customer before sending.')
          } else if (errorMsg.includes('organization details') || errorMsg.includes('legal name') || errorMsg.includes('Add organization')) {
            setError('Add organization details in Settings before sending.')
          } else if (errorMsg.includes('Post the invoice')) {
            setError('Post the invoice before sending.')
          } else if (errorMsg.includes('paid in full')) {
            setError('Invoice is paid in full.')
          } else if (errorMsg.includes('Quotes') || errorMsg.includes('quote')) {
            setError('Quotes aren\'t sent as invoices.')
          } else {
            setError('Couldn\'t send reminder — try again')
          }
        } else {
          setError('Couldn\'t send reminder — try again')
        }
      } else {
        setSuccess(`Reminder sent to ${reminderToEmail.trim()}`)
        setLastReminded({ date: new Date().toISOString(), email: reminderToEmail.trim() })
        await loadInvoice()
      }
    } catch (err: any) {
      console.error('Send reminder error:', err)
      setError('Couldn\'t send reminder — try again')
    } finally {
      setProcessing(false)
    }
  }

  async function handleOpenSendDialog() {
    setSendToEmail(customer?.email || '')
    setShowSendDialog(true)
    setError(null)
    setSuccess(null)
  }

  async function handleSendInvoice() {
    if (!invoice || !sendToEmail.trim()) return
    
    setProcessing(true)
    setError(null)
    setSuccess(null)
    setShowSendDialog(false)
    
    try {
      const response = await fetch(`/api/v1/invoices/${invoiceId}/send`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          to: sendToEmail.trim(),
        }),
      })

      const data = await response.json()

      if (!response.ok) {
        if (response.status === 503) {
          setError('Email service not configured. Contact support.')
        } else if (data?.error?.message) {
          const errorMsg = data.error.message
          if (errorMsg.includes('email') || errorMsg.includes('Add an email')) {
            setError('Add an email on the customer before sending.')
          } else if (errorMsg.includes('organization details') || errorMsg.includes('legal name') || errorMsg.includes('Add organization')) {
            setError('Add organization details in Settings before sending.')
          } else if (errorMsg.includes('Post the invoice')) {
            setError('Post the invoice before sending.')
          } else if (errorMsg.includes('Quotes') || errorMsg.includes('quote')) {
            setError('Quotes aren\'t sent as invoices.')
          } else {
            setError('Couldn\'t send invoice — try again')
          }
        } else {
          setError('Couldn\'t send invoice — try again')
        }
      } else {
        setSuccess(`Invoice sent to ${sendToEmail.trim()}`)
        setLastSent({ date: new Date().toISOString(), email: sendToEmail.trim() })
        await loadInvoice()
      }
    } catch (err: any) {
      console.error('Send invoice error:', err)
      setError('Couldn\'t send invoice — try again')
    } finally {
      setProcessing(false)
    }
  }

  async function handleDownloadPdf() {
    if (!invoice) return
    
    setDownloadingPdf(true)
    try {
      const response = await fetch(`/api/v1/invoices/${invoiceId}/pdf`)
      
      if (!response.ok) {
        throw new Error('Failed to generate PDF')
      }
      
      const blob = await response.blob()
      const url = window.URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `${formatInvoiceNumber(invoice.number, invoice.invoice_date)}.pdf`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      window.URL.revokeObjectURL(url)
    } catch (err: any) {
      console.error('Download PDF error:', err)
      setError('Couldn\'t download PDF — try again')
    } finally {
      setDownloadingPdf(false)
    }
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  if (loadError) {
    return (
      <div className="p-8">
        <Button variant="ghost" onClick={() => router.back()} className="mb-4">
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back
        </Button>
        <div className="p-4 rounded-md bg-red-50 text-red-800 border border-red-200">
          <p className="text-sm font-medium">{loadError}</p>
        </div>
      </div>
    )
  }

  if (!invoice) {
    return (
      <div className="p-8">
        <Button variant="ghost" onClick={() => router.back()} className="mb-4">
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back
        </Button>
        <div className="p-4 rounded-md bg-red-50 text-red-800 border border-red-200">
          <p className="text-sm font-medium">Invoice not found.</p>
        </div>
      </div>
    )
  }

  const remaining = invoice.status === 'Void' ? 0 : ((invoice.total_cents - invoice.received_cents) / 100)
  const receivedCents = invoice.received_cents

  const canModify = currentRole && ['owner', 'bookkeeper'].includes(currentRole)
  const canRecordReceipt = canModify && (invoice.status === 'Posted' || invoice.status === 'Paid')
  const canIssueCredit = canModify && (invoice.status === 'Posted' || invoice.status === 'Paid')
  const canWriteOff = canModify && (invoice.status === 'Posted' || invoice.status === 'Paid')
  const canSend = canModify && (invoice.status === 'Posted' || invoice.status === 'Paid')
  const canSendReminder = canModify && (invoice.status === 'Posted' || invoice.status === 'Paid') && remaining > 0
  const canVoid = canModify && (invoice.status === 'Posted' || invoice.status === 'Paid')

  return (
    <div className="p-8">
      <div className="mb-8">
        <Button variant="ghost" onClick={() => router.back()} className="mb-4">
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back
        </Button>

        {error && (
          <div className="mb-4 p-4 rounded-md bg-red-50 text-red-800 border border-red-200">
            <p className="text-sm font-medium">{error}</p>
          </div>
        )}

        {success && (
          <div className="mb-4 p-4 rounded-md bg-green-50 text-green-800 border border-green-200">
            <p className="text-sm font-medium">{success}</p>
          </div>
        )}

        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">{formatInvoiceNumber(invoice.number, invoice.invoice_date)}</h1>
            <p className="text-muted-foreground">{customer?.name || '—'}</p>
            {lastSent && (
              <div className="flex items-center gap-3 mt-1">
                <p className="text-sm text-muted-foreground">
                  Last sent {formatDate(lastSent.date.split('T')[0])} to {lastSent.email}
                </p>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={handleDownloadPdf}
                  disabled={downloadingPdf}
                  className="h-7 px-2 text-xs"
                >
                  {downloadingPdf ? 'Downloading...' : 'Download PDF'}
                </Button>
              </div>
            )}
            {lastReminded && (
              <p className="text-sm text-muted-foreground mt-1">
                Last reminded {formatDate(lastReminded.date.split('T')[0])} to {lastReminded.email}
              </p>
            )}
          </div>
          <Badge variant={
            invoice.status === 'Paid' ? 'default' :
            invoice.status === 'Posted' ? 'outline' :
            invoice.status === 'Void' ? 'secondary' : 'outline'
          }>
            {invoice.status === 'Void' ? 'Voided' : invoice.status}
          </Badge>
        </div>
        {invoice.status === 'Void' && customerCredit && (
          <div className="mt-4 p-4 rounded-md bg-blue-50 border border-blue-200">
            <p className="text-sm text-blue-900">
              Invoice voided. {formatCurrency(customerCredit.remaining_cents)} kept as{' '}
              <Link href={`/contacts/${invoice.customer_id}`} className="underline font-medium">
                customer credit
              </Link>
            </p>
          </div>
        )}
      </div>

      <div className="grid gap-6 md:grid-cols-2 mb-6">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Invoice Total
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-semibold tabular-nums">
              {formatCurrency(invoice.total_cents)}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Amount Due
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-semibold tabular-nums">
              {formatCurrency(Math.round(remaining * 100))}
            </div>
          </CardContent>
        </Card>
      </div>

      <Card className="mb-6">
        <CardHeader>
          <CardTitle>Invoice Details</CardTitle>
          <CardDescription>
            Invoice date: {formatDate(invoice.invoice_date)}
            {invoice.due_date && ` · Due: ${formatDate(invoice.due_date)}`}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {invoice.notes && (
            <p className="text-sm text-muted-foreground mb-4">{invoice.notes}</p>
          )}
          
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Account</TableHead>
                <TableHead>Description</TableHead>
                <TableHead className="text-right">Amount</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {lines.map((line: any) => (
                <TableRow key={line.id}>
                  <TableCell className="font-mono text-sm">
                    {line.account ? `${line.account.code} - ${line.account.name}` : '—'}
                  </TableCell>
                  <TableCell className="text-sm">{line.description || '—'}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatCurrency(line.amount_cents)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {availableCredits.length > 0 && (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Available Credits</CardTitle>
            <CardDescription>
              {availableCredits.length} customer credit{availableCredits.length > 1 ? 's' : ''} available
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Source Invoice</TableHead>
                  <TableHead className="text-right">Available</TableHead>
                  <TableHead className="text-right">Action</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {availableCredits.map((credit: any) => (
                  <TableRow key={credit.id}>
                    <TableCell className="text-sm">{credit.invoices?.number || '—'}</TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatCurrency(credit.remaining_cents)}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handleOpenApplyDialog(credit.id, credit.remaining_cents)}
                        disabled={applyingCredit}
                      >
                        Apply
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}

      {receipts.length > 0 && (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Receipts</CardTitle>
            <CardDescription>{receipts.length} receipt(s) recorded</CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Date</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                  <TableHead>Notes</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {receipts.map((receipt: any) => {
                  let displayType = receipt.receipt_type
                  if (receipt.receipt_type === 'credit_note') {
                    displayType = 'Customer credit'
                  } else if (receipt.receipt_type === 'payment') {
                    displayType = 'Payment'
                  } else if (receipt.receipt_type === 'write_off') {
                    displayType = 'Write off'
                  }
                  return (
                    <TableRow key={receipt.id}>
                      <TableCell>{formatDate(receipt.receipt_date)}</TableCell>
                      <TableCell>{displayType}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatCurrency(receipt.amount_cents)}
                      </TableCell>
                      <TableCell className="text-sm text-muted-foreground">
                        {receipt.notes || '—'}
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}

      {showReceiptForm ? (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Record Receipt</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <label className="text-sm font-medium">Receipt Date</label>
                <input
                  type="date"
                  value={receiptDate}
                  onChange={(e) => setReceiptDate(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium">Amount</label>
                <input
                  type="number"
                  step="0.01"
                  value={receiptAmount}
                  onChange={(e) => setReceiptAmount(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2 md:col-span-2">
                <label className="text-sm font-medium">Deposit To</label>
                <select
                  value={cashAccountId}
                  onChange={(e) => setCashAccountId(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                >
                  <option value="">Select cash account...</option>
                  {cashAccounts.map(acc => (
                    <option key={acc.id} value={acc.id}>
                      {acc.code} - {acc.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-2 md:col-span-2">
                <label className="text-sm font-medium">Notes (optional)</label>
                <input
                  type="text"
                  value={receiptNotes}
                  onChange={(e) => setReceiptNotes(e.target.value)}
                  placeholder="Payment reference"
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
            </div>
            
            <div className="flex gap-3">
              <Button onClick={handleRecordReceipt} disabled={processing || !cashAccountId || !receiptAmount}>
                {processing ? 'Processing...' : 'Record Receipt'}
              </Button>
              <Button variant="ghost" onClick={() => setShowReceiptForm(false)}>
                Cancel
              </Button>
            </div>
          </CardContent>
        </Card>
      ) : showCreditForm ? (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Issue Credit Note</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <label className="text-sm font-medium">Credit Date</label>
                <input
                  type="date"
                  value={creditDate}
                  onChange={(e) => setCreditDate(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium">Amount</label>
                <input
                  type="number"
                  step="0.01"
                  value={creditAmount}
                  onChange={(e) => setCreditAmount(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2 md:col-span-2">
                <label className="text-sm font-medium">Reason</label>
                <input
                  type="text"
                  value={creditReason}
                  onChange={(e) => setCreditReason(e.target.value)}
                  placeholder="Service adjustment, discount, etc."
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
            </div>
            
            <div className="flex gap-3">
              <Button onClick={handleIssueCreditNote} disabled={processing || !creditAmount || !creditReason}>
                {processing ? 'Processing...' : 'Issue Credit Note'}
              </Button>
              <Button variant="ghost" onClick={() => setShowCreditForm(false)}>
                Cancel
              </Button>
            </div>
          </CardContent>
        </Card>
      ) : showWriteOffForm ? (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Write Off Invoice</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <label className="text-sm font-medium">Write-off Date</label>
                <input
                  type="date"
                  value={writeOffDate}
                  onChange={(e) => setWriteOffDate(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium">Amount</label>
                <input
                  type="number"
                  step="0.01"
                  value={writeOffAmount}
                  onChange={(e) => setWriteOffAmount(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2 md:col-span-2">
                <label className="text-sm font-medium">Reason</label>
                <input
                  type="text"
                  value={writeOffReason}
                  onChange={(e) => setWriteOffReason(e.target.value)}
                  placeholder="Uncollectible, customer bankrupt, etc."
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
            </div>
            
            <div className="flex gap-3">
              <Button onClick={handleWriteOff} disabled={processing || !writeOffAmount || !writeOffReason}>
                {processing ? 'Processing...' : 'Write Off'}
              </Button>
              <Button variant="ghost" onClick={() => setShowWriteOffForm(false)}>
                Cancel
              </Button>
            </div>
          </CardContent>
        </Card>
      ) : null}

      <Dialog open={showVoidDialog} onOpenChange={setShowVoidDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Void this invoice?</DialogTitle>
            <DialogDescription>
              This will reverse the revenue journal. {invoice.received_cents > 0 ? (
                <>The {formatCurrency(invoice.received_cents)} already settled will become a customer credit you can apply to future invoices.</>
              ) : (
                'No payments have been received yet.'
              )}
              <br />
              <span className="text-xs text-muted-foreground mt-2 block">
                {(() => {
                  if (!receipts || receipts.length === 0) {
                    return `Posts on ${formatLongDate(companyToday(orgTimezone))} (company time).`
                  }
                  const latestReceiptDate = receipts.reduce((latest, r) => {
                    return r.receipt_date > latest ? r.receipt_date : latest
                  }, receipts[0].receipt_date)
                  const today = companyToday(orgTimezone)
                  if (latestReceiptDate > today) {
                    return `Posts on ${formatLongDate(latestReceiptDate)}, the payment date.`
                  }
                  return `Posts on ${formatLongDate(companyToday(orgTimezone))} (company time).`
                })()}
              </span>
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowVoidDialog(false)} disabled={voiding}>
              Cancel
            </Button>
            <Button onClick={handleVoidInvoice} disabled={voiding}>
              {voiding ? 'Voiding...' : 'Void Invoice'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={showSendDialog} onOpenChange={setShowSendDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Send invoice</DialogTitle>
            <DialogDescription>
              Send {formatInvoiceNumber(invoice.number, invoice.invoice_date)} to {customer?.name || 'customer'}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <label className="text-sm font-medium">To</label>
              <input
                type="email"
                value={sendToEmail}
                onChange={(e) => setSendToEmail(e.target.value)}
                placeholder="customer@example.com"
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                disabled={processing}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowSendDialog(false)} disabled={processing}>
              Cancel
            </Button>
            <Button onClick={handleSendInvoice} disabled={processing || !sendToEmail.trim()}>
              {processing ? 'Sending...' : 'Send invoice'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={showReminderDialog} onOpenChange={setShowReminderDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Send reminder</DialogTitle>
            <DialogDescription>
              Send reminder for {formatInvoiceNumber(invoice.number, invoice.invoice_date)} to {customer?.name || 'customer'}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <label className="text-sm font-medium">To</label>
              <input
                type="email"
                value={reminderToEmail}
                onChange={(e) => setReminderToEmail(e.target.value)}
                placeholder="customer@example.com"
                className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                disabled={processing}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowReminderDialog(false)} disabled={processing}>
              Cancel
            </Button>
            <Button onClick={handleSendReminder} disabled={processing || !reminderToEmail.trim()}>
              {processing ? 'Sending...' : 'Send reminder'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={showApplyCreditDialog} onOpenChange={setShowApplyCreditDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Apply customer credit</DialogTitle>
            <DialogDescription>
              Enter the amount to apply to this invoice.
              <br />
              {invoice && (() => {
                const today = companyToday(orgTimezone)
                const postingDate = invoice.invoice_date > today ? invoice.invoice_date : today
                const comesFromInvoice = invoice.invoice_date > today
                return (
                  <span className="text-xs text-muted-foreground mt-2 block">
                    Posts on {formatLongDate(postingDate)}{comesFromInvoice ? ', the invoice date.' : ' (company time)'}
                  </span>
                )
              })()}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <label htmlFor="applyAmount" className="text-sm font-medium">
                Amount
              </label>
              <input
                id="applyAmount"
                type="number"
                step="0.01"
                min="0"
                max={(applyCreditMax / 100).toFixed(2)}
                value={applyAmount}
                onChange={(e) => setApplyAmount(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
                placeholder="0.00"
              />
              <p className="text-sm text-muted-foreground">
                Up to {formatCurrency(applyCreditMax)} available
              </p>
              {parseFloat(applyAmount) > (applyCreditMax / 100) && (
                <p className="text-sm text-destructive">
                  You can apply up to {formatCurrency(applyCreditMax)}
                </p>
              )}
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowApplyCreditDialog(false)} disabled={applyingCredit}>
              Cancel
            </Button>
            <Button
              onClick={handleApplyCredit}
              disabled={
                applyingCredit ||
                !applyAmount ||
                parseFloat(applyAmount) <= 0 ||
                parseFloat(applyAmount) > (applyCreditMax / 100)
              }
            >
              {applyingCredit ? 'Applying...' : 'Apply Credit'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <div className="flex gap-3">
        {!showReceiptForm && !showCreditForm && !showWriteOffForm && canSend && (
          <Button onClick={handleOpenSendDialog} disabled={processing}>
            Send invoice
          </Button>
        )}
        {!showReceiptForm && !showCreditForm && !showWriteOffForm && canSendReminder && (
          <Button onClick={handleOpenReminderDialog} disabled={processing} variant="outline">
            Send reminder
          </Button>
        )}
        {!showReceiptForm && !showCreditForm && !showWriteOffForm && canRecordReceipt && remaining > 0 && (
          <Button onClick={() => { 
            setReceiptDate(companyToday(orgTimezone))
            setShowReceiptForm(true); 
            setError(null); 
            setSuccess(null); 
          }}>Record Receipt</Button>
        )}
        {!showReceiptForm && !showCreditForm && !showWriteOffForm && canIssueCredit && remaining > 0 && (
          <Button onClick={() => { setShowCreditForm(true); setError(null); setSuccess(null); }} variant="outline">Credit Note</Button>
        )}
        {!showReceiptForm && !showCreditForm && !showWriteOffForm && canWriteOff && remaining > 0 && (
          <Button onClick={() => { setShowWriteOffForm(true); setError(null); setSuccess(null); }} variant="outline">Write Off</Button>
        )}
        {!showReceiptForm && !showCreditForm && !showWriteOffForm && canVoid && (
          <Button onClick={handleOpenVoidDialog} disabled={voiding} variant="outline">
            Void Invoice
          </Button>
        )}
      </div>
    </div>
  )
}
