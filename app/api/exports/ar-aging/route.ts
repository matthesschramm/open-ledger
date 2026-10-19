import { createClient } from '@/lib/supabase/server'
import { NextResponse } from 'next/server'

function formatInvoiceForCSV(number: string, invoiceDate: string): string {
  if (!number) return ''
  
  if (number.includes('INV-')) {
    return number
  }
  
  const year = invoiceDate.split('-')[0]
  const sequence = parseInt(number, 10)
  if (isNaN(sequence)) {
    return number
  }
  
  return `INV-${year}-${String(sequence).padStart(4, '0')}`
}

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
  
  const { data: rows } = await supabase.rpc('get_ar_aging', {
    p_organization_id: orgId,
    p_as_of_date: asOfDate,
  })

  if (!rows) {
    return new NextResponse('No data', { status: 404 })
  }

  const csvRows = [
    ['AR Aging - ' + (orgData?.name || 'Organization')],
    ['As of ' + new Date(asOfDate).toLocaleDateString()],
    [''],
    ['Customer Name', 'Invoice Number', 'Invoice Date', 'Due Date', 'Amount Due', 'Days Overdue'],
    ...rows.map((row: any) => [
      row.customer_name || '',
      formatInvoiceForCSV(row.invoice_number, row.invoice_date),
      new Date(row.invoice_date).toLocaleDateString(),
      row.due_date ? new Date(row.due_date).toLocaleDateString() : '',
      (row.amount_due_cents / 100).toFixed(2),
      row.days_overdue || 0,
    ]),
  ]

  const csv = csvRows.map(row => row.join(',')).join('\n')

  return new NextResponse(csv, {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': `attachment; filename="ar-aging-${asOfDate}.csv"`,
    },
  })
}
