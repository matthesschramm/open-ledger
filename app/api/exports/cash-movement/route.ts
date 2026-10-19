import { createClient } from '@/lib/supabase/server'
import { NextResponse } from 'next/server'

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url)
  const startDate = searchParams.get('start_date') || new Date(new Date().getFullYear(), 0, 1).toISOString().split('T')[0]
  const endDate = searchParams.get('end_date') || new Date().toISOString().split('T')[0]

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    return new NextResponse('Unauthorized', { status: 401 })
  }

  const { data: orgData } = await supabase
    .from('organizations')
    .select('name')
    .single()

  const { data: orgId } = await supabase.rpc('current_org_id')
  
  const { data: rows } = await supabase.rpc('get_cash_movement', {
    p_organization_id: orgId,
    p_start_date: startDate,
    p_end_date: endDate,
  })

  if (!rows) {
    return new NextResponse('No data', { status: 404 })
  }

  const csvRows = [
    ['Cash Movement - ' + (orgData?.name || 'Organization')],
    [new Date(startDate).toLocaleDateString() + ' to ' + new Date(endDate).toLocaleDateString()],
    [''],
    ['Counter Account Code', 'Counter Account Name', 'Cash In', 'Cash Out', 'Net'],
    ...rows
      .filter((row: any) => {
        const net = row.net_change_cents
        return typeof net === 'number' && Number.isFinite(net)
      })
      .map((row: any) => {
        const netChangeCents = row.net_change_cents
        const cashInCents = Math.max(netChangeCents, 0)
        const cashOutCents = Math.max(-netChangeCents, 0)
        
        return [
          row.counter_account_code,
          row.counter_account_name,
          cashInCents > 0 ? (cashInCents / 100).toFixed(2) : '',
          cashOutCents > 0 ? (cashOutCents / 100).toFixed(2) : '',
          (netChangeCents / 100).toFixed(2),
        ]
      }),
  ]

  const csv = csvRows.map(row => row.join(',')).join('\n')

  return new NextResponse(csv, {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': `attachment; filename="cash-movement-${startDate}-${endDate}.csv"`,
    },
  })
}
