'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Button } from '@/components/ui/button'
import { Separator } from '@/components/ui/separator'
import { Download } from 'lucide-react'
import Link from 'next/link'
import { EmptyState } from '@/components/app/empty-state'
import { FileText } from 'lucide-react'

import { formatDate } from '@/lib/format-date'
import { getFiscalYearStart, getCurrentDateString } from '@/lib/fiscal-year'
import { formatCurrency } from '@/lib/money'

export default function CashMovementPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [startDate, setStartDate] = useState('')
  const [endDate, setEndDate] = useState('')
  const [orgName, setOrgName] = useState('')
  const [rows, setRows] = useState<any[]>([])
  const [hasJournals, setHasJournals] = useState(false)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    initializeDates()
  }, [])

  useEffect(() => {
    if (startDate && endDate) {
      loadData()
    }
  }, [startDate, endDate])

  async function initializeDates() {
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
  }

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgId } = await supabase.rpc('current_org_id')
    
    // Check if there are any posted/reversed journals in the period
    const { count: journalCount } = await supabase
      .from('journals')
      .select('id', { count: 'exact', head: true })
      .eq('organization_id', orgId)
      .in('status', ['Posted', 'Reversed'])
      .gte('entry_date', startDate)
      .lte('entry_date', endDate)
    
    setHasJournals((journalCount !== null && journalCount > 0))
    
    const { data: cmData, error } = await supabase.rpc('get_cash_movement', {
      p_organization_id: orgId,
      p_start_date: startDate,
      p_end_date: endDate,
    })

    if (error) {
      setRows([])
    } else if (cmData) {
      const validRows = cmData.filter((row: any) => {
        const net = row.net_change_cents
        return typeof net === 'number' && Number.isFinite(net)
      })
      setRows(validRows)
    } else {
      setRows([])
    }
    
    setLoading(false)
  }

  async function handleExport() {
    const url = `/api/exports/cash-movement?start_date=${startDate}&end_date=${endDate}`
    window.location.href = url
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  if (!hasJournals) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <Link href="/reports">
            <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
          </Link>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Cash Movement</h1>
              <p className="text-muted-foreground">Change in cash, by counter-account</p>
            </div>
            <div className="flex gap-2">
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
            </div>
          </div>
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

  // Calculate totals: net_change_cents is already signed from cash's perspective
  // Positive = cash increase (inflow), Negative = cash decrease (outflow)
  const totalCashInCents = rows.reduce((sum, r) => {
    const netChange = typeof r.net_change_cents === 'number' ? r.net_change_cents : 0
    if (!Number.isFinite(netChange)) return sum
    return sum + Math.max(netChange, 0)
  }, 0)
  
  const totalCashOutCents = rows.reduce((sum, r) => {
    const netChange = typeof r.net_change_cents === 'number' ? r.net_change_cents : 0
    if (!Number.isFinite(netChange)) return sum
    return sum + Math.max(-netChange, 0)
  }, 0)
  
  // Footer Net Change = sum of all signed row nets (no Math.abs, no in-out)
  // Assertion: if one row is -$1.00 net, footer must show -$1.00
  const netChangeCents = rows.reduce((sum, r) => {
    const netChange = typeof r.net_change_cents === 'number' ? r.net_change_cents : 0
    if (!Number.isFinite(netChange)) return sum
    return sum + netChange
  }, 0)

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/reports">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Cash Movement</h1>
            <p className="text-muted-foreground">
              {formatDate(startDate)} to {formatDate(endDate)} • {orgName}
            </p>
          </div>
          <div className="flex gap-2">
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
          <CardTitle>Cash Movement Report</CardTitle>
          <CardDescription>Change in cash, by counter-account</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Counter Account</TableHead>
                <TableHead className="text-right">Cash In</TableHead>
                <TableHead className="text-right">Cash Out</TableHead>
                <TableHead className="text-right">Net</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, idx) => {
                const netChangeCents = typeof row.net_change_cents === 'number' ? row.net_change_cents : 0
                if (!Number.isFinite(netChangeCents)) return null
                
                const cashInCents = Math.max(netChangeCents, 0)
                const cashOutCents = Math.max(-netChangeCents, 0)
                
                return (
                  <TableRow key={idx}>
                    <TableCell>
                      <Link href={`/accounts/${row.counter_account_id}`} className="text-blue-600 hover:underline">
                        {row.counter_account_code} - {row.counter_account_name}
                      </Link>
                    </TableCell>
                    <TableCell className="text-right tabular-nums text-green-700">
                      {cashInCents > 0 ? formatCurrency(cashInCents) : '—'}
                    </TableCell>
                    <TableCell className="text-right tabular-nums text-red-700">
                      {cashOutCents > 0 ? formatCurrency(cashOutCents) : '—'}
                    </TableCell>
                    <TableCell className="text-right tabular-nums font-medium">
                      {formatCurrency(netChangeCents)}
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
          
          <Separator className="my-4" />
          
          <div className="flex justify-end">
            <div className="space-y-2 text-right">
              <div className="flex justify-between gap-8 text-sm font-medium">
                <span className="text-muted-foreground">Total Cash In:</span>
                <span className="tabular-nums text-green-700">{formatCurrency(totalCashInCents)}</span>
              </div>
              <div className="flex justify-between gap-8 text-sm font-medium">
                <span className="text-muted-foreground">Total Cash Out:</span>
                <span className="tabular-nums text-red-700">{formatCurrency(totalCashOutCents)}</span>
              </div>
              <Separator className="my-2" />
              <div className="flex justify-between gap-8 border-t pt-2 text-lg font-semibold">
                <span>Net Change:</span>
                <span className={netChangeCents >= 0 ? 'text-green-700' : 'text-red-700'}>
                  {formatCurrency(netChangeCents)}
                </span>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
