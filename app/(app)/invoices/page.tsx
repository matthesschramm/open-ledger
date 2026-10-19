'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { KpiTile } from '@/components/app/kpi-tile'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/app/empty-state'
import { formatDate } from '@/lib/format-date'
import { Receipt } from 'lucide-react'
import { formatInvoiceNumber } from '@/lib/format-invoice'
import { formatCurrency } from '@/lib/money'

export default function InvoicesPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [invoices, setInvoices] = useState<any[]>([])
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    checkAuthAndLoad()
  }, [])

  async function checkAuthAndLoad() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }
    await loadData()
  }

  async function loadData() {
    const { data: roleData } = await supabase.rpc('current_role')
    setCurrentRole(roleData)

    const { data: invoicesData } = await supabase
      .from('invoices')
      .select(`
        *,
        customer:contacts(name)
      `)
      .order('invoice_date', { ascending: false })

    if (invoicesData) setInvoices(invoicesData)
    setLoading(false)
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  const canCreate = currentRole && ['owner', 'bookkeeper'].includes(currentRole)

  if (invoices.length === 0) {
    return (
      <div className="p-8">
        <div className="mb-8 flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Invoices</h1>
            <p className="text-muted-foreground">Customer invoices and receivables</p>
          </div>
          {canCreate && (
            <Button onClick={() => router.push('/invoices/new')}>New invoice</Button>
          )}
        </div>
        <EmptyState
          icon={<Receipt className="h-8 w-8 text-coral" />}
          title="No invoices yet."
          description=""
          actions={canCreate ? [{ label: 'New invoice', href: '/invoices/new' }] : []}
        />
      </div>
    )
  }

  const unpaidInvoices = invoices.filter(i => i.status === 'Posted')
  const paidInvoices = invoices.filter(i => i.status === 'Paid')
  const draftInvoices = invoices.filter(i => i.status === 'Draft' || i.status === 'Quote')
  
  const totalUnpaid = unpaidInvoices.reduce((sum, inv) => sum + (inv.total_cents - inv.received_cents), 0) / 100
  const totalPaid = paidInvoices.reduce((sum, inv) => sum + inv.total_cents, 0) / 100

  const today = new Date()
  const overdue = unpaidInvoices.filter(i => {
    if (!i.due_date) return false
    const due = new Date(i.due_date)
    return due < today
  })
  const totalOverdue = overdue.reduce((sum, inv) => sum + (inv.total_cents - inv.received_cents), 0) / 100

  const statusColorMap: Record<string, any> = {
    'Paid': 'default',
    'Posted': 'outline',
    'Draft': 'outline',
    'Quote': 'secondary',
    'Void': 'secondary',
  }

  return (
    <div className="p-8">
      <div className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Invoices</h1>
          <p className="text-muted-foreground">
            {unpaidInvoices.length} unpaid, {paidInvoices.length} paid, {draftInvoices.length} draft
          </p>
        </div>
        {canCreate && (
          <Button onClick={() => router.push('/invoices/new')}>New invoice</Button>
        )}
      </div>

      <div className="mb-6 grid gap-3 md:grid-cols-3">
        <KpiTile
          label="Outstanding AR"
          value={formatCurrency(Math.round(totalUnpaid * 100))}
          hint={`${unpaidInvoices.length} invoices unpaid`}
        />
        <KpiTile
          label="Overdue"
          value={
            <span className="text-coral">
              {formatCurrency(Math.round(totalOverdue * 100))}
            </span>
          }
          hint={`${overdue.length} invoices`}
        />
        <KpiTile
          label="Collected"
          value={formatCurrency(Math.round(totalPaid * 100))}
          hint={`${paidInvoices.length} invoices paid`}
        />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>All Invoices</CardTitle>
          <CardDescription>{invoices.length} invoices in the system</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Customer</TableHead>
                <TableHead>Invoice Number</TableHead>
                <TableHead>Date</TableHead>
                <TableHead>Due Date</TableHead>
                <TableHead className="text-right">Amount</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-[100px]"></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {invoices.map((invoice) => (
                <TableRow key={invoice.id}>
                  <TableCell className="font-medium">{invoice.customer?.name || 'Unknown'}</TableCell>
                  <TableCell className="font-mono text-sm">{formatInvoiceNumber(invoice.number, invoice.invoice_date)}</TableCell>
                  <TableCell className="font-mono text-sm">
                    {formatDate(invoice.invoice_date)}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {invoice.due_date ? formatDate(invoice.due_date) : '—'}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatCurrency(invoice.total_cents)}
                  </TableCell>
                  <TableCell>
                    <Badge variant={statusColorMap[invoice.status] || 'outline'}>
                      {invoice.status}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => router.push(`/invoices/${invoice.id}`)}
                      aria-label={`View invoice ${formatInvoiceNumber(invoice.number, invoice.invoice_date)}`}
                    >
                      View
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  )
}
