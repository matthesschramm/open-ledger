import { createClient } from '@/lib/supabase/server'
import { NextResponse } from 'next/server'

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url)
  const accountId = searchParams.get('account_id')
  const startDate = searchParams.get('start_date') || new Date(new Date().getFullYear(), 0, 1).toISOString().split('T')[0]
  const endDate = searchParams.get('end_date') || new Date().toISOString().split('T')[0]

  if (!accountId) {
    return new NextResponse('Missing account_id', { status: 400 })
  }

  // Validate account_id is a UUID
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  if (!uuidRegex.test(accountId)) {
    return new NextResponse('account_id must be a UUID', { status: 400 })
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    return new NextResponse('Unauthorized', { status: 401 })
  }

  const { data: orgData } = await supabase
    .from('organizations')
    .select('name')
    .single()

  const { data: accountData } = await supabase
    .from('accounts')
    .select('code, name')
    .eq('id', accountId)
    .single()

  const { data: orgId } = await supabase.rpc('current_org_id')
  
  const { data: rows } = await supabase.rpc('get_account_ledger', {
    p_organization_id: orgId,
    p_account_id: accountId,
    p_start_date: startDate,
    p_end_date: endDate,
  })

  if (!rows) {
    return new NextResponse('No data', { status: 404 })
  }

  const csvRows = [
    ['Account Ledger - ' + (orgData?.name || 'Organization')],
    ['Account: ' + accountData?.code + ' - ' + accountData?.name],
    [new Date(startDate).toLocaleDateString() + ' to ' + new Date(endDate).toLocaleDateString()],
    [''],
    ['Date', 'Journal Number', 'Description', 'Debit', 'Credit', 'Balance'],
    ...rows.map((row: any) => [
      new Date(row.entry_date).toLocaleDateString(),
      row.journal_number || 'Draft',
      row.line_memo || row.journal_description,
      row.debit_cents > 0 ? (row.debit_cents / 100).toFixed(2) : '',
      row.credit_cents > 0 ? (row.credit_cents / 100).toFixed(2) : '',
      (row.running_balance_cents / 100).toFixed(2),
    ]),
  ]

  const csv = csvRows.map(row => row.join(',')).join('\n')

  return new NextResponse(csv, {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': `attachment; filename="account-ledger-${accountData?.code}-${startDate}-${endDate}.csv"`,
    },
  })
}
