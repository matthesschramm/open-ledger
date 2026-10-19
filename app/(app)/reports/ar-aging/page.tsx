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
import { formatDate, getLocalDateString, companyToday } from '@/lib/format-date'
import { FileText } from 'lucide-react'
import { formatInvoiceNumber } from '@/lib/format-invoice'
import { formatCurrency } from '@/lib/money'

export default function ARAgingPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [orgTimezone, setOrgTimezone] = useState<string>('America/New_York')
  const [asOfDate, setAsOfDate] = useState('')
  const [orgName, setOrgName] = useState('')
  const [rows, setRows] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

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
    const { data: orgId } = await supabase.rpc('current_org_id')
    
    const { data: arData } = await supabase.rpc('get_ar_aging', {
      p_organization_id: orgId,
      p_as_of_date: asOfDate,
    })

    if (arData) setRows(arData)
    setLoading(false)
  }

  async function handleExport() {
    try {
      const url = `/api/exports/ar-aging?as_of_date=${asOfDate}`
      const response = await fetch(url)
      
      if (!response.ok) {
        console.error('Export failed:', response.status, response.statusText)
        return
      }
      
      const blob = await response.blob()
      const downloadUrl = window.URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = downloadUrl
      a.download = `ar-aging-${asOfDate}.csv`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      window.URL.revokeObjectURL(downloadUrl)
    } catch (error) {
      console.error('Export error:', error)
    }
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
              <h1 className="text-3xl font-semibold tracking-tight">AR Aging</h1>
              <p className="text-muted-foreground">Unpaid invoices by age</p>
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

  if (rows.length === 0) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <Link href="/reports">
            <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
          </Link>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">AR Aging</h1>
              <p className="text-muted-foreground">Unpaid invoices by age</p>
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
          description="This report shows unpaid customer invoices."
          actions={[{ label: 'New invoice', href: '/invoices/new' }]}
        />
      </div>
    )
  }

  const totalAmount = rows.reduce((sum, r) => sum + (r.amount_due_cents || 0), 0) / 100

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/reports">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Reports</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">AR Aging</h1>
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
          <CardTitle>AR Aging Report</CardTitle>
          <CardDescription>Unpaid invoices by age</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Customer</TableHead>
                <TableHead>Invoice Number</TableHead>
                <TableHead>Date</TableHead>
                <TableHead>Due Date</TableHead>
                <TableHead className="text-right">Amount Due</TableHead>
                <TableHead className="text-right">Days Overdue</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, idx) => (
                <TableRow key={idx}>
                  <TableCell className="font-medium">{row.customer_name}</TableCell>
                  <TableCell>
                    <Link href={`/invoices/${row.invoice_id}`} className="text-blue-600 hover:underline">
                      {formatInvoiceNumber(row.invoice_number, row.invoice_date)}
                    </Link>
                  </TableCell>
                  <TableCell className="text-sm">
                    {formatDate(row.invoice_date)}
                  </TableCell>
                  <TableCell className="text-sm">
                    {row.due_date ? formatDate(row.due_date) : '—'}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatCurrency(row.amount_due_cents)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {row.days_overdue > 0 ? (
                      <span className="text-red-700">{row.days_overdue}</span>
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
