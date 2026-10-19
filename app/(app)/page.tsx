import { createClient } from '@/lib/supabase/server'
import { InviteLanding } from '@/components/invite-landing'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import Link from 'next/link'
import { FileText } from 'lucide-react'
import { EmptyState } from '@/components/app/empty-state'
import { KpiTile } from '@/components/app/kpi-tile'
import { formatDate } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default async function HomePage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    return <InviteLanding />
  }

  await supabase.rpc('accept_pending_invitation')

  // Fetch org info
  const { data: org } = await supabase
    .from('organizations')
    .select('name, currency_code')
    .single()

  // Check if this is an empty organization (no posted journals)
  const { count: journalCount } = await supabase
    .from('journals')
    .select('*', { count: 'exact', head: true })
    .neq('status', 'Draft')

  // Show empty state if no non-draft journals exist
  if (!journalCount || journalCount === 0) {
    // Check if a cash account exists
    const { data: cashAccounts } = await supabase
      .from('accounts')
      .select('id')
      .eq('is_cash', true)
      .eq('is_active', true)

    const hasCashAccount = cashAccounts && cashAccounts.length > 0

  return (
    <div className="p-8">
      <div className="mb-8">
        <p className="page-kicker">Overview</p>
        <h1 className="text-3xl font-semibold tracking-tight">Home</h1>
        <p className="text-muted-foreground">
          {user.email && <span>{user.email} · </span>}
          {org?.name || 'Your Organization'}
        </p>
      </div>
      <EmptyState
        icon={<FileText className="h-8 w-8 text-coral" />}
        title="No books yet"
        description={hasCashAccount ? undefined : "Add a cash account, then post an opening journal."}
        actions={
          hasCashAccount
            ? [{ label: 'New journal', href: '/journals/new' }]
            : [
                { label: 'Add cash account', href: '/cash' },
                { label: 'New journal', href: '/journals/new' },
              ]
        }
      />
    </div>
  )
  }

  // Fetch live data
  const { data: cashAccounts } = await supabase
    .from('accounts')
    .select('id, code, name')
    .eq('is_cash', true)
    .eq('is_active', true)

  // Get organization ID once for all RPC calls
  const { data: orgId } = await supabase.rpc('current_org_id')
  
  // Use Melbourne local date for consistency with all other date pickers
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
  const asOfDate = `${year}-${month}-${day}`

  let totalCash = 0
  if (cashAccounts && orgId) {
    for (const account of cashAccounts) {
      const { data: balanceResult } = await supabase.rpc('calculate_account_balance', {
        p_organization_id: orgId,
        p_account_id: account.id,
        p_as_of_date: asOfDate,
      })
      if (balanceResult !== null && balanceResult !== undefined) {
        totalCash += balanceResult
      }
    }
  }

  // Get P&L summary (YTD) - use Melbourne year
  const currentYear = year
  const { data: plData } = await supabase.rpc('get_profit_and_loss', {
    p_organization_id: orgId,
    p_start_date: `${currentYear}-01-01`,
    p_end_date: asOfDate,
  })

  let totalRevenue = 0
  let totalExpenses = 0
  if (plData) {
    for (const row of plData) {
      if (row.section === 'Revenue') {
        totalRevenue += row.amount_cents || 0
      } else if (row.section === 'Expenses') {
        totalExpenses += row.amount_cents || 0
      }
    }
  }
  const netIncome = totalRevenue - totalExpenses

  // Get draft journals count
  const { count: draftCount } = await supabase
    .from('journals')
    .select('*', { count: 'exact', head: true })
    .eq('status', 'Draft')

  // Get overdue bills (due date before today)
  const { data: overdueBills } = await supabase
    .from('bills')
    .select('*')
    .eq('status', 'Open')
    .lt('due_date', asOfDate)
    .order('due_date')
    .limit(5)

  // Get bills due soon (due date today through end of this week)
  // Calculate end of week (Sunday) using Melbourne timezone
  const todayDate = new Date(`${asOfDate}T00:00:00+10:00`)
  const dayOfWeek = todayDate.getDay()
  const daysUntilSunday = dayOfWeek === 0 ? 0 : 7 - dayOfWeek
  const endOfWeek = new Date(todayDate)
  endOfWeek.setDate(todayDate.getDate() + daysUntilSunday)
  const endOfWeekStr = endOfWeek.toISOString().split('T')[0]

  const { data: billsDueSoon } = await supabase
    .from('bills')
    .select('*')
    .eq('status', 'Open')
    .gte('due_date', asOfDate)
    .lte('due_date', endOfWeekStr)
    .order('due_date')
    .limit(5)

  // Get current period status - use Melbourne local date
  const today = asOfDate
  const { data: currentPeriod } = await supabase
    .from('accounting_periods')
    .select('*')
    .lte('start_date', today)
    .gte('end_date', today)
    .single()

  return (
    <div className="p-8">
      <div className="mb-8">
        <p className="page-kicker">Overview</p>
        <h1 className="text-3xl font-semibold tracking-tight">Home</h1>
        <p className="text-muted-foreground">
          {user.email && <span>{user.email} · </span>}
          {org?.name || 'Your Organization'}
        </p>
      </div>

      <div className="mb-8 grid gap-3 md:grid-cols-2 lg:grid-cols-4">
        <KpiTile
          label="Cash Position"
          value={formatCurrency(totalCash)}
          hint="Operating cash and reserves"
        />
        <KpiTile
          label={`YTD ${netIncome >= 0 ? 'Surplus' : 'Deficit'}`}
          value={
            <span className={netIncome < 0 ? 'text-coral' : undefined}>
              {formatCurrency(Math.abs(netIncome))}
            </span>
          }
          hint={`Revenue ${formatCurrency(totalRevenue)} • Expenses ${formatCurrency(totalExpenses)}`}
        />
        <KpiTile
          label="Draft Entries"
          value={draftCount || 0}
          hint={
            draftCount ? (
              <Link href="/journals?status=draft" className="hover:underline">
                View drafts →
              </Link>
            ) : (
              'No pending journals'
            )
          }
        />
        <KpiTile
          label="Bills Summary"
          value={
            <>
              {overdueBills?.length || 0} overdue • {billsDueSoon?.length || 0} due soon
            </>
          }
          hint={
            <Link href="/bills" className="hover:underline">
              View all →
            </Link>
          }
        />
      </div>

      {/* Current Period Status */}
      {currentPeriod && (
        <Card className="mb-8">
          <CardHeader>
            <CardTitle>Current Period</CardTitle>
            <CardDescription>
              {currentPeriod.name} ({new Date(currentPeriod.start_date).toLocaleDateString()} - {new Date(currentPeriod.end_date).toLocaleDateString()})
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="flex items-center gap-2">
              {currentPeriod.is_locked ? (
                <>
                  <span className="status-pill bg-red-50 text-red-700">
                    Locked
                  </span>
                  <span className="text-sm text-ink-soft">
                    No journals can be posted or reversed in this period
                  </span>
                </>
              ) : (
                <>
                  <span className="status-pill bg-green-50 text-green-700">
                    Open
                  </span>
                  <span className="text-sm text-ink-soft">
                    Journals can be posted and reversed
                  </span>
                </>
              )}
            </div>
          </CardContent>
        </Card>
      )}

      {/* Overdue Bills */}
      <Card className="mb-8">
        <CardHeader>
          <CardTitle>Overdue</CardTitle>
          <CardDescription>
            {overdueBills && overdueBills.length > 0
              ? `${overdueBills.length} overdue bills`
              : 'No overdue bills'}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {!overdueBills || overdueBills.length === 0 ? (
            <p className="text-sm text-ink-soft">No overdue bills</p>
          ) : (
            <div className="space-y-3">
              {overdueBills.map((bill) => (
                <div key={bill.id} className="flex items-center justify-between border-b pb-3 last:border-0 last:pb-0">
                  <div className="flex items-center gap-2">
                    <Badge variant="outline" className="text-xs">
                      Overdue
                    </Badge>
                    <div>
                      <Link href={`/bills/${bill.id}`} className="font-medium hover:underline">
                        {bill.number}
                      </Link>
                    <p className="text-sm text-ink-soft">
                      Due {formatDate(bill.due_date)}
                    </p>
                  </div>
                </div>
                <div className="text-right">
                  <p className="font-medium">
                    {formatCurrency(bill.total_cents - bill.paid_cents)}
                  </p>
                </div>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Bills Due Soon */}
      <Card>
        <CardHeader>
          <CardTitle>Bills due soon</CardTitle>
          <CardDescription>
            {billsDueSoon && billsDueSoon.length > 0
              ? `${billsDueSoon.length} bills due this week`
              : 'No bills due soon'}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {!billsDueSoon || billsDueSoon.length === 0 ? (
            <p className="text-sm text-ink-soft">No bills due soon</p>
          ) : (
            <div className="space-y-3">
              {billsDueSoon.map((bill) => (
                <div key={bill.id} className="flex items-center justify-between border-b pb-3 last:border-0 last:pb-0">
                  <div>
                    <Link href={`/bills/${bill.id}`} className="font-medium hover:underline">
                      {bill.number}
                    </Link>
                    <p className="text-sm text-ink-soft">
                      Due {formatDate(bill.due_date)}
                    </p>
                  </div>
                  <div className="text-right">
                    <p className="font-medium">
                      {formatCurrency(bill.total_cents - bill.paid_cents)}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
