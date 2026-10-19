'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Button } from '@/components/ui/button'
import { Separator } from '@/components/ui/separator'
import { Download } from 'lucide-react'
import { formatCurrency } from '@/lib/money'
import Link from 'next/link'
import { EmptyState } from '@/components/app/empty-state'
import { FileText } from 'lucide-react'
import { formatDate, companyToday } from '@/lib/format-date'

export default function TrialBalancePage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [asOfDate, setAsOfDate] = useState('')
  const [orgName, setOrgName] = useState('')
  const [orgTimezone, setOrgTimezone] = useState('UTC')
  const [rows, setRows] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    loadInitialData()
  }, [])

  useEffect(() => {
    if (asOfDate) {
      loadData()
    }
  }, [asOfDate])

  async function loadInitialData() {
    const { data: orgData } = await supabase
      .from('organizations')
      .select('name, timezone')
      .single()
    if (orgData) {
      setOrgName(orgData.name)
      const timezone = orgData.timezone || 'UTC'
      setOrgTimezone(timezone)
      setAsOfDate(companyToday(timezone))
    }
  }

  async function loadData() {
    if (!asOfDate) return
    setLoading(true)
    setError(null)
    
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgId } = await supabase.rpc('current_org_id')
    
    const { data: tbData, error: tbError } = await supabase.rpc('get_trial_balance', {
      p_organization_id: orgId,
      p_as_of_date: asOfDate,
    })

    if (tbError) {
      setError("Couldn't load this report.")
      setRows([])
    } else if (tbData) {
      setRows(tbData)
    } else {
      setRows([])
    }
    
    setLoading(false)
  }

  async function handleExport() {
    const url = `/api/exports/trial-balance?as_of_date=${asOfDate}`
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
              <h1 className="text-3xl font-semibold tracking-tight">Trial Balance</h1>
              <p className="text-muted-foreground">The accountant check</p>
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
              <h1 className="text-3xl font-semibold tracking-tight">Trial Balance</h1>
              <p className="text-muted-foreground">The accountant check</p>
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
              <h1 className="text-3xl font-semibold tracking-tight">Trial Balance</h1>
              <p className="text-muted-foreground">The accountant check</p>
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

  const totalDebitCents = rows.reduce((sum, row) => sum + (row.debit_cents || 0), 0)
  const totalCreditCents = rows.reduce((sum, row) => sum + (row.credit_cents || 0), 0)
  const isBalanced = Math.abs(totalDebitCents - totalCreditCents) < 1

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/reports">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Trial Balance</h1>
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
          <CardTitle>Trial Balance Report</CardTitle>
          <CardDescription>All accounts with debit and credit balances from posted journal entries</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Code</TableHead>
                <TableHead>Account Name</TableHead>
                <TableHead>Type</TableHead>
                <TableHead className="text-right">Debit</TableHead>
                <TableHead className="text-right">Credit</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, idx) => (
                <TableRow key={idx}>
                  <TableCell className="font-mono text-sm">
                    <Link href={`/accounts/${row.account_id}`} className="text-blue-600 hover:underline">
                      {row.account_code}
                    </Link>
                  </TableCell>
                  <TableCell className="font-medium">{row.account_name}</TableCell>
                  <TableCell className="text-sm text-muted-foreground">{row.account_type}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {row.debit_cents > 0 ? formatCurrency(row.debit_cents) : '—'}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {row.credit_cents > 0 ? formatCurrency(row.credit_cents) : '—'}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          
          <Separator className="my-4" />
          
          <div className="flex justify-end">
            <div className="space-y-2 text-right">
              <div className="flex justify-between gap-8 text-sm font-medium">
                <span className="text-muted-foreground">Total Debits:</span>
                <span className="tabular-nums">{formatCurrency(totalDebitCents)}</span>
              </div>
              <div className="flex justify-between gap-8 text-sm font-medium">
                <span className="text-muted-foreground">Total Credits:</span>
                <span className="tabular-nums">{formatCurrency(totalCreditCents)}</span>
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
