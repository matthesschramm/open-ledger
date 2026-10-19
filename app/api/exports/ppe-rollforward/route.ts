import { createClient } from '@/lib/supabase/server'
import { NextResponse } from 'next/server'

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url)
  const startDate = searchParams.get('start_date') || `${new Date().getFullYear()}-01-01`
  const endDate = searchParams.get('end_date') || `${new Date().getFullYear()}-12-31`

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
  
  const { data: rows } = await supabase.rpc('get_ppe_rollforward', {
    p_organization_id: orgId,
    p_start_date: startDate,
    p_end_date: endDate,
  })

  if (!rows) {
    return new NextResponse('No data', { status: 404 })
  }

  const csvRows = [
    ['PPE Rollforward - ' + (orgData?.name || 'Organization')],
    [new Date(startDate).toLocaleDateString() + ' to ' + new Date(endDate).toLocaleDateString()],
    [''],
    ['Class', 'Lives', 'Opening Gross', 'Additions', 'Disposals', 'Closing Gross', 'Opening Accum.', 'Depreciation', 'Disp. Accum.', 'Closing NBV'],
    ...rows.map((row: any) => [
      row.asset_class ? row.asset_class.replaceAll('_', ' ') : '',
      row.useful_lives || '',
      (row.opening_gross_cents / 100).toFixed(2),
      (row.additions_cents / 100).toFixed(2),
      (row.disposals_gross_cents / 100).toFixed(2),
      (row.closing_gross_cents / 100).toFixed(2),
      (row.opening_accum_cents / 100).toFixed(2),
      (row.depreciation_cents / 100).toFixed(2),
      (row.disposals_accum_cents / 100).toFixed(2),
      (row.closing_nbv_cents / 100).toFixed(2),
    ]),
  ]

  const csv = csvRows.map(row => row.join(',')).join('\n')

  return new NextResponse(csv, {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': `attachment; filename="ppe-rollforward-${startDate}-${endDate}.csv"`,
    },
  })
}
