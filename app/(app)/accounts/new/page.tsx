'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import Link from 'next/link'

export default function NewAccountPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [accountType, setAccountType] = useState<string>('')
  const [isCash, setIsCash] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)

    if (!code || !name || !accountType) {
      setError('Code, name, and type are required')
      return
    }

    setSubmitting(true)

    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) {
        router.push('/login')
        return
      }

      const { data: orgId } = await supabase.rpc('current_org_id')

      const { data: account, error: insertError } = await supabase
        .from('accounts')
        .insert({
          organization_id: orgId,
          code,
          name,
          type: accountType,
          category: 'Other',
          is_header: false,
          is_cash: isCash,
          is_system: false,
          is_active: true,
        })
        .select()
        .single()

      if (insertError) {
        if (insertError.code === '23505' || insertError.message?.includes('accounts_organization_id_code_key')) {
          setError('That number is already in the chart.')
        } else {
          setError("Couldn't add this account.")
        }
        setSubmitting(false)
        return
      }

      router.push('/accounts')
    } catch (err: any) {
      setError("Couldn't add this account.")
      setSubmitting(false)
    }
  }

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/accounts">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Chart of Accounts</Button>
        </Link>
        <h1 className="text-3xl font-semibold tracking-tight">Add Account</h1>
        <p className="text-muted-foreground">Create a new account in the chart of accounts</p>
      </div>

      <Card className="max-w-2xl">
        <CardHeader>
          <CardTitle>Account Details</CardTitle>
          <CardDescription>Number, Name, Type, Cash</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-4">
            {error && (
              <div className="rounded-md bg-red-50 p-4 text-sm text-red-700">
                {error}
              </div>
            )}

            <div>
              <Label htmlFor="code">Number</Label>
              <Input
                id="code"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="e.g., 5100"
                required
              />
            </div>

            <div>
              <Label htmlFor="name">Name</Label>
              <Input
                id="name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="e.g., Marketing expenses"
                required
              />
            </div>

            <div>
              <Label htmlFor="type">Type</Label>
              <select
                id="type"
                value={accountType}
                onChange={(e) => setAccountType(e.target.value)}
                className="flex h-10 w-full rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm ring-offset-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-950 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
                required
              >
                <option value="">Select type</option>
                <option value="Asset">Asset</option>
                <option value="Liability">Liability</option>
                <option value="Equity">Equity</option>
                <option value="Revenue">Revenue</option>
                <option value="Expense">Expense</option>
              </select>
            </div>

            <div className="flex items-center space-x-2">
              <input
                type="checkbox"
                id="is_cash"
                checked={isCash}
                onChange={(e) => setIsCash(e.target.checked)}
                className="h-4 w-4 rounded border-gray-300"
              />
              <Label htmlFor="is_cash" className="font-normal">
                Cash
              </Label>
            </div>

            <div className="flex gap-2">
              <Button type="submit" disabled={submitting}>
                {submitting ? 'Adding...' : 'Add account'}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => router.push('/accounts')}
              >
                Cancel
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
