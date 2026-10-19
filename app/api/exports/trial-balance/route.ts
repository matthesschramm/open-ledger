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
  
  const { data: rows } = await supabase.rpc('get_trial_balance', {
    p_organization_id: orgId,
    p_as_of_date: asOfDate,
  })

  if (!rows) {
    return new NextResponse('No data', { status: 404 })
  }

  const totalDebit = rows.reduce((sum: number, row: any) => sum + (row.debit_cents || 0), 0) / 100
  const totalCredit = rows.reduce((sum: number, row: any) => sum + (row.credit_cents || 0), 0) / 100
  const isBalanced = Math.abs(totalDebit - totalCredit) < 0.01

  const csvRows = [
    ['Trial Balance - ' + (orgData?.name || 'Organization')],
    ['As of ' + new Date(asOfDate).toLocaleDateString()],
    [''],
    ['Account Code', 'Account Name', 'Type', 'Debit', 'Credit'],
    ...rows.map((row: any) => [
      row.account_code,
      row.account_name,
      row.account_type,
      row.debit_cents > 0 ? (row.debit_cents / 100).toFixed(2) : '',
      row.credit_cents > 0 ? (row.credit_cents / 100).toFixed(2) : '',
    ]),
    [''],
    ['', '', 'Total', totalDebit.toFixed(2), totalCredit.toFixed(2)],
    ['', '', 'Balanced', isBalanced ? 'Yes' : 'No', ''],
  ]

  const csv = csvRows.map(row => row.join(',')).join('\n')

  return new NextResponse(csv, {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': `attachment; filename="trial-balance-${asOfDate}.csv"`,
    },
  })
}
