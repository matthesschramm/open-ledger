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
import { CreditCard } from 'lucide-react'
import { formatDate } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default function BillsPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [bills, setBills] = useState<any[]>([])
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: roleData } = await supabase.rpc('current_role')
    setCurrentRole(roleData)

    const { data: billsData } = await supabase
      .from('bills')
      .select(`
        *,
        contact:contacts(name)
      `)
      .order('bill_date', { ascending: false })

    if (billsData) setBills(billsData)
    setLoading(false)
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  const canCreate = currentRole && ['owner', 'bookkeeper'].includes(currentRole)

  if (bills.length === 0) {
    return (
      <div className="p-8">
        <div className="mb-8 flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Bills</h1>
            <p className="text-muted-foreground">Vendor bills and payables</p>
          </div>
          {canCreate && (
            <Button onClick={() => router.push('/bills/new')}>New Bill</Button>
          )}
        </div>
        <EmptyState
          icon={<CreditCard className="h-8 w-8 text-coral" />}
          title="No bills"
          description="Add a vendor bill, or skip this and post a cash journal if you already paid."
          actions={canCreate ? [{ label: 'New bill', href: '/bills/new' }] : []}
        />
      </div>
    )
  }

  const unpaidBills = bills.filter(b => b.status !== 'Paid' && b.status !== 'Void')
  const paidBills = bills.filter(b => b.status === 'Paid')
  const totalUnpaidCents = unpaidBills.reduce((sum, bill) => sum + bill.total_cents, 0)
  const totalPaidCents = paidBills.reduce((sum, bill) => sum + bill.total_cents, 0)

  // Use Melbourne timezone for consistent date calculation
  const formatter = new Intl.DateTimeFormat('en-AU', {
    timeZone: 'Australia/Melbourne',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  })
  const parts = formatter.formatToParts(new Date())
  const year = parts.find(p => p.type === 'year')?.value
  const month = parts.find(p => p.type === 'month')?.value
  const day = parts.find(p => p.type === 'day')?.value
  const todayStr = `${year}-${month}-${day}`

  // Calculate end of week (Sunday)
  const todayDate = new Date(`${todayStr}T00:00:00+10:00`)
  const dayOfWeek = todayDate.getDay()
  const daysUntilSunday = dayOfWeek === 0 ? 0 : 7 - dayOfWeek
  const endOfWeek = new Date(todayDate)
  endOfWeek.setDate(todayDate.getDate() + daysUntilSunday)
  const endOfWeekStr = endOfWeek.toISOString().split('T')[0]

  // Overdue: due date before today
  const overdueBills = unpaidBills.filter(b => {
    if (!b.due_date) return false
    return b.due_date < todayStr
  })
  const totalOverdueCents = overdueBills.reduce((sum, bill) => sum + bill.total_cents, 0)

  // Due this week: due date today through end of this week
  const dueSoon = unpaidBills.filter(b => {
    if (!b.due_date) return false
    return b.due_date >= todayStr && b.due_date <= endOfWeekStr
  })
  const totalDueSoonCents = dueSoon.reduce((sum, bill) => sum + bill.total_cents, 0)

  const statusColorMap: Record<string, any> = {
    'Paid': 'default',
    'Open': 'outline',
    'Overdue': 'destructive',
    'Void': 'secondary',
  }

  return (
    <div className="p-8">
      <div className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Bills</h1>
          <p className="text-muted-foreground">
            {unpaidBills.length} unpaid, {paidBills.length} paid
          </p>
        </div>
        {canCreate && (
          <Button onClick={() => router.push('/bills/new')}>New Bill</Button>
        )}
      </div>

      <div className="mb-6 grid gap-3 md:grid-cols-2 lg:grid-cols-4">
        <KpiTile
          label="Total Unpaid"
          value={formatCurrency(totalUnpaidCents)}
          hint={`${unpaidBills.length} bills outstanding`}
        />
        <KpiTile
          label="Due This Week"
          value={formatCurrency(totalDueSoonCents)}
          hint={`${dueSoon.length} bills`}
        />
        <KpiTile
          label="Overdue"
          value={formatCurrency(totalOverdueCents)}
          hint={`${overdueBills.length} bills`}
        />
        <KpiTile
          label="Paid Total"
          value={formatCurrency(totalPaidCents)}
          hint={`${paidBills.length} bills paid`}
        />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>All Bills</CardTitle>
          <CardDescription>{bills.length} bills in the system</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Vendor</TableHead>
                <TableHead>Bill Number</TableHead>
                <TableHead>Date</TableHead>
                <TableHead>Due Date</TableHead>
                <TableHead className="text-right">Amount</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-[100px]"></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {bills.map((bill) => (
                <TableRow key={bill.id}>
                  <TableCell className="font-medium">{bill.contact?.name || 'Unknown'}</TableCell>
                  <TableCell className="font-mono text-sm">{bill.number}</TableCell>
                  <TableCell className="font-mono text-sm">
                    {formatDate(bill.bill_date)}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {formatDate(bill.due_date) || '-'}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatCurrency(bill.total_cents)}
                  </TableCell>
                  <TableCell>
                    <Badge variant={statusColorMap[bill.status] || 'outline'}>
                      {bill.status}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => router.push(`/bills/${bill.id}`)}
                      aria-label={`View bill ${bill.number}`}
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
