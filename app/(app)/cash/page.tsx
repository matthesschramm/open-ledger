'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/app/empty-state'
import { Wallet } from 'lucide-react'

import { formatDate } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default function CashPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [cashAccounts, setCashAccounts] = useState<any[]>([])
  const [cashLines, setCashLines] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) {
        router.push('/login')
        return
      }

      const { data: accountsData } = await supabase
        .from('accounts')
        .select('*')
        .eq('is_cash', true)
        .eq('is_active', true)
        .order('code')

      if (accountsData) {
        setCashAccounts(accountsData)

        // Get all journal lines for cash accounts
        const allLines = []
        for (const account of accountsData) {
          const { data: lines } = await supabase
            .from('journal_lines')
            .select(`
            *,
            journal:journals!inner(number, entry_date, description, status),
            account:accounts(code, name)
          `)
            .eq('account_id', account.id)
            .in('journal.status', ['Posted', 'Reversed'])
            .order('journal(entry_date)', { ascending: false })

          if (lines) allLines.push(...lines)
        }
      
        allLines.sort((a: any, b: any) => 
          new Date(b.journal.entry_date).getTime() - new Date(a.journal.entry_date).getTime()
        )
      
        setCashLines(allLines)
      }
    } catch (error) {
      console.error('Error loading cash data:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  if (cashAccounts.length === 0) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <h1 className="text-3xl font-semibold tracking-tight">Cash Management</h1>
          <p className="text-muted-foreground">Monitor cash accounts and transactions</p>
        </div>
        <EmptyState
          icon={<Wallet className="h-8 w-8 text-coral" />}
          title="No cash account"
          description="Add the operating account before you record spend."
          actions={[]}
        />
      </div>
    )
  }

  // Calculate totals
  const totalCash = cashLines.reduce((sum, line: any) => {
    return sum + (line.debit_cents - line.credit_cents)
  }, 0) / 100

  const thisMonth = new Date().getMonth()
  const thisYear = new Date().getFullYear()
  const monthlyLines = cashLines.filter((line: any) => {
    const lineDate = new Date(line.journal.entry_date)
    return lineDate.getMonth() === thisMonth && lineDate.getFullYear() === thisYear
  })

  const cashIn = monthlyLines.reduce((sum, line: any) => sum + line.debit_cents, 0) / 100
  const cashOut = monthlyLines.reduce((sum, line: any) => sum + line.credit_cents, 0) / 100

  // Calculate balances per account
  const accountBalances: Record<string, number> = {}
  cashLines.forEach((line: any) => {
    if (!accountBalances[line.account_id]) {
      accountBalances[line.account_id] = 0
    }
    accountBalances[line.account_id] += (line.debit_cents - line.credit_cents)
  })

  return (
    <div className="p-8">
      <div className="mb-8">
        <h1 className="text-3xl font-semibold tracking-tight">Cash Management</h1>
        <p className="text-muted-foreground">
          Monitor cash accounts and transactions
        </p>
      </div>

      <div className="mb-6 grid gap-6 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Total Cash
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className={`text-2xl font-semibold tabular-nums ${totalCash < 0 ? 'text-red-700' : ''}`}>
              {formatCurrency(Math.round(totalCash * 100))}
            </div>
            <p className="mt-1 text-xs text-muted-foreground">
              Across {cashAccounts.length} accounts
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Cash In (MTD)
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-semibold tabular-nums text-green-700">
              {formatCurrency(Math.round(cashIn * 100))}
            </div>
            <p className="mt-1 text-xs text-muted-foreground">
              This month inflows
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Cash Out (MTD)
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-semibold tabular-nums text-red-700">
              {formatCurrency(Math.round(cashOut * 100))}
            </div>
            <p className="mt-1 text-xs text-muted-foreground">
              This month outflows
            </p>
          </CardContent>
        </Card>
      </div>

      <Card className="mb-6">
        <CardHeader>
          <CardTitle>Cash Accounts</CardTitle>
          <CardDescription>{cashAccounts.length} active cash accounts</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Account</TableHead>
                <TableHead>Name</TableHead>
                <TableHead className="text-right">Balance</TableHead>
                <TableHead className="w-[100px]"></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {cashAccounts.map((account: any) => (
                <TableRow key={account.id}>
                  <TableCell className="font-mono text-sm">{account.code}</TableCell>
                  <TableCell className="font-medium">{account.name}</TableCell>
                  <TableCell className={`text-right tabular-nums ${(accountBalances[account.id] || 0) < 0 ? 'text-red-700' : ''}`}>
                    {formatCurrency(accountBalances[account.id] || 0)}
                  </TableCell>
                  <TableCell>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => router.push(`/accounts/${account.id}`)}
                      aria-label={`View account ${account.code} – ${account.name}`}
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

      <Card>
        <CardHeader>
          <CardTitle>Cash Register</CardTitle>
          <CardDescription>All posted cash transactions</CardDescription>
        </CardHeader>
        <CardContent>
          {cashLines.length === 0 ? (
            <p className="text-sm text-muted-foreground py-8 text-center">
              No cash transactions yet
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Date</TableHead>
                  <TableHead>Journal</TableHead>
                  <TableHead>Account</TableHead>
                  <TableHead>Description</TableHead>
                  <TableHead className="text-right">In</TableHead>
                  <TableHead className="text-right">Out</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {cashLines.slice(0, 50).map((line: any) => (
                  <TableRow key={line.id}>
                    <TableCell className="text-sm">
                      {formatDate(line.journal.entry_date)}
                    </TableCell>
                    <TableCell>
                      <button
                        onClick={() => router.push(`/journals/${line.journal_id}`)}
                        className="text-sm text-blue-600 hover:underline"
                      >
                        {line.journal.number || 'Draft'}
                      </button>
                    </TableCell>
                    <TableCell className="text-sm font-mono">
                      {line.account.code}
                    </TableCell>
                    <TableCell className="text-sm">
                      {line.memo || line.journal.description}
                    </TableCell>
                    <TableCell className="text-right tabular-nums text-green-700">
                      {line.debit_cents > 0 && formatCurrency(line.debit_cents)}
                    </TableCell>
                    <TableCell className="text-right tabular-nums text-red-700">
                      {line.credit_cents > 0 && formatCurrency(line.credit_cents)}
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
