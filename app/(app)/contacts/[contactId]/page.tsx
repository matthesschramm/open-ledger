import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { redirect, notFound } from 'next/navigation'

function formatCents(cents: number) {
  return (cents / 100).toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
  })
}

export default async function ContactDetailPage({
  params,
}: {
  params: Promise<{ contactId: string }>
}) {
  const { contactId } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: contact } = await supabase
    .from('contacts')
    .select('id, name, email, type')
    .eq('id', contactId)
    .single()

  if (!contact) notFound()

  // Server-side aggregation for outstanding balances (no row limit)
  const { data: billTotals } = await supabase
    .from('bills')
    .select('total_cents, paid_cents')
    .eq('vendor_id', contactId)
    .eq('status', 'Open')
  
  const { data: invoiceTotals } = await supabase
    .from('invoices')
    .select('total_cents, received_cents')
    .eq('customer_id', contactId)
    .in('status', ['Posted', 'Paid'])

  const unpaid = (billTotals || []).reduce((sum, b) => sum + (b.total_cents || 0) - (b.paid_cents || 0), 0)
  const outstandingReceivable = (invoiceTotals || []).reduce((sum, i) => sum + (i.total_cents || 0) - (i.received_cents || 0), 0)

  // Fetch bills and invoices for history display (keep 50-row limit for UI)
  const { data: bills } = await supabase
    .from('bills')
    .select('id, number, bill_date, status, total_cents, paid_cents')
    .eq('vendor_id', contactId)
    .order('bill_date', { ascending: false })
    .limit(50)

  const { data: invoices } = await supabase
    .from('invoices')
    .select('id, number, invoice_date, status, total_cents, received_cents')
    .eq('customer_id', contactId)
    .order('invoice_date', { ascending: false })
    .limit(50)

  // Fetch supplier credits for this contact
  const { data: supplierCredits } = await supabase
    .from('supplier_credits')
    .select('remaining_cents')
    .eq('contact_id', contactId)
    .eq('status', 'open')

  // Fetch customer credits for this contact
  const { data: customerCredits } = await supabase
    .from('customer_credits')
    .select('remaining_cents')
    .eq('contact_id', contactId)
    .eq('status', 'open')

  const billRows = bills || []
  const invoiceRows = invoices || []

  // Calculate available credits (separate from outstanding balances for GL tie)
  const totalSupplierCredits = (supplierCredits || []).reduce((sum, c) => sum + (c.remaining_cents || 0), 0)
  const totalCustomerCredits = (customerCredits || []).reduce((sum, c) => sum + (c.remaining_cents || 0), 0)

  const history = [
    ...billRows.map((b) => ({
      id: b.id,
      href: `/bills/${b.id}`,
      date: b.bill_date,
      type: 'Bill',
      number: b.number,
      amount: b.total_cents,
      status: b.status,
    })),
    ...invoiceRows.map((i) => ({
      id: i.id,
      href: `/invoices/${i.id}`,
      date: i.invoice_date,
      type: 'Invoice',
      number: i.number,
      amount: i.total_cents,
      status: i.status,
    })),
  ].sort((a, b) => String(b.date).localeCompare(String(a.date)))

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/contacts">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Contacts</Button>
        </Link>
        <div className="flex items-start justify-between">
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-3xl font-semibold tracking-tight">{contact.name}</h1>
              <Badge variant="outline">{contact.type}</Badge>
            </div>
            <p className="mt-1 text-sm text-muted-foreground">
              {contact.email || 'No email'}
            </p>
          </div>
          <div className="text-right space-y-2">
            {/* Always show both Outstanding Payable and Receivable */}
            <div>
              <div className="text-sm text-muted-foreground">
                Outstanding Receivable
              </div>
              <div className="text-3xl font-semibold tabular-nums">
                {formatCents(outstandingReceivable)}
              </div>
            </div>
            <div>
              <div className="text-sm text-muted-foreground">
                Outstanding Payable
              </div>
              <div className="text-3xl font-semibold tabular-nums">
                {formatCents(unpaid)}
              </div>
            </div>
            {totalCustomerCredits > 0 && (
              <div>
                <div className="text-sm text-muted-foreground">
                  Customer credit available
                </div>
                <div className="text-xl font-semibold tabular-nums text-green-700">
                  {formatCents(totalCustomerCredits)}
                </div>
              </div>
            )}
            {totalSupplierCredits > 0 && (
              <div>
                <div className="text-sm text-muted-foreground">
                  Supplier credit available
                </div>
                <div className="text-xl font-semibold tabular-nums text-green-700">
                  {formatCents(totalSupplierCredits)}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      <div className="grid gap-6 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Total billed
            </CardTitle>
          </CardHeader>
          <CardContent>
            {(() => {
              const receivableBilled = invoiceRows.filter(i => i.status === 'Posted' || i.status === 'Paid').reduce((sum, i) => sum + (i.total_cents || 0), 0)
              const payableBilled = billRows.filter(b => b.status === 'Open').reduce((sum, b) => sum + (b.total_cents || 0), 0)
              const hasReceivable = receivableBilled > 0
              const hasPayable = payableBilled > 0
              
              if (hasReceivable && hasPayable) {
                return (
                  <div className="space-y-1">
                    <div className="text-lg font-semibold tabular-nums">Receivable: {formatCents(receivableBilled)}</div>
                    <div className="text-lg font-semibold tabular-nums">Payable: {formatCents(payableBilled)}</div>
                  </div>
                )
              }
              return (
                <div className="text-2xl font-semibold tabular-nums">
                  {formatCents(hasReceivable ? receivableBilled : payableBilled)}
                </div>
              )
            })()}
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Settled
            </CardTitle>
          </CardHeader>
          <CardContent>
            {(() => {
              const receivableSettled = invoiceRows.filter(i => i.status === 'Posted' || i.status === 'Paid').reduce((sum, i) => sum + (i.received_cents || 0), 0)
              const payableSettled = billRows.filter(b => b.status === 'Open').reduce((sum, b) => sum + (b.paid_cents || 0), 0)
              const hasReceivable = receivableSettled > 0
              const hasPayable = payableSettled > 0
              
              if (hasReceivable && hasPayable) {
                return (
                  <div className="space-y-1">
                    <div className="text-lg font-semibold tabular-nums text-green-700">Receivable: {formatCents(receivableSettled)}</div>
                    <div className="text-lg font-semibold tabular-nums text-green-700">Payable: {formatCents(payableSettled)}</div>
                  </div>
                )
              }
              return (
                <div className="text-2xl font-semibold tabular-nums text-green-700">
                  {formatCents(hasReceivable ? receivableSettled : payableSettled)}
                </div>
              )
            })()}
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Open
            </CardTitle>
          </CardHeader>
          <CardContent>
            {(() => {
              const hasReceivable = outstandingReceivable > 0
              const hasPayable = unpaid > 0
              
              if (hasReceivable && hasPayable) {
                return (
                  <div className="space-y-1">
                    <div className="text-lg font-semibold tabular-nums text-red-700">Receivable: {formatCents(outstandingReceivable)}</div>
                    <div className="text-lg font-semibold tabular-nums text-red-700">Payable: {formatCents(unpaid)}</div>
                  </div>
                )
              }
              return (
                <div className="text-2xl font-semibold tabular-nums text-red-700">
                  {formatCents(hasReceivable ? outstandingReceivable : unpaid)}
                </div>
              )
            })()}
          </CardContent>
        </Card>
      </div>

      <Card className="mt-6">
        <CardHeader>
          <CardTitle>Transaction history</CardTitle>
          <CardDescription>Bills and invoices for this contact</CardDescription>
        </CardHeader>
        <CardContent>
          {history.length === 0 ? (
            <p className="text-sm text-muted-foreground">No documents yet.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Date</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead>Number</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {history.map((txn) => (
                  <TableRow key={`${txn.type}-${txn.id}`}>
                    <TableCell className="font-mono text-sm">{txn.date}</TableCell>
                    <TableCell>{txn.type}</TableCell>
                    <TableCell className="font-mono text-sm">
                      <Link href={txn.href} className="text-blue-600 hover:underline">
                        {txn.number}
                      </Link>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatCents(txn.amount || 0)}
                    </TableCell>
                    <TableCell>
                      <Badge variant={txn.status === 'Paid' ? 'default' : 'outline'}>
                        {txn.status}
                      </Badge>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
