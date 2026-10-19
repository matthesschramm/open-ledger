import { createClient } from '@/lib/supabase/server'
import { NextResponse } from 'next/server'

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url)
  const asOfDate = searchParams.get('as_of_date') || new Date().toISOString().split('T')[0]

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
  
  const { data: rows } = await supabase.rpc('get_balance_sheet', {
    p_organization_id: orgId,
    p_as_of_date: asOfDate,
  })

  if (!rows) {
    return new NextResponse('No data', { status: 404 })
  }

  const csvRows = [
    ['Balance Sheet - ' + (orgData?.name || 'Organization')],
    ['As of ' + new Date(asOfDate).toLocaleDateString()],
    [''],
    ['Section', 'Account Code', 'Account Name', 'Amount'],
    ...rows.map((row: any) => [
      row.section,
      row.account_code || '',
      row.account_name,
      (Math.abs(row.balance_cents / 100)).toFixed(2),
    ]),
  ]

  const csv = csvRows.map(row => row.join(',')).join('\n')

  return new NextResponse(csv, {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': `attachment; filename="balance-sheet-${asOfDate}.csv"`,
    },
  })
}
