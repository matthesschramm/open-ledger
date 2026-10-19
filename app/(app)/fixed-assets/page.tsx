'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { Landmark } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { EmptyState } from '@/components/app/empty-state'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatCurrency } from '@/lib/money'

const statusVariant: Record<string, 'default' | 'outline' | 'secondary' | 'destructive'> = {
  in_use: 'outline',
  held_for_sale: 'secondary',
  disposed: 'default',
  impaired: 'destructive',
}

export default function FixedAssetsPage() {
  const router = useRouter()
  const supabase = createClient()
  const [assets, setAssets] = useState<any[]>([])
  const [role, setRole] = useState<string | null>(null)
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
    setRole(roleData)

    const { data } = await supabase
      .from('fixed_assets')
      .select('*')
      .order('number')

    if (data) setAssets(data)
    setLoading(false)
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  const canWrite = role === 'owner' || role === 'bookkeeper'
  const inUse = assets.filter((asset) => asset.status === 'in_use')
  const netBook = inUse.reduce((sum, asset) => sum + asset.cost_cents - asset.accum_dep_cents, 0)

  return (
    <div className="p-8">
      <div className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Fixed assets</h1>
          <p className="text-muted-foreground">
            Register is the source of truth. Journals are generated from it.
          </p>
        </div>
        {canWrite && (
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => router.push('/reports/ppe-rollforward')}>
              PPE rollforward
            </Button>
            <Button onClick={() => router.push('/fixed-assets/new')}>Register asset</Button>
          </div>
        )}
      </div>

      {assets.length === 0 ? (
        <EmptyState
          icon={<Landmark className="h-8 w-8 text-coral" />}
          title="No fixed assets"
          description="Register a purchase at or above the capitalization threshold, or attach an asset already on the books."
          actions={canWrite ? [{ label: 'Register asset', href: '/fixed-assets/new' }] : []}
        />
      ) : (
        <>
          <div className="mb-6 grid gap-6 md:grid-cols-3">
            <Card>
              <CardHeader>
                <CardTitle className="text-sm font-medium text-muted-foreground">In use</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-semibold tabular-nums">{inUse.length}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle className="text-sm font-medium text-muted-foreground">Net book value</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-semibold tabular-nums">{formatCurrency(netBook)}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle className="text-sm font-medium text-muted-foreground">On register</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-semibold tabular-nums">{assets.length}</div>
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader>
              <CardTitle>Register</CardTitle>
              <CardDescription>{assets.length} assets</CardDescription>
            </CardHeader>
            <CardContent>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Number</TableHead>
                    <TableHead>Description</TableHead>
                    <TableHead>Class</TableHead>
                    <TableHead>In service</TableHead>
                    <TableHead className="text-right">Cost</TableHead>
                    <TableHead className="text-right">Accum. dep.</TableHead>
                    <TableHead className="text-right">NBV</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead className="w-[80px]"></TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {assets.map((asset) => (
                    <TableRow key={asset.id}>
                      <TableCell className="font-mono text-sm">{asset.number}</TableCell>
                      <TableCell className="font-medium">{asset.description}</TableCell>
                      <TableCell>{asset.class.replaceAll('_', ' ')}</TableCell>
                      <TableCell className="font-mono text-sm">{asset.in_service_date}</TableCell>
                      <TableCell className="text-right tabular-nums">{formatCurrency(asset.cost_cents)}</TableCell>
                      <TableCell className="text-right tabular-nums">{formatCurrency(asset.accum_dep_cents)}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatCurrency(asset.cost_cents - asset.accum_dep_cents)}
                      </TableCell>
                      <TableCell>
                        <Badge variant={statusVariant[asset.status] || 'outline'}>
                          {asset.status.replaceAll('_', ' ')}
                        </Badge>
                      </TableCell>
                      <TableCell>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => router.push(`/fixed-assets/${asset.id}`)}
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
        </>
      )}
    </div>
  )
}
