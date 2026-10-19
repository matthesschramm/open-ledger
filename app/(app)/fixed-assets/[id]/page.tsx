'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { getLocalDateString } from '@/lib/format-date'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatCurrency } from '@/lib/money'

export default function FixedAssetDetailPage() {
  const params = useParams<{ id: string }>()
  const router = useRouter()
  const supabase = createClient()
  const [asset, setAsset] = useState<any>(null)
  const [runs, setRuns] = useState<any[]>([])
  const [role, setRole] = useState<string | null>(null)
  const [cashAccounts, setCashAccounts] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [disposing, setDisposing] = useState(false)
  const [running, setRunning] = useState(false)
  const [disposalDate, setDisposalDate] = useState(getLocalDateString())
  const [proceeds, setProceeds] = useState('0')
  const [cashAccountId, setCashAccountId] = useState('')
  const [periodStart, setPeriodStart] = useState(getLocalDateString().slice(0, 7) + '-01')

  useEffect(() => {
    loadData()
  }, [params.id])

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: roleData } = await supabase.rpc('current_role')
    setRole(roleData)

    const { data: assetData, error: assetError } = await supabase
      .from('fixed_assets')
      .select('*')
      .eq('id', params.id)
      .maybeSingle()

    if (assetError || !assetData) {
      setError('Asset not found')
      setLoading(false)
      return
    }
    setAsset(assetData)

    const { data: runData } = await supabase
      .from('fixed_asset_depreciation_runs')
      .select('*')
      .eq('asset_id', params.id)
      .order('period_start')
    if (runData) setRuns(runData)

    const { data: cash } = await supabase
      .from('accounts')
      .select('id, code, name')
      .eq('is_cash', true)
      .eq('is_active', true)
      .order('code')
    if (cash) {
      setCashAccounts(cash)
      const operating = cash.find((account) => account.code === '1010')
      setCashAccountId(operating?.id || cash[0]?.id || '')
    }

    setLoading(false)
  }

  async function handleDepreciation() {
    setError(null)
    setRunning(true)
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      const { data, error: rpcError } = await supabase.rpc('run_depreciation', {
        p_period_start: periodStart,
        p_user_id: user.id,
      })
      if (rpcError) throw rpcError
      if (!data?.success) throw new Error(data?.error || 'Depreciation failed')
      await loadData()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Depreciation failed')
    } finally {
      setRunning(false)
    }
  }

  async function handleDispose(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setDisposing(true)
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      const proceedsCents = Math.round(parseFloat(proceeds || '0') * 100)
      const { data, error: rpcError } = await supabase.rpc('dispose_fixed_asset', {
        p_asset_id: params.id,
        p_disposal_date: disposalDate,
        p_proceeds_cents: proceedsCents,
        p_cash_account_id: proceedsCents > 0 ? cashAccountId : null,
        p_user_id: user.id,
      })
      if (rpcError) throw rpcError
      if (!data?.success) throw new Error(data?.error || 'Dispose failed')
      await loadData()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Dispose failed')
    } finally {
      setDisposing(false)
    }
  }

  if (loading) return <div className="p-8">Loading...</div>
  if (!asset) return <div className="p-8">{error || 'Asset not found'}</div>

  const canWrite = role === 'owner' || role === 'bookkeeper'
  const nbv = asset.cost_cents - asset.accum_dep_cents

  return (
    <div className="p-8">
      <Link href="/fixed-assets">
        <Button variant="ghost" size="sm" className="mb-4">← Back to fixed assets</Button>
      </Link>
      <div className="mb-8 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">{asset.number}</h1>
          <p className="text-muted-foreground">{asset.description}</p>
        </div>
        <Badge variant={asset.status === 'disposed' ? 'default' : 'outline'}>
          {asset.status.replaceAll('_', ' ')}
        </Badge>
      </div>

      <div className="mb-6 grid gap-6 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">Cost</CardTitle>
          </CardHeader>
          <CardContent className="text-2xl font-semibold tabular-nums">{formatCurrency(asset.cost_cents)}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">Accumulated depreciation</CardTitle>
          </CardHeader>
          <CardContent className="text-2xl font-semibold tabular-nums">{formatCurrency(asset.accum_dep_cents)}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium text-muted-foreground">Net book value</CardTitle>
          </CardHeader>
          <CardContent className="text-2xl font-semibold tabular-nums">{formatCurrency(nbv)}</CardContent>
        </Card>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Details</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <p>Class: {asset.class.replaceAll('_', ' ')}</p>
            <p>Method: {asset.method.replaceAll('_', ' ')}</p>
            <p>Useful life: {asset.useful_life_months} months</p>
            <p>Residual: {formatCurrency(asset.residual_cents)}</p>
            <p>Acquired: {asset.acquisition_date}</p>
            <p>In service: {asset.in_service_date}</p>
            {asset.serial_number && <p>Serial: {asset.serial_number}</p>}
            {asset.location && <p>Location: {asset.location}</p>}
            {asset.notes && <p>Notes: {asset.notes}</p>}
            {asset.recognition_journal_id && (
              <p>
                <Link className="underline" href={`/journals/${asset.recognition_journal_id}`}>
                  Acquisition journal
                </Link>
              </p>
            )}
            {asset.disposal_journal_id && (
              <p>
                <Link className="underline" href={`/journals/${asset.disposal_journal_id}`}>
                  Disposal journal
                </Link>
              </p>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Depreciation runs</CardTitle>
            <CardDescription>One row per month charged</CardDescription>
          </CardHeader>
          <CardContent>
            {runs.length === 0 ? (
              <p className="text-sm text-muted-foreground">No charges yet.</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Period</TableHead>
                    <TableHead className="text-right">Amount</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {runs.map((run) => (
                    <TableRow key={run.id}>
                      <TableCell className="font-mono text-sm">{run.period_start}</TableCell>
                      <TableCell className="text-right tabular-nums">{formatCurrency(run.amount_cents)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
            {canWrite && asset.status === 'in_use' && (
              <div className="mt-4 flex items-end gap-2">
                <div className="space-y-2">
                  <Label htmlFor="period">Run month</Label>
                  <Input id="period" type="date" value={periodStart} onChange={(e) => setPeriodStart(e.target.value)} />
                </div>
                <Button type="button" variant="outline" disabled={running} onClick={handleDepreciation}>
                  {running ? 'Posting...' : 'Run depreciation'}
                </Button>
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {canWrite && asset.status !== 'disposed' && (
        <Card className="mt-6 max-w-xl">
          <CardHeader>
            <CardTitle>Dispose</CardTitle>
            <CardDescription>Takes this month&apos;s depreciation if it has not run, then clears the asset.</CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleDispose} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="disp-date">Disposal date</Label>
                <Input id="disp-date" type="date" value={disposalDate} onChange={(e) => setDisposalDate(e.target.value)} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="proceeds">Proceeds</Label>
                <Input id="proceeds" inputMode="decimal" value={proceeds} onChange={(e) => setProceeds(e.target.value)} />
              </div>
              {parseFloat(proceeds || '0') > 0 && (
                <div className="space-y-2">
                  <Label htmlFor="cash">Cash account</Label>
                  <select
                    id="cash"
                    className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                    value={cashAccountId}
                    onChange={(e) => setCashAccountId(e.target.value)}
                  >
                    {cashAccounts.map((account) => (
                      <option key={account.id} value={account.id}>
                        {account.code} {account.name}
                      </option>
                    ))}
                  </select>
                </div>
              )}
              <Button type="submit" variant="destructive" disabled={disposing}>
                {disposing ? 'Posting...' : 'Dispose asset'}
              </Button>
            </form>
          </CardContent>
        </Card>
      )}

      {error && <p className="mt-4 text-sm text-red-700">{error}</p>}
    </div>
  )
}
