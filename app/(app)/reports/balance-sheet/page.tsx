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

import { formatDate, getLocalDateString, companyToday } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default function BalanceSheetPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [orgTimezone, setOrgTimezone] = useState<string>('America/New_York')
  const [asOfDate, setAsOfDate] = useState('')
  const [orgName, setOrgName] = useState('')
  const [rows, setRows] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    checkAuthAndLoadTimezone()
  }, [])

  useEffect(() => {
    if (asOfDate) {
      loadData()
    }
  }, [asOfDate])

  async function checkAuthAndLoadTimezone() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    // Load timezone first
    const { data: orgData } = await supabase
      .from('organizations')
      .select('name, timezone')
      .single()
    if (orgData) {
      setOrgName(orgData.name)
      const tz = orgData.timezone || 'America/New_York'
      setOrgTimezone(tz)
      setAsOfDate(companyToday(tz))
    }
  }

  async function loadData() {
    setLoading(true)
    setError(null)
    
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgId } = await supabase.rpc('current_org_id')
    
    const { data: bsData, error: bsError } = await supabase.rpc('get_balance_sheet', {
      p_organization_id: orgId,
      p_as_of_date: asOfDate,
    })

    if (bsError) {
      setError("Couldn't load this report.")
      setRows([])
    } else if (bsData) {
      setRows(bsData)
    } else {
      setRows([])
    }
    
    setLoading(false)
  }

  async function handleExport() {
    const url = `/api/exports/balance-sheet?as_of_date=${asOfDate}`
    window.location.href = url
  }

  if (loading) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <Link href="/reports">
            <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
          </Link>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Balance Sheet</h1>
              <p className="text-muted-foreground">Position as of a date</p>
            </div>
            <div className="flex gap-2">
              <input
                type="date"
                value={asOfDate}
                onChange={(e) => setAsOfDate(e.target.value)}
                className="rounded-md border border-neutral-300 px-3 py-2 text-sm"
              />
            </div>
          </div>
        </div>
        <div>Loading...</div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <Link href="/reports">
            <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
          </Link>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Balance Sheet</h1>
              <p className="text-muted-foreground">Position as of a date</p>
            </div>
            <div className="flex gap-2">
              <input
                type="date"
                value={asOfDate}
                onChange={(e) => setAsOfDate(e.target.value)}
                className="rounded-md border border-neutral-300 px-3 py-2 text-sm"
              />
            </div>
          </div>
        </div>
        <Card>
          <CardContent className="pt-6">
            <div className="text-red-600">Couldn't load this report.</div>
          </CardContent>
        </Card>
      </div>
    )
  }

  if (rows.length === 0) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <Link href="/reports">
            <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
          </Link>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Balance Sheet</h1>
              <p className="text-muted-foreground">Position as of a date</p>
            </div>
            <div className="flex gap-2">
              <input
                type="date"
                value={asOfDate}
                onChange={(e) => setAsOfDate(e.target.value)}
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

  const assets = rows.filter(r => r.section === 'Assets')
  const liabilities = rows.filter(r => r.section === 'Liabilities')
  const equity = rows.filter(r => r.section === 'Equity')

  const totalAssets = assets.reduce((sum, r) => sum + (r.balance_cents || 0), 0) / 100
  const totalLiabilities = liabilities.reduce((sum, r) => sum + (r.balance_cents || 0), 0) / 100
  const totalEquity = equity.reduce((sum, r) => sum + (r.balance_cents || 0), 0) / 100
  // Balanced check: Assets = Liabilities + Equity (with normal balance signs applied)
  const isBalanced = Math.abs(totalAssets - (totalLiabilities + totalEquity)) < 0.01

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/reports">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Balance Sheet</h1>
            <p className="text-muted-foreground">
              As of {formatDate(asOfDate)} • {orgName}
            </p>
          </div>
          <div className="flex gap-2">
            <input
              type="date"
              value={asOfDate}
              onChange={(e) => setAsOfDate(e.target.value)}
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
          <CardTitle>Balance Sheet</CardTitle>
          <CardDescription>Position as of a date</CardDescription>
        </CardHeader>
        <CardContent>
          {/* Assets */}
          <div className="mb-6">
            <h3 className="font-semibold text-lg mb-3">Assets</h3>
            <Table>
              <TableBody>
                {assets.map((row, idx) => (
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
                    <TableCell className={`text-right tabular-nums ${(row.balance_cents || 0) < 0 ? 'text-red-700' : ''}`}>
                      {formatCurrency(row.balance_cents || 0)}
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow className="font-semibold border-t-2">
                  <TableCell>Total Assets</TableCell>
                  <TableCell className={`text-right tabular-nums ${totalAssets < 0 ? 'text-red-700' : ''}`}>
                    {formatCurrency(Math.round(totalAssets * 100))}
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </div>

          <Separator className="my-6" />

          {/* Liabilities */}
          <div className="mb-6">
            <h3 className="font-semibold text-lg mb-3">Liabilities</h3>
            <Table>
              <TableBody>
                {liabilities.map((row, idx) => (
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
                    <TableCell className={`text-right tabular-nums ${(row.balance_cents || 0) < 0 ? 'text-red-700' : ''}`}>
                      {formatCurrency(row.balance_cents || 0)}
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow className="font-semibold border-t-2">
                  <TableCell>Total Liabilities</TableCell>
                  <TableCell className={`text-right tabular-nums ${totalLiabilities < 0 ? 'text-red-700' : ''}`}>
                    {formatCurrency(Math.round(totalLiabilities * 100))}
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </div>

          <Separator className="my-6" />

          {/* Equity */}
          <div className="mb-6">
            <h3 className="font-semibold text-lg mb-3">Equity</h3>
            <Table>
              <TableBody>
                {equity.map((row, idx) => (
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
                    <TableCell className={`text-right tabular-nums ${(row.balance_cents || 0) < 0 ? 'text-red-700' : ''}`}>
                      {formatCurrency(row.balance_cents || 0)}
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow className="font-semibold border-t-2">
                  <TableCell>Total Equity</TableCell>
                  <TableCell className={`text-right tabular-nums ${totalEquity < 0 ? 'text-red-700' : ''}`}>
                    {formatCurrency(Math.round(totalEquity * 100))}
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </div>

          <Separator className="my-6" />

          <div className="flex justify-end">
            <div className="space-y-2 text-right">
              <div className="flex justify-between gap-8 text-sm font-medium">
                <span className="text-muted-foreground">Total Liabilities + Equity:</span>
                <span className={`tabular-nums ${(totalLiabilities + totalEquity) < 0 ? 'text-red-700' : ''}`}>
                  {formatCurrency(Math.round((totalLiabilities + totalEquity) * 100))}
                </span>
              </div>
              <Separator className="my-2" />
              <div className="flex justify-between gap-8 border-t pt-2 font-semibold">
                <span>Balanced:</span>
                <span className={isBalanced ? 'text-green-700' : 'text-red-700'}>
                  {isBalanced ? '✓ Yes' : '✗ No'}
                </span>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
