'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Landmark, Download } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { EmptyState } from '@/components/app/empty-state'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatCurrency } from '@/lib/money'

function yearStart() {
  return `${new Date().getFullYear()}-01-01`
}

function yearEnd() {
  return `${new Date().getFullYear()}-12-31`
}

export default function PpeRollforwardPage() {
  const router = useRouter()
  const supabase = createClient()
  const [startDate, setStartDate] = useState(yearStart())
  const [endDate, setEndDate] = useState(yearEnd())
  const [rows, setRows] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    loadData()
  }, [startDate, endDate])

  async function loadData() {
    setLoading(true)
    setError(null)
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgId } = await supabase.rpc('current_org_id')
    const { data, error: rpcError } = await supabase.rpc('get_ppe_rollforward', {
      p_organization_id: orgId,
      p_start_date: startDate,
      p_end_date: endDate,
    })

    if (rpcError) {
      setError("Couldn't load this report.")
      setRows([])
    } else {
      setRows(data || [])
    }
    setLoading(false)
  }

  async function handleExport() {
    try {
      const url = `/api/exports/ppe-rollforward?start_date=${startDate}&end_date=${endDate}`
      const response = await fetch(url)
      
      if (!response.ok) {
        console.error('Export failed:', response.status, response.statusText)
        return
      }
      
      const blob = await response.blob()
      const downloadUrl = window.URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = downloadUrl
      a.download = `ppe-rollforward-${startDate}-${endDate}.csv`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      window.URL.revokeObjectURL(downloadUrl)
    } catch (error) {
      console.error('Export error:', error)
    }
  }

  return (
    <div className="p-8">
      <Link href="/reports">
        <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
      </Link>
      <div className="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">PPE rollforward</h1>
          <p className="text-muted-foreground">IAS 16.73 by class, from the register</p>
        </div>
        <div className="flex gap-2">
          <input
            type="date"
            value={startDate}
            onChange={(e) => setStartDate(e.target.value)}
            className="rounded-md border border-neutral-300 px-3 py-2 text-sm"
          />
          <input
            type="date"
            value={endDate}
            onChange={(e) => setEndDate(e.target.value)}
            className="rounded-md border border-neutral-300 px-3 py-2 text-sm"
          />
          {!loading && !error && rows.length > 0 && (
            <Button variant="outline" size="sm" onClick={handleExport}>
              <Download className="mr-2 h-4 w-4" />
              Export CSV
            </Button>
          )}
        </div>
      </div>

      {loading ? (
        <div>Loading...</div>
      ) : error ? (
        <p className="text-sm text-red-700">{error}</p>
      ) : rows.length === 0 ? (
        <EmptyState
          icon={<Landmark className="h-8 w-8 text-coral" />}
          title="Nothing on the register"
          description="Register a fixed asset, then this report can add up."
          actions={[{ label: 'Register asset', href: '/fixed-assets/new' }]}
        />
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>Carrying amount</CardTitle>
            <CardDescription>Cost model, straight-line unless noted</CardDescription>
          </CardHeader>
          <CardContent className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Class</TableHead>
                  <TableHead>Lives</TableHead>
                  <TableHead className="text-right">Opening gross</TableHead>
                  <TableHead className="text-right">Additions</TableHead>
                  <TableHead className="text-right">Disposals</TableHead>
                  <TableHead className="text-right">Closing gross</TableHead>
                  <TableHead className="text-right">Opening accum.</TableHead>
                  <TableHead className="text-right">Depreciation</TableHead>
                  <TableHead className="text-right">Disp. accum.</TableHead>
                  <TableHead className="text-right">Closing NBV</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.asset_class}>
                    <TableCell className="font-medium">{row.asset_class.replaceAll('_', ' ')}</TableCell>
                    <TableCell>{row.useful_lives}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.opening_gross_cents)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.additions_cents)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.disposals_gross_cents)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.closing_gross_cents)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.opening_accum_cents)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.depreciation_cents)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.disposals_accum_cents)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatCurrency(row.closing_nbv_cents)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
