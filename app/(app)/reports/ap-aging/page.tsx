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
import { formatCurrency } from '@/lib/money'

export default function APAgingPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [asOfDate, setAsOfDate] = useState(new Date().toISOString().split('T')[0])
  const [orgName, setOrgName] = useState('')
  const [rows, setRows] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadData()
  }, [asOfDate])

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgData } = await supabase
      .from('organizations')
      .select('name')
      .single()
    if (orgData) setOrgName(orgData.name)

    const { data: orgId } = await supabase.rpc('current_org_id')
    
    const { data: apData } = await supabase.rpc('get_ap_aging', {
      p_organization_id: orgId,
      p_as_of_date: asOfDate,
    })

    if (apData) setRows(apData)
    setLoading(false)
  }

  async function handleExport() {
    const url = `/api/exports/ap-aging?as_of_date=${asOfDate}`
    window.location.href = url
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
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
              <h1 className="text-3xl font-semibold tracking-tight">AP Aging</h1>
              <p className="text-muted-foreground">Unpaid bills by age</p>
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
          description="This report shows unpaid vendor bills. Create your first bill to see it here."
          actions={[{ label: 'New bill', href: '/bills/new' }]}
        />
      </div>
    )
  }

  const totalAmount = rows.reduce((sum, r) => sum + (r.balance_cents || 0), 0) / 100

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/reports">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">AP Aging</h1>
            <p className="text-muted-foreground">
              As of {new Date(asOfDate).toLocaleDateString()} • {orgName}
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
          <CardTitle>AP Aging Report</CardTitle>
          <CardDescription>Unpaid bills by age</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Vendor</TableHead>
                <TableHead>Bill Number</TableHead>
                <TableHead>Date</TableHead>
                <TableHead>Due Date</TableHead>
                <TableHead className="text-right">Amount Due</TableHead>
                <TableHead className="text-right">Days Overdue</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, idx) => (
                <TableRow key={idx}>
                  <TableCell className="font-medium">{row.vendor_name}</TableCell>
                  <TableCell>
                    <Link href={`/bills/${row.bill_id}`} className="text-blue-600 hover:underline">
                      {row.bill_number}
                    </Link>
                  </TableCell>
                  <TableCell className="text-sm">
                    {new Date(row.bill_date).toLocaleDateString()}
                  </TableCell>
                  <TableCell className="text-sm">
                    {row.due_date ? new Date(row.due_date).toLocaleDateString() : '—'}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatCurrency(row.balance_cents)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {row.days_outstanding > 0 ? (
                      <span className="text-red-700">{row.days_outstanding}</span>
                    ) : (
                      <span className="text-green-700">—</span>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          
          <div className="mt-4 flex justify-end">
            <div className="text-right">
              <div className="flex justify-between gap-8 text-lg font-semibold border-t pt-4">
                <span>Total Outstanding:</span>
                <span>{formatCurrency(Math.round(totalAmount * 100))}</span>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
