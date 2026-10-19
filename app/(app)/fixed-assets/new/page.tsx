'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { getLocalDateString } from '@/lib/format-date'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'

const CLASSES = [
  { value: 'equipment', label: 'Equipment' },
  { value: 'furniture', label: 'Furniture' },
  { value: 'leasehold_improvements', label: 'Leasehold improvements' },
  { value: 'intangible', label: 'Intangible' },
]

export default function NewFixedAssetPage() {
  const router = useRouter()
  const supabase = createClient()
  const [role, setRole] = useState<string | null>(null)
  const [threshold, setThreshold] = useState(100000)
  const [creditAccounts, setCreditAccounts] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [alreadyOnBooks, setAlreadyOnBooks] = useState(false)

  const [description, setDescription] = useState('')
  const [assetClass, setAssetClass] = useState('equipment')
  const [cost, setCost] = useState('')
  const [residual, setResidual] = useState('0')
  const [life, setLife] = useState('36')
  const [acquisitionDate, setAcquisitionDate] = useState(getLocalDateString())
  const [inServiceDate, setInServiceDate] = useState(getLocalDateString())
  const [creditAccountId, setCreditAccountId] = useState('')
  const [existingJournalId, setExistingJournalId] = useState('')
  const [broughtForward, setBroughtForward] = useState('0')
  const [broughtForwardAsOf, setBroughtForwardAsOf] = useState('')
  const [broughtForwardJournalId, setBroughtForwardJournalId] = useState('')
  const [serial, setSerial] = useState('')
  const [location, setLocation] = useState('')
  const [notes, setNotes] = useState('')

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
    setRole(roleData)
    if (roleData !== 'owner' && roleData !== 'bookkeeper') {
      router.push('/fixed-assets')
      return
    }

    const { data: org } = await supabase
      .from('organizations')
      .select('capitalization_threshold_cents')
      .single()
    if (org) setThreshold(org.capitalization_threshold_cents)

    const { data: accounts } = await supabase
      .from('accounts')
      .select('id, code, name, type, is_cash, is_header, is_active')
      .eq('is_active', true)
      .eq('is_header', false)
      .in('type', ['Asset', 'Liability'])
      .order('code')

    const credits = (accounts || []).filter((account) => account.is_cash || account.code === '2000')
    setCreditAccounts(credits)
    const cash = credits.find((account) => account.code === '1010')
    if (cash) setCreditAccountId(cash.id)
    setLoading(false)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)

    const costCents = Math.round(parseFloat(cost) * 100)
    const residualCents = Math.round(parseFloat(residual || '0') * 100)
    const lifeMonths = parseInt(life, 10)

    if (!description.trim() || !Number.isFinite(costCents) || costCents <= 0 || !lifeMonths) {
      setError('Description, cost, and useful life are required.')
      return
    }

    setSaving(true)
    try {
      const { data, error: rpcError } = await supabase.rpc('register_fixed_asset', {
        p_description: description.trim(),
        p_class: assetClass,
        p_cost_cents: costCents,
        p_useful_life_months: lifeMonths,
        p_acquisition_date: acquisitionDate,
        p_in_service_date: inServiceDate,
        p_residual_cents: residualCents,
        p_credit_account_id: alreadyOnBooks ? null : creditAccountId,
        p_post_acquisition: !alreadyOnBooks,
        p_existing_journal_id: alreadyOnBooks ? existingJournalId : null,
        p_brought_forward_accum_dep_cents: alreadyOnBooks
          ? Math.round(parseFloat(broughtForward || '0') * 100)
          : 0,
        p_brought_forward_as_of: alreadyOnBooks && broughtForwardAsOf ? broughtForwardAsOf : null,
        p_brought_forward_journal_id: alreadyOnBooks && broughtForwardJournalId
          ? broughtForwardJournalId
          : null,
        p_serial_number: serial.trim() || null,
        p_location: location.trim() || null,
        p_notes: notes.trim() || null,
      })

      if (rpcError) throw rpcError
      if (!data?.success) throw new Error(data?.error || 'Could not register this asset')

      router.push(`/fixed-assets/${data.asset_id}`)
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Could not register this asset')
      setSaving(false)
    }
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  return (
    <div className="p-8">
      <Link href="/fixed-assets">
        <Button variant="ghost" size="sm" className="mb-4">← Back to fixed assets</Button>
      </Link>
      <h1 className="text-3xl font-semibold tracking-tight">Register asset</h1>
      <p className="mb-8 text-muted-foreground">
        Capitalize at or above ${(threshold / 100).toLocaleString('en-US', { minimumFractionDigits: 2 })}.
        Below that, expense the purchase.
      </p>

      <form onSubmit={handleSubmit} className="max-w-2xl space-y-6">
        <Card>
          <CardHeader>
            <CardTitle>Asset</CardTitle>
            <CardDescription>Straight-line, full month from the in-service month.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="description">Description</Label>
              <Input id="description" value={description} onChange={(e) => setDescription(e.target.value)} required />
            </div>
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="class">Class</Label>
                <select
                  id="class"
                  className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                  value={assetClass}
                  onChange={(e) => setAssetClass(e.target.value)}
                >
                  {CLASSES.map((item) => (
                    <option key={item.value} value={item.value}>{item.label}</option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="life">Useful life (months)</Label>
                <Input id="life" type="number" min={1} value={life} onChange={(e) => setLife(e.target.value)} required />
              </div>
            </div>
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="cost">Cost</Label>
                <Input id="cost" inputMode="decimal" value={cost} onChange={(e) => setCost(e.target.value)} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="residual">Residual</Label>
                <Input id="residual" inputMode="decimal" value={residual} onChange={(e) => setResidual(e.target.value)} />
              </div>
            </div>
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="acq">Acquisition date</Label>
                <Input id="acq" type="date" value={acquisitionDate} onChange={(e) => setAcquisitionDate(e.target.value)} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="svc">In-service date</Label>
                <Input id="svc" type="date" value={inServiceDate} onChange={(e) => setInServiceDate(e.target.value)} required />
              </div>
            </div>
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="serial">Serial / tag</Label>
                <Input id="serial" value={serial} onChange={(e) => setSerial(e.target.value)} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="location">Location</Label>
                <Input id="location" value={location} onChange={(e) => setLocation(e.target.value)} />
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="notes">Notes</Label>
              <Input id="notes" value={notes} onChange={(e) => setNotes(e.target.value)} />
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={alreadyOnBooks}
                onChange={(e) => setAlreadyOnBooks(e.target.checked)}
              />
              Already posted to the general ledger
            </label>
            {alreadyOnBooks ? (
              <div className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="journal">Existing journal ID</Label>
                  <Input id="journal" value={existingJournalId} onChange={(e) => setExistingJournalId(e.target.value)} required />
                  <p className="text-xs text-muted-foreground">The posted acquisition journal. Copy the ID from the journal URL.</p>
                </div>
                <div className="grid gap-4 md:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="bf">Depreciation already booked</Label>
                    <Input id="bf" inputMode="decimal" value={broughtForward} onChange={(e) => setBroughtForward(e.target.value)} />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="bf-asof">As of</Label>
                    <Input id="bf-asof" type="date" value={broughtForwardAsOf} onChange={(e) => setBroughtForwardAsOf(e.target.value)} />
                  </div>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="bf-journal">Depreciation journal ID</Label>
                  <Input id="bf-journal" value={broughtForwardJournalId} onChange={(e) => setBroughtForwardJournalId(e.target.value)} />
                  <p className="text-xs text-muted-foreground">Required when depreciation is already on the books, so that month is not charged again.</p>
                </div>
              </div>
            ) : (
              <div className="space-y-2">
                <Label htmlFor="credit">Credit account</Label>
                <select
                  id="credit"
                  className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                  value={creditAccountId}
                  onChange={(e) => setCreditAccountId(e.target.value)}
                  required
                >
                  <option value="">Select cash or AP</option>
                  {creditAccounts.map((account) => (
                    <option key={account.id} value={account.id}>
                      {account.code} {account.name}
                    </option>
                  ))}
                </select>
              </div>
            )}
          </CardContent>
        </Card>

        {error && <p className="text-sm text-red-700">{error}</p>}

        <Button type="submit" disabled={saving}>
          {saving ? 'Saving...' : 'Register and post'}
        </Button>
      </form>
    </div>
  )
}
