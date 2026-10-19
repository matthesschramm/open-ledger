'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { ArrowLeft } from 'lucide-react'
import { formatDate } from '@/lib/format-date'
import { formatCurrency } from '@/lib/money'

export default function AccountDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const router = useRouter()
  const supabase = createClient()
  
  const [accountId, setAccountId] = useState<string | null>(null)
  const [account, setAccount] = useState<any>(null)
  const [lines, setLines] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    params.then(p => setAccountId(p.id))
  }, [params])

  useEffect(() => {
    if (accountId) {
      loadData()
    }
  }, [accountId])

  async function loadData() {
    if (!accountId) return

    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) {
        router.push('/login')
        return
      }

      const { data: accountData } = await supabase
        .from('accounts')
        .select('*')
        .eq('id', accountId)
        .single()

      if (accountData) setAccount(accountData)

      const { data: orgId } = await supabase.rpc('current_org_id')

      const { data: linesData } = await supabase.rpc('get_account_ledger', {
        p_organization_id: orgId,
        p_account_id: accountId,
        p_start_date: null,
        p_end_date: null,
      })

      if (linesData) setLines(linesData)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  if (!account) {
    return <div className="p-8">Account not found</div>
  }

  const runningBalance = lines.length > 0 ? lines[lines.length - 1].running_balance_cents : 0
  
  // For Asset and Expense accounts (debit normal), balance is signed as-is
  // For Liability, Equity, Revenue accounts (credit normal), negate the balance
  const signedBalance = ['Liability', 'Equity', 'Revenue'].includes(account.type)
    ? -runningBalance
    : runningBalance

  return (
    <div className="p-8">
      <div className="mb-8">
        <Button variant="ghost" onClick={() => router.back()} className="mb-4">
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back to Chart of Accounts
        </Button>
        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Account ledger</h1>
            <p className="text-muted-foreground">{account.code} - {account.name}</p>
          </div>
          <div className="text-right">
            <div className="text-sm text-muted-foreground">Current Balance</div>
            <div className="text-2xl font-semibold">
              {formatCurrency(signedBalance)}
            </div>
          </div>
        </div>
      </div>

      <Card>
        <CardContent className="pt-6">
          {lines.length === 0 ? (
            <div className="py-8 text-center">
              <p className="text-sm text-muted-foreground mb-4">Nothing to report yet</p>
              <Button onClick={() => router.push('/journals/new')}>
                New journal
              </Button>
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Date</TableHead>
                  <TableHead>Journal</TableHead>
                  <TableHead>Memo</TableHead>
                  <TableHead className="text-right">Debit</TableHead>
                  <TableHead className="text-right">Credit</TableHead>
                  <TableHead className="text-right">Running balance</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {lines.map((line: any, index: number) => (
                  <TableRow key={index}>
                    <TableCell className="text-sm">
                      {formatDate(line.entry_date)}
                    </TableCell>
                    <TableCell>
                      <button
                        onClick={() => router.push(`/journals/${line.journal_id}`)}
                        className="text-sm text-blue-600 hover:underline"
                      >
                        {line.journal_number || 'Draft'}
                      </button>
                    </TableCell>
                    <TableCell className="text-sm">
                      {line.line_memo || line.journal_description}
                      {line.status === 'Reversed' && (
                        <Badge variant="secondary" className="ml-2 text-xs">Reversed</Badge>
                      )}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {line.debit_cents > 0 && formatCurrency(line.debit_cents)}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {line.credit_cents > 0 && formatCurrency(line.credit_cents)}
                    </TableCell>
                    <TableCell className="text-right tabular-nums font-medium">
                      {(() => {
                        // For Asset and Expense accounts (debit normal), balance is signed as-is
                        // For Liability, Equity, Revenue accounts (credit normal), negate the balance
                        const signedBalance = ['Liability', 'Equity', 'Revenue'].includes(account.type)
                          ? -line.running_balance_cents
                          : line.running_balance_cents
                        return formatCurrency(signedBalance)
                      })()}
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
