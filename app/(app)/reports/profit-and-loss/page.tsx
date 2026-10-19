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
import { getFiscalYearStart, getCurrentDateString } from '@/lib/fiscal-year'
import { formatDate } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default function ProfitAndLossPage() {
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
    
    const { data: plData } = await supabase.rpc('get_profit_and_loss', {
      p_organization_id: orgId,
      p_start_date: startDate,
      p_end_date: endDate,
    })

    if (plData) setRows(plData)
    setLoading(false)
  }

  async function handleExport() {
    const url = `/api/exports/profit-and-loss?start_date=${startDate}&end_date=${endDate}`
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
          <h1 className="text-3xl font-semibold tracking-tight">Profit & Loss</h1>
          <p className="text-muted-foreground">Activity for a period</p>
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

  const revenue = rows.filter(r => r.section === 'Revenue')
  const expenses = rows.filter(r => r.section === 'Expenses')

  const totalRevenue = revenue.reduce((sum, r) => sum + (r.amount_cents || 0), 0) / 100
  const totalExpenses = expenses.reduce((sum, r) => sum + (r.amount_cents || 0), 0) / 100
  const netIncome = totalRevenue - totalExpenses

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/reports">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Profit & Loss</h1>
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
          <CardTitle>Profit & Loss</CardTitle>
          <CardDescription>Activity for a period</CardDescription>
        </CardHeader>
        <CardContent>
          {/* Revenue */}
          <div className="mb-6">
            <h3 className="font-semibold text-lg mb-3">Revenue</h3>
            <Table>
              <TableBody>
                {revenue.map((row, idx) => (
                  <TableRow key={idx} className={row.is_header ? 'font-semibold' : ''}>
                    <TableCell className={row.indent_level > 0 ? 'pl-8' : ''}>
                      {row.account_id ? (
                        <Link href={`/accounts/${row.account_id}`} className="text-blue-600 hover:underline">
                          {row.account_code} - {row.account_name}
                        </Link>
                      ) : (
                        row.account_name
                      )}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      ${Math.abs(row.amount_cents / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow className="font-semibold border-t-2">
                  <TableCell>Total Revenue</TableCell>
                  <TableCell className="text-right tabular-nums">
                    ${Math.abs(totalRevenue).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </div>

          <Separator className="my-6" />

          {/* Expenses */}
          <div className="mb-6">
            <h3 className="font-semibold text-lg mb-3">Expenses</h3>
            <Table>
              <TableBody>
                {expenses.map((row, idx) => (
                  <TableRow key={idx} className={row.is_header ? 'font-semibold' : ''}>
                    <TableCell className={row.indent_level > 0 ? 'pl-8' : ''}>
                      {row.account_id ? (
                        <Link href={`/accounts/${row.account_id}`} className="text-blue-600 hover:underline">
                          {row.account_code} - {row.account_name}
                        </Link>
                      ) : (
                        row.account_name
                      )}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      ${Math.abs(row.amount_cents / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow className="font-semibold border-t-2">
                  <TableCell>Total Expenses</TableCell>
                  <TableCell className="text-right tabular-nums">
                    ${Math.abs(totalExpenses).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </div>

          <Separator className="my-6" />

          <div className="flex justify-end">
            <div className="space-y-2 text-right">
              <div className="flex justify-between gap-8 text-lg font-semibold border-t pt-4">
                <span>Net {netIncome >= 0 ? 'Surplus' : 'Deficit'}:</span>
                <span className={netIncome >= 0 ? 'text-green-700' : 'text-red-700'}>
                  {formatCurrency(Math.round(netIncome * 100))}
                </span>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
