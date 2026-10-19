'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Button } from '@/components/ui/button'
import { Download } from 'lucide-react'
import Link from 'next/link'
import { EmptyState } from '@/components/app/empty-state'
import { FileText } from 'lucide-react'
import { getFiscalYearStart, getCurrentDateString } from '@/lib/fiscal-year'
import { formatDate } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default function AccountLedgerPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [accounts, setAccounts] = useState<any[]>([])
  const [selectedAccountId, setSelectedAccountId] = useState('')
  const [startDate, setStartDate] = useState('')
  const [endDate, setEndDate] = useState('')
  const [orgName, setOrgName] = useState('')
  const [rows, setRows] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadAccounts()
  }, [])

  useEffect(() => {
    if (selectedAccountId && startDate && endDate) {
      loadLedger()
    }
  }, [selectedAccountId, startDate, endDate])

  async function loadAccounts() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgData } = await supabase
      .from('organizations')
      .select('name, fiscal_year_end_month, fiscal_year_end_day')
      .single()
    
    if (orgData) {
      setOrgName(orgData.name)
      const fyStart = getFiscalYearStart(
        orgData.fiscal_year_end_month || 12,
        orgData.fiscal_year_end_day || 31
      )
      setStartDate(fyStart)
      setEndDate(getCurrentDateString())
    }

    const { data: accountsData } = await supabase
      .from('accounts')
      .select('*')
      .eq('is_active', true)
      .eq('is_header', false)
      .order('code')

    if (accountsData) {
      setAccounts(accountsData)
      if (accountsData.length > 0) {
        setSelectedAccountId(accountsData[0].id)
      }
    }
    setLoading(false)
  }

  async function loadLedger() {
    const { data: orgId } = await supabase.rpc('current_org_id')
    
    const { data: ledgerData } = await supabase.rpc('get_account_ledger', {
      p_organization_id: orgId,
      p_account_id: selectedAccountId,
      p_start_date: startDate,
      p_end_date: endDate,
    })

    if (ledgerData) setRows(ledgerData)
  }

  async function handleExport() {
    const url = `/api/exports/account-ledger?account_id=${selectedAccountId}&start_date=${startDate}&end_date=${endDate}`
    window.location.href = url
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  if (accounts.length === 0) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <Link href="/reports">
            <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
          </Link>
          <h1 className="text-3xl font-semibold tracking-tight">Account Ledger</h1>
          <p className="text-muted-foreground">Every posted line in one account</p>
        </div>
        <EmptyState
          icon={<FileText className="h-8 w-8 text-coral" />}
          title="Nothing to report yet"
          description="Post a journal, then this report can add up."
          actions={[{ label: 'New journal', href: '/journals/new' }]}
        />
      </div>
    )
  }

  const selectedAccount = accounts.find(a => a.id === selectedAccountId)
  const runningBalance = rows.length > 0 ? rows[rows.length - 1].running_balance_cents : 0
  
  // For Asset and Expense accounts (debit normal), balance is signed as-is
  // For Liability, Equity, Revenue accounts (credit normal), negate the balance
  const signedBalance = selectedAccount && ['Liability', 'Equity', 'Revenue'].includes(selectedAccount.type)
    ? -runningBalance
    : runningBalance

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/reports">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Account Ledger</h1>
            <p className="text-muted-foreground">
              {selectedAccount?.code} - {selectedAccount?.name} • {orgName}
            </p>
          </div>
          <div className="flex gap-2">
            <select
              value={selectedAccountId}
              onChange={(e) => setSelectedAccountId(e.target.value)}
              className="rounded-md border border-neutral-300 px-3 py-2 text-sm"
            >
              {accounts.map(acc => (
                <option key={acc.id} value={acc.id}>
                  {acc.code} - {acc.name}
                </option>
              ))}
            </select>
            <input
              type="date"
              value={startDate}
              onChange={(e) => setStartDate(e.target.value)}
              className="rounded-md border border-neutral-300 px-3 py-2 text-sm"
            />
            <span className="flex items-center text-sm text-muted-foreground">to</span>
            <input
              type="date"
              value={endDate}
              onChange={(e) => setEndDate(e.target.value)}
              className="rounded-md border border-neutral-300 px-3 py-2 text-sm"
            />
            <Button variant="outline" size="sm" onClick={handleExport}>
              <Download className="mr-2 h-4 w-4" />
              Export CSV
            </Button>
          </div>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Account Ledger Report</CardTitle>
          <CardDescription>Every posted line in one account</CardDescription>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground py-8 text-center">
              No posted entries in this date range
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Date</TableHead>
                  <TableHead>Journal</TableHead>
                  <TableHead>Description</TableHead>
                  <TableHead className="text-right">Debit</TableHead>
                  <TableHead className="text-right">Credit</TableHead>
                  <TableHead className="text-right">Balance</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row, idx) => (
                  <TableRow key={idx}>
                    <TableCell className="text-sm">
                      {formatDate(row.entry_date)}
                    </TableCell>
                    <TableCell>
                      <Link href={`/journals/${row.journal_id}`} className="text-sm text-blue-600 hover:underline">
                        {row.journal_number || 'Draft'}
                      </Link>
                    </TableCell>
                    <TableCell className="text-sm">
                      {row.line_memo || row.journal_description}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {row.debit_cents > 0 ? formatCurrency(row.debit_cents) : '—'}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {row.credit_cents > 0 ? formatCurrency(row.credit_cents) : '—'}
                    </TableCell>
                    <TableCell className="text-right tabular-nums font-medium">
                      {formatCurrency(
                        selectedAccount && ['Liability', 'Equity', 'Revenue'].includes(selectedAccount.type)
                          ? -row.running_balance_cents
                          : row.running_balance_cents
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          
          {rows.length > 0 && (
            <div className="mt-4 flex justify-end">
              <div className="text-right">
                <div className="flex justify-between gap-8 text-lg font-semibold border-t pt-4">
                  <span>Ending Balance:</span>
                  <span>{formatCurrency(signedBalance)}</span>
                </div>
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
