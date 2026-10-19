'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/app/empty-state'
import { FolderOpen } from 'lucide-react'

export default function AccountsPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [accounts, setAccounts] = useState<any[]>([])
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

    const { data: accountsData } = await supabase
      .from('accounts')
      .select('*')
      .eq('is_active', true)
      .order('code')

    if (accountsData) {
      setAccounts(accountsData)
    }
    
    setLoading(false)
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  if (accounts.length === 0) {
    return (
      <div className="p-8">
        <div className="mb-8 flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Chart of Accounts</h1>
            <p className="text-muted-foreground">All accounts in the ledger</p>
          </div>
          {(currentRole === 'owner' || currentRole === 'bookkeeper') && (
            <Button onClick={() => router.push('/accounts/new')}>
              Add account
            </Button>
          )}
        </div>
        <EmptyState
          icon={<FolderOpen className="h-8 w-8 text-coral" />}
          title="No accounts"
          description="Load a US chart of accounts, or add cash and expense accounts by hand."
          actions={[]}
        />
      </div>
    )
  }

  const accountsByType = accounts.reduce((acc, account) => {
    if (!acc[account.type]) {
      acc[account.type] = []
    }
    acc[account.type].push(account)
    return acc
  }, {} as Record<string, any[]>)

  const typeOrder = ['Asset', 'Liability', 'Equity', 'Revenue', 'Expense']

  return (
    <div className="p-8">
      <div className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Chart of Accounts</h1>
          <p className="text-muted-foreground">
            {accounts.length} active accounts
          </p>
        </div>
        {(currentRole === 'owner' || currentRole === 'bookkeeper') && (
          <Button onClick={() => router.push('/accounts/new')}>
            Add account
          </Button>
        )}
      </div>

      <div className="space-y-6">
        {typeOrder.map(type => {
          const typeAccounts = accountsByType[type] || []
          if (typeAccounts.length === 0) return null

          return (
            <Card key={type}>
              <CardHeader>
                <CardTitle>{type}</CardTitle>
                <CardDescription>{typeAccounts.length} accounts</CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="w-[100px]">Code</TableHead>
                      <TableHead>Name</TableHead>
                      <TableHead className="w-[200px]">Category</TableHead>
                      <TableHead className="w-[100px] pl-5">View</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {typeAccounts.map((account: any) => (
                      <TableRow key={account.id}>
                        <TableCell className="w-[100px] font-mono text-sm">{account.code}</TableCell>
                        <TableCell className="font-medium">{account.name}</TableCell>
                        <TableCell className="w-[200px]">
                          {account.is_cash && <Badge variant="outline" className="mr-2">Cash</Badge>}
                          {account.is_system && <Badge variant="secondary" className="mr-2">System</Badge>}
                          {account.is_header && <Badge variant="outline">Header</Badge>}
                        </TableCell>
                        <TableCell className="w-[100px]">
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
          )
        })}
      </div>
    </div>
  )
}
