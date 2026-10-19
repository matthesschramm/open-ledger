'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { ArrowLeft, ExternalLink } from 'lucide-react'
import { getLocalDateString, formatDate, companyToday } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'
import { guardedPost } from '@/lib/guarded-post'
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

export default function BillDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const router = useRouter()
  const supabase = createClient()
  
  const [billId, setBillId] = useState<string | null>(null)
  const [bill, setBill] = useState<any>(null)
  const [lines, setLines] = useState<any[]>([])
  const [payments, setPayments] = useState<any[]>([])
  const [cashAccounts, setCashAccounts] = useState<any[]>([])
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [orgTimezone, setOrgTimezone] = useState<string>('America/New_York')
  const [lockDate, setLockDate] = useState<string | null>(null)
  const [paying, setPaying] = useState(false)
  const [voiding, setVoiding] = useState(false)
  const [showPayForm, setShowPayForm] = useState(false)
  const [showVoidDialog, setShowVoidDialog] = useState(false)
  const [paymentDate, setPaymentDate] = useState(getLocalDateString())
  const [paymentAmount, setPaymentAmount] = useState('')
  const [cashAccountId, setCashAccountId] = useState('')
  const [supplierCredit, setSupplierCredit] = useState<any>(null)
  const [availableCredits, setAvailableCredits] = useState<any[]>([])
  const [applyingCredit, setApplyingCredit] = useState(false)
  const [showApplyCreditDialog, setShowApplyCreditDialog] = useState(false)
  const [applyCreditId, setApplyCreditId] = useState<string | null>(null)
  const [applyCreditMax, setApplyCreditMax] = useState(0)
  const [applyAmount, setApplyAmount] = useState('')
  const [applyIdempotencyKey, setApplyIdempotencyKey] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)

  useEffect(() => {
    params.then(p => setBillId(p.id))
  }, [params])

  useEffect(() => {
    if (billId) {
      loadBill()
    }
  }, [billId])

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

  async function loadBill() {
    if (!billId) return

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

    const { data: billData } = await supabase
      .from('bills')
      .select(`
        *,
        contact:contacts(name)
      `)
      .eq('id', billId)
      .single()

    if (billData) {
      setBill(billData)
      setPaymentAmount((billData.total_cents / 100).toFixed(2))
    }

    const { data: linesData } = await supabase
      .from('bill_lines')
      .select(`
        *,
        account:accounts(code, name)
      `)
      .eq('bill_id', billId)
      .order('created_at')

    if (linesData) setLines(linesData)

    const { data: paymentsData } = await supabase
      .from('bill_payments')
      .select('*')
      .eq('bill_id', billId)
      .order('payment_date', { ascending: false })

    if (paymentsData) setPayments(paymentsData)

    const { data: cashData } = await supabase
      .from('accounts')
      .select('*')
      .eq('is_cash', true)
      .eq('is_active', true)
      .order('code')

    if (cashData) setCashAccounts(cashData)

    // Load supplier credit if voided
    if (billData && billData.status === 'Void') {
      const { data: creditData } = await supabase
        .from('supplier_credits')
        .select('*')
        .eq('source_bill_id', billId)
        .eq('status', 'open')
        .maybeSingle()

      if (creditData) setSupplierCredit(creditData)
    }

    // Load available credits for this vendor
    if (billData && billData.vendor_id && billData.status === 'Open') {
      const { data: creditsData } = await supabase
        .from('supplier_credits')
        .select('*, bills!supplier_credits_source_bill_id_fkey(number)')
        .eq('contact_id', billData.vendor_id)
        .eq('status', 'open')
        .gt('remaining_cents', 0)
        .order('created_at')

      if (creditsData) setAvailableCredits(creditsData)
    } else {
      setAvailableCredits([])
    }
  }

  async function handleOpenVoidDialog() {
    setShowVoidDialog(true)
  }

  async function handleVoid() {
    if (!billId) return
    
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

      const { data, error } = await supabase.rpc('void_bill', {
        p_bill_id: billId,
        p_void_date: localDate,
      })

      if (error) {
        // Parse error codes for friendly messages
        if (error.message.includes('PERIOD_LOCKED:')) {
          setError(`This date is in a locked period. Choose a date after ${formatLockDate(lockDate)}.`)
        } else {
          setError(error.message || 'Could not void bill — try again')
        }
        return
      }
      
      if (data && !data.success) {
        // Map error codes to friendly messages
        if (data?.error_code === 'PERIOD_LOCKED') {
          setError(`This date is in a locked period. Choose a date after ${formatLockDate(lockDate)}.`)
        } else if (data?.error_code === 'INSUFFICIENT_PERMISSIONS') {
          setError('You don\'t have permission to void this bill.')
        } else {
          setError(data?.error || 'Could not void bill — try again')
        }
      } else {
        // Refetch the bill to update UI in place
        await loadBill()
        // Force Next.js to refresh router cache so UI updates immediately
        router.refresh()
      }
    } catch (error: any) {
      setError('Could not void bill — try again')
    } finally {
      setVoiding(false)
    }
  }

  function handleOpenApplyDialog(creditId: string, creditRemaining: number) {
    if (!bill) return
    const billOpenBalance = bill.total_cents - bill.paid_cents
    const maxApply = Math.min(creditRemaining, billOpenBalance)
    
    setApplyCreditId(creditId)
    setApplyCreditMax(maxApply)
    setApplyAmount((maxApply / 100).toFixed(2))
    setApplyIdempotencyKey(crypto.randomUUID())
    setError(null)
    setSuccess(null)
    setShowApplyCreditDialog(true)
  }

  async function handleApplyCredit() {
    if (!billId || !applyCreditId) return

    const amountCents = Math.round(parseFloat(applyAmount) * 100)
    if (isNaN(amountCents) || amountCents <= 0) return

    setApplyingCredit(true)
    setShowApplyCreditDialog(false)
    setError(null)
    setSuccess(null)
    try {
      const { data, error } = await supabase.rpc('apply_supplier_credit', {
        p_credit_id: applyCreditId,
        p_bill_id: billId,
        p_amount_cents: amountCents,
        p_idempotency_key: applyIdempotencyKey,
      })

      if (error) {
        // Parse exception error codes for friendly messages
        if (error.message.includes('PERIOD_LOCKED:')) {
          setError(`This date is in a locked period. Choose a date after ${formatLockDate(lockDate)}.`)
        } else if (error.message.includes('INSUFFICIENT_BALANCE:')) {
          const msg = error.message.replace('INSUFFICIENT_BALANCE:', '').trim()
          setError(msg)
        } else if (error.message.includes('VALIDATION_ERROR:')) {
          const msg = error.message.replace('VALIDATION_ERROR:', '').trim()
          setError(msg)
        } else if (error.message.includes('INVALID_STATUS:')) {
          const msg = error.message.replace('INVALID_STATUS:', '').trim()
          setError(msg)
        } else {
          setError(error.message || 'Could not apply credit — try again')
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
        await loadBill()
      }
    } catch (error: any) {
      setError('Could not apply credit — try again')
    } finally {
      setApplyingCredit(false)
    }
  }

  async function handlePay() {
    if (!cashAccountId || !paymentAmount) return
    
    setPaying(true)
    try {
      const amountCents = Math.round(parseFloat(paymentAmount) * 100)
      if (!Number.isFinite(amountCents) || amountCents <= 0) {
        throw new Error('Payment must be greater than zero')
      }
      const remainingCents = bill.total_cents - bill.paid_cents
      if (amountCents > remainingCents) {
        throw new Error('Payment exceeds remaining balance')
      }

      // Get current user
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      // Get org ID
      const { data: orgData } = await supabase.rpc('current_org_id')
      if (!orgData) throw new Error('Organization not found')

      // Get AP account
      const { data: apData } = await supabase
        .from('accounts')
        .select('*')
        .eq('code', '2000')
        .single()

      if (!apData) throw new Error('AP account not found')

      await guardedPost(supabase, orgData, paymentDate, null, async (track) => {
        // Create payment journal (Draft, number assigned at post time)
        const { data: journal, error: journalError } = await supabase
          .from('journals')
          .insert({
            organization_id: orgData,
            number: null,
            entry_date: paymentDate,
            description: `Payment for bill ${bill.number}`,
            status: 'Draft',
            source: 'bill_payment',
            created_by: user.id,
          })
          .select()
          .single()

        if (journalError) throw journalError
        track('journals', journal.id)

        // Create journal lines
        const { data: insertedLines, error: linesError } = await supabase
          .from('journal_lines')
          .insert([
            {
              organization_id: orgData,
              journal_id: journal.id,
              account_id: apData.id,
              debit_cents: amountCents,
              credit_cents: 0,
              memo: `Bill ${bill.number}`,
            },
            {
              organization_id: orgData,
              journal_id: journal.id,
              account_id: cashAccountId,
              debit_cents: 0,
              credit_cents: amountCents,
              memo: `Bill ${bill.number}`,
            },
          ])
          .select()

        if (linesError) throw linesError
        insertedLines?.forEach(line => track('journal_lines', line.id))

        // Post the journal via RPC (respects period locks)
        const { data: postResult, error: postError } = await supabase.rpc('post_journal', {
          p_journal_id: journal.id,
          p_user_id: user.id,
        })

        if (postError) throw postError
        if (!postResult?.success) {
          throw new Error(postResult?.error || 'Unknown error')
        }

        // Record bill payment (AFTER post succeeds - no rollback needed)
        const { error: paymentError } = await supabase
          .from('bill_payments')
          .insert({
            organization_id: orgData,
            bill_id: billId,
            payment_journal_id: journal.id,
            payment_date: paymentDate,
            amount_cents: amountCents,
            created_by: user.id,
          })

        if (paymentError) throw paymentError

        // Update bill paid_cents and status
        const newPaidCents = bill.paid_cents + amountCents
        const updates: any = {
          paid_cents: newPaidCents
        }
        
        // Update bill status if fully paid
        if (newPaidCents >= bill.total_cents) {
          updates.status = 'Paid'
        }

        await supabase
          .from('bills')
          .update(updates)
          .eq('id', billId)
      })

      setShowPayForm(false)
      await loadBill()
    } catch (error: any) {
      setError(`Error: ${error.message}`)
    } finally {
      setPaying(false)
    }
  }

  if (!bill) {
    return <div className="p-8">Loading...</div>
  }

  const totalPaid = payments.reduce((sum, p) => sum + p.amount_cents, 0)
  const remainingCents = bill.status === 'Void' ? 0 : (bill.total_cents - totalPaid)

  const canPay = currentRole && ['owner', 'bookkeeper'].includes(currentRole) && bill.status === 'Open'
  const canVoid = currentRole && ['owner', 'admin', 'bookkeeper'].includes(currentRole) && bill.status !== 'Void'

  return (
    <div className="p-8">
      <div className="mb-8">
        <Button variant="ghost" onClick={() => router.back()} className="mb-4">
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back
        </Button>
        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">{bill.number}</h1>
            <p className="text-muted-foreground">{bill.contact?.name}</p>
          </div>
          <Badge variant={
            bill.status === 'Paid' ? 'default' :
            bill.status === 'Void' ? 'secondary' : 'outline'
          }>
            {bill.status === 'Void' ? 'Voided' : bill.status}
          </Badge>
        </div>
        {bill.status === 'Void' && supplierCredit && (
          <div className="mt-4 p-4 rounded-md bg-blue-50 border border-blue-200">
            <p className="text-sm text-blue-900">
              Bill voided. {formatCurrency(supplierCredit.remaining_cents)} kept as{' '}
              <Link href={`/contacts/${bill.vendor_id}`} className="underline font-medium">
                supplier credit
              </Link>
            </p>
          </div>
        )}
      </div>

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

      <div className="grid gap-6 md:grid-cols-2 mb-6">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Bill Total
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-semibold tabular-nums">
              {formatCurrency(bill.total_cents)}
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
              {formatCurrency(remainingCents)}
            </div>
          </CardContent>
        </Card>
      </div>

      <Card className="mb-6">
        <CardHeader>
          <CardTitle>Bill Details</CardTitle>
          <CardDescription>
            Bill date: {formatDate(bill.bill_date)}
            {bill.due_date && ` · Due: ${formatDate(bill.due_date)}`}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {bill.notes && (
            <p className="text-sm text-muted-foreground mb-4">{bill.notes}</p>
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
                    {line.account.code} - {line.account.name}
                  </TableCell>
                  <TableCell className="text-sm">{line.description || '-'}</TableCell>
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
              {availableCredits.length} supplier credit{availableCredits.length > 1 ? 's' : ''} available
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Source Bill</TableHead>
                  <TableHead className="text-right">Available</TableHead>
                  <TableHead className="text-right">Action</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {availableCredits.map((credit: any) => (
                  <TableRow key={credit.id}>
                    <TableCell className="text-sm">{credit.bills?.number || '—'}</TableCell>
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

      {payments.length > 0 && (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Payments</CardTitle>
            <CardDescription>{payments.length} payment(s) recorded</CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Date</TableHead>
                  <TableHead>Method</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {payments.map((payment: any) => (
                  <TableRow key={payment.id}>
                    <TableCell>{formatDate(payment.payment_date)}</TableCell>
                    <TableCell>
                      {payment.source === 'supplier_credit' ? 'Supplier credit' : 'Cash'}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatCurrency(payment.amount_cents)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}

      {showPayForm ? (
        <Card>
          <CardHeader>
            <CardTitle>Record Payment</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <label className="text-sm font-medium">Payment Date</label>
                <input
                  type="date"
                  value={paymentDate}
                  onChange={(e) => setPaymentDate(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium">Amount</label>
                <input
                  type="number"
                  step="0.01"
                  value={paymentAmount}
                  onChange={(e) => setPaymentAmount(e.target.value)}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="space-y-2 md:col-span-2">
                <label className="text-sm font-medium">Pay From</label>
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
            </div>
            
            <div className="flex gap-3">
              <Button onClick={handlePay} disabled={paying || !cashAccountId || !paymentAmount}>
                {paying ? 'Processing...' : 'Record Payment'}
              </Button>
              <Button variant="ghost" onClick={() => setShowPayForm(false)}>
                Cancel
              </Button>
            </div>
          </CardContent>
        </Card>
      ) : (
        <div className="flex gap-3">
          {canPay && (
            <Button onClick={() => {
              // Set payment date to company-local today when opening
              setPaymentDate(companyToday(orgTimezone))
              setShowPayForm(true)
            }}>Pay Bill</Button>
          )}
          {canVoid && (
            <Button onClick={handleOpenVoidDialog} disabled={voiding} variant="outline">
              Void Bill
            </Button>
          )}
        </div>
      )}

      <Dialog open={showVoidDialog} onOpenChange={setShowVoidDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Void this bill?</DialogTitle>
            <DialogDescription>
              This will reverse the AP journal. {bill.paid_cents > 0 ? (
                <>The {formatCurrency(bill.paid_cents)} already settled will become a supplier credit you can apply to future bills.</>
              ) : (
                'No payments have been made yet.'
              )}
              <br />
              <span className="text-xs text-muted-foreground mt-2 block">
                {(() => {
                  if (!payments || payments.length === 0) {
                    return `Posts on ${formatLongDate(companyToday(orgTimezone))} (company time).`
                  }
                  const latestPaymentDate = payments.reduce((latest, p) => {
                    return p.payment_date > latest ? p.payment_date : latest
                  }, payments[0].payment_date)
                  const today = companyToday(orgTimezone)
                  if (latestPaymentDate > today) {
                    return `Posts on ${formatLongDate(latestPaymentDate)}, the payment date.`
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
            <Button onClick={handleVoid} disabled={voiding}>
              {voiding ? 'Voiding...' : 'Void Bill'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={showApplyCreditDialog} onOpenChange={setShowApplyCreditDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Apply supplier credit</DialogTitle>
            <DialogDescription>
              Enter the amount to apply to this bill.
              <br />
              {bill && (() => {
                const today = companyToday(orgTimezone)
                const postingDate = bill.bill_date > today ? bill.bill_date : today
                const comesFromBill = bill.bill_date > today
                return (
                  <span className="text-xs text-muted-foreground mt-2 block">
                    Posts on {formatLongDate(postingDate)}{comesFromBill ? ', the bill date.' : ' (company time)'}
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
    </div>
  )
}
