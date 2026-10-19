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
  
  const { data: rows } = await supabase.rpc('get_profit_and_loss', {
    p_organization_id: orgId,
    p_start_date: startDate,
    p_end_date: endDate,
  })

  if (!rows) {
    return new NextResponse('No data', { status: 404 })
  }

  const csvRows = [
    ['Profit & Loss - ' + (orgData?.name || 'Organization')],
    [new Date(startDate).toLocaleDateString() + ' to ' + new Date(endDate).toLocaleDateString()],
    [''],
    ['Section', 'Account Code', 'Account Name', 'Amount'],
    ...rows.map((row: any) => [
      row.section,
      row.account_code || '',
      row.account_name,
      (Math.abs(row.amount_cents / 100)).toFixed(2),
    ]),
  ]

  const csv = csvRows.map(row => row.join(',')).join('\n')

  return new NextResponse(csv, {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': `attachment; filename="profit-and-loss-${startDate}-${endDate}.csv"`,
    },
  })
}
