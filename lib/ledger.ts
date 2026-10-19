// Domain functions for ledger operations
// Shared by UI Server Actions, REST API, and MCP
import { createServerClient } from '@supabase/ssr'
import { formatMoney, type MoneyValue } from './money'
import { companyToday } from './format-date'
import { guardedPost } from './guarded-post'


/**
 * Create a Supabase client with service role (bypasses RLS for API auth)
 */
function createServiceClient() {
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('Missing required Supabase environment variables')
  }
  
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY,
    {
      cookies: {
        getAll() { return [] },
        setAll() { },
      },
    }
  )
}

// ============================================================================
// ORGANIZATION
// ============================================================================

export async function getOrganization(organizationId: string) {
  const supabase = createServiceClient()
  
  const { data, error } = await supabase
    .from('organizations')
    .select('id, name, currency_code, timezone, fiscal_year_end_month, fiscal_year_end_day, capitalization_threshold_cents, created_at')
    .eq('id', organizationId)
    .single()

  if (error) throw new Error(error.message)
  
  return {
    id: data.id,
    name: data.name,
    currency: data.currency_code,
    timezone: data.timezone,
    fiscal_year_end: {
      month: data.fiscal_year_end_month,
      day: data.fiscal_year_end_day,
    },
    capitalization_threshold_cents: data.capitalization_threshold_cents,
    created_at: data.created_at,
  }
}

export async function updateCapitalizationThreshold(
  organizationId: string,
  thresholdCents: number
) {
  const supabase = createServiceClient()
  if (!Number.isFinite(thresholdCents) || thresholdCents < 0) {
    throw new Error('capitalization_threshold_cents must be zero or greater')
  }

  const { error } = await supabase
    .from('organizations')
    .update({ capitalization_threshold_cents: Math.round(thresholdCents) })
    .eq('id', organizationId)

  if (error) throw new Error(error.message)

  return { capitalization_threshold_cents: Math.round(thresholdCents) }
}

// ============================================================================
// ACCOUNTS
// ============================================================================

export async function listAccounts(organizationId: string, params?: {
  type?: string
  is_active?: boolean
}) {
  const supabase = createServiceClient()
  
  let query = supabase
    .from('accounts')
    .select('id, code, name, type, category, is_header, is_cash, is_active, parent_id')
    .eq('organization_id', organizationId)
    .order('code')

  if (params?.type) {
    query = query.eq('type', params.type)
  }
  if (params?.is_active !== undefined) {
    query = query.eq('is_active', params.is_active)
  }

  const { data, error } = await query

  if (error) throw new Error(error.message)
  
  return data.map(account => ({
    id: account.id,
    code: account.code,
    name: account.name,
    type: account.type,
    category: account.category,
    is_header: account.is_header,
    is_cash: account.is_cash,
    is_active: account.is_active,
    parent_id: account.parent_id,
  }))
}

export async function getAccount(organizationId: string, accountId: string) {
  const supabase = createServiceClient()
  
  const { data, error } = await supabase
    .from('accounts')
    .select('id, code, name, type, category, is_header, is_cash, is_active, parent_id, created_at, updated_at')
    .eq('organization_id', organizationId)
    .eq('id', accountId)
    .maybeSingle()

  if (error) throw new Error(error.message)
  if (!data) throw new Error('Account not found')
  
  return {
    id: data.id,
    code: data.code,
    name: data.name,
    type: data.type,
    category: data.category,
    is_header: data.is_header,
    is_cash: data.is_cash,
    is_active: data.is_active,
    parent_id: data.parent_id,
    created_at: data.created_at,
    updated_at: data.updated_at,
  }
}

const ACCOUNT_TYPES = ['Asset', 'Liability', 'Equity', 'Revenue', 'Expense'] as const
const ACCOUNT_CATEGORIES = ['Cash', 'AR', 'AP', 'Equity', 'Revenue', 'COGS', 'Expense', 'Other'] as const

function defaultAccountCategory(type: string, isCash: boolean): (typeof ACCOUNT_CATEGORIES)[number] {
  if (isCash) return 'Cash'
  if (type === 'Revenue') return 'Revenue'
  if (type === 'Expense') return 'Expense'
  if (type === 'Equity') return 'Equity'
  return 'Other'
}

export async function createAccount(
  organizationId: string,
  data: {
    code: string
    name: string
    type: string
    category?: string
    is_cash?: boolean
    parent_id?: string
  }
) {
  const supabase = createServiceClient()
  const code = data.code.trim()
  const name = data.name.trim()
  const isCash = Boolean(data.is_cash)

  if (!code || !name) {
    throw new Error('code and name are required')
  }
  if (!ACCOUNT_TYPES.includes(data.type as (typeof ACCOUNT_TYPES)[number])) {
    throw new Error('type must be Asset, Liability, Equity, Revenue, or Expense')
  }
  if (isCash && data.type !== 'Asset') {
    throw new Error('Cash accounts must be Asset type')
  }

  const category = data.category || defaultAccountCategory(data.type, isCash)
  if (!ACCOUNT_CATEGORIES.includes(category as (typeof ACCOUNT_CATEGORIES)[number])) {
    throw new Error(`category must be one of: ${ACCOUNT_CATEGORIES.join(', ')}`)
  }

  if (data.parent_id) {
    const { data: parent, error: parentError } = await supabase
      .from('accounts')
      .select('id')
      .eq('id', data.parent_id)
      .eq('organization_id', organizationId)
      .maybeSingle()
    if (parentError) throw new Error(parentError.message)
    if (!parent) throw new Error('parent_id must belong to the organization')
  }

  const { data: account, error } = await supabase
    .from('accounts')
    .insert({
      organization_id: organizationId,
      code,
      name,
      type: data.type,
      category,
      is_header: false,
      is_cash: isCash,
      is_system: false,
      is_active: true,
      parent_id: data.parent_id || null,
    })
    .select('id, code, name, type, category, is_header, is_cash, is_active, parent_id')
    .single()

  if (error) {
    if (error.code === '23505' || error.message?.includes('accounts_organization_id_code_key')) {
      throw new Error(`Account code ${code} already exists`)
    }
    throw new Error(error.message)
  }

  return { account_id: account.id, account }
}

export async function deleteAccount(organizationId: string, accountId: string) {
  const supabase = createServiceClient()

  const { data: account, error: accountError } = await supabase
    .from('accounts')
    .select('id, code, name, is_system')
    .eq('id', accountId)
    .eq('organization_id', organizationId)
    .maybeSingle()

  if (accountError) throw new Error(accountError.message)
  if (!account) throw new Error('Account not found')
  if (account.is_system) {
    throw new Error(`System account ${account.code} (${account.name}) cannot be deleted`)
  }

  const { count: childCount, error: childError } = await supabase
    .from('accounts')
    .select('id', { count: 'exact', head: true })
    .eq('organization_id', organizationId)
    .eq('parent_id', accountId)
  if (childError) throw new Error(childError.message)
  if (childCount && childCount > 0) {
    throw new Error(`Account ${account.code} has child accounts and cannot be deleted`)
  }

  const { count: journalCount, error: journalError } = await supabase
    .from('journal_lines')
    .select('id', { count: 'exact', head: true })
    .eq('organization_id', organizationId)
    .eq('account_id', accountId)
  if (journalError) throw new Error(journalError.message)
  if (journalCount && journalCount > 0) {
    throw new Error(`Account ${account.code} has journal lines and cannot be deleted`)
  }

  const { count: billCount, error: billError } = await supabase
    .from('bill_lines')
    .select('id', { count: 'exact', head: true })
    .eq('organization_id', organizationId)
    .eq('account_id', accountId)
  if (billError) throw new Error(billError.message)
  if (billCount && billCount > 0) {
    throw new Error(`Account ${account.code} is used on bills and cannot be deleted`)
  }

  const { count: invoiceCount, error: invoiceError } = await supabase
    .from('invoice_lines')
    .select('id', { count: 'exact', head: true })
    .eq('organization_id', organizationId)
    .eq('account_id', accountId)
  if (invoiceError) throw new Error(invoiceError.message)
  if (invoiceCount && invoiceCount > 0) {
    throw new Error(`Account ${account.code} is used on invoices and cannot be deleted`)
  }

  const { count: assetCount, error: assetError } = await supabase
    .from('fixed_assets')
    .select('id', { count: 'exact', head: true })
    .eq('organization_id', organizationId)
    .or(`asset_account_id.eq.${accountId},accum_dep_account_id.eq.${accountId},dep_expense_account_id.eq.${accountId}`)
  if (assetError) throw new Error(assetError.message)
  if (assetCount && assetCount > 0) {
    throw new Error(`Account ${account.code} is used on fixed assets and cannot be deleted`)
  }

  const { error: deleteError } = await supabase
    .from('accounts')
    .delete()
    .eq('id', accountId)
    .eq('organization_id', organizationId)

  if (deleteError) throw new Error(deleteError.message)

  return { success: true, account_id: accountId }
}

// ============================================================================
// JOURNALS
// ============================================================================

export async function listJournals(organizationId: string, params?: {
  status?: string
  limit?: number
  offset?: number
}) {
  const supabase = createServiceClient()
  
  let query = supabase
    .from('journals')
    .select('id, number, entry_date, description, status, source, created_at, posted_at')
    .eq('organization_id', organizationId)
    .order('entry_date', { ascending: false })
    .order('created_at', { ascending: false })

  if (params?.status) {
    query = query.eq('status', params.status)
  }
  if (params?.limit) {
    query = query.limit(params.limit)
  }
  if (params?.offset) {
    query = query.range(params.offset, params.offset + (params.limit || 100) - 1)
  }

  const { data, error } = await query

  if (error) throw new Error(error.message)
  
  return data.map(journal => ({
    id: journal.id,
    number: journal.number,
    entry_date: journal.entry_date,
    description: journal.description,
    status: journal.status,
    source: journal.source,
    created_at: journal.created_at,
    posted_at: journal.posted_at,
  }))
}

export async function getJournal(organizationId: string, journalId: string) {
  const supabase = createServiceClient()
  
  const { data: journal, error: journalError } = await supabase
    .from('journals')
    .select('*')
    .eq('organization_id', organizationId)
    .eq('id', journalId)
    .maybeSingle()

  if (journalError) throw new Error(journalError.message)
  if (!journal) throw new Error('Journal not found')

  const { data: lines, error: linesError } = await supabase
    .from('journal_lines')
    .select(`
      id,
      account_id,
      debit_cents,
      credit_cents,
      memo,
      accounts!inner(code, name, type)
    `)
    .eq('journal_id', journalId)
    .order('id')

  if (linesError) throw new Error(linesError.message)

  return {
    id: journal.id,
    number: journal.number,
    entry_date: journal.entry_date,
    description: journal.description,
    status: journal.status,
    source: journal.source,
    created_at: journal.created_at,
    posted_at: journal.posted_at,
    posted_by: journal.posted_by,
    lines: lines.map(line => ({
      id: line.id,
      account_id: line.account_id,
      account_code: (line.accounts as any).code,
      account_name: (line.accounts as any).name,
      account_type: (line.accounts as any).type,
      debit: formatMoney(line.debit_cents, 'USD'),
      credit: formatMoney(line.credit_cents, 'USD'),
      memo: line.memo,
    })),
  }
}

export async function draftJournal(
  organizationId: string,
  data: {
    entry_date: string
    description: string
    lines: Array<{
      account_id: string
      debit_cents: number
      credit_cents: number
      memo?: string
    }>
  },
  createdBy: string
) {
  const supabase = createServiceClient()

  const accountIds = [...new Set(data.lines.map((line) => line.account_id))]
  if (accountIds.length > 0) {
    const { data: accounts, error: accountError } = await supabase
      .from('accounts')
      .select('id')
      .eq('organization_id', organizationId)
      .in('id', accountIds)

    if (accountError) throw new Error(accountError.message)
    if ((accounts || []).length !== accountIds.length) {
      throw new Error('All journal accounts must belong to the organization')
    }
  }

  // Create journal with null number (assigned at post time)
  const { data: journal, error: journalError } = await supabase
    .from('journals')
    .insert({
      organization_id: organizationId,
      number: null,
      entry_date: data.entry_date,
      description: data.description,
      status: 'Draft',
      source: 'manual',
      created_by: createdBy,
    })
    .select()
    .single()

  if (journalError) throw new Error(journalError.message)

  // Create lines
  const { error: linesError } = await supabase
    .from('journal_lines')
    .insert(
      data.lines.map(line => ({
        organization_id: organizationId,
        journal_id: journal.id,
        account_id: line.account_id,
        debit_cents: line.debit_cents,
        credit_cents: line.credit_cents,
        memo: line.memo || null,
      }))
    )

  if (linesError) throw new Error(linesError.message)

  return { journal_id: journal.id }
}

export async function postJournal(organizationId: string, journalId: string, userId?: string) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('post_journal', {
    p_journal_id: journalId,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!data?.success) throw new Error(data?.error || 'Unknown error')

  return { success: true, journal_id: journalId }
}

export async function reverseJournal(
  organizationId: string,
  journalId: string,
  reversalDate: string,
  reversalDescription?: string,
  userId?: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('reverse_journal', {
    p_journal_id: journalId,
    p_reversal_date: reversalDate,
    p_reversal_description: reversalDescription || null,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!data?.success) throw new Error(data?.error || 'Failed to reverse journal')

  return {
    success: true,
    original_journal_id: data.original_journal_id,
    reversal_journal_id: data.reversal_journal_id,
  }
}

export async function deleteJournal(
  organizationId: string,
  journalId: string,
  userId?: string
) {
  const supabase = createServiceClient()
  
  const { data, error } = await supabase.rpc('delete_journal', {
    p_journal_id: journalId,
    p_user_id: userId || null,
  })
  
  if (error) throw new Error(error.message)
  if (!data?.success) throw new Error(data?.error || 'Failed to delete journal')
  
  return {
    success: true,
    journal_number: data.journal_number,
  }
}

// ============================================================================
// CONTACTS
// ============================================================================

export async function listContacts(organizationId: string, params?: {
  type?: string
  is_active?: boolean
}) {
  const supabase = createServiceClient()
  
  let query = supabase
    .from('contacts')
    .select('id, type, name, email, phone, address, notes, is_active, created_at')
    .eq('organization_id', organizationId)
    .order('name')

  if (params?.type) {
    query = query.eq('type', params.type)
  }
  if (params?.is_active !== undefined) {
    query = query.eq('is_active', params.is_active)
  }

  const { data, error } = await query

  if (error) throw new Error(error.message)
  
  return data
}

export async function createContact(
  organizationId: string,
  data: {
    type: string
    name: string
    email?: string
    phone?: string
    address?: string
    notes?: string
  }
) {
  const supabase = createServiceClient()

  const { data: contact, error } = await supabase
    .from('contacts')
    .insert({
      organization_id: organizationId,
      type: data.type,
      name: data.name,
      email: data.email || null,
      phone: data.phone || null,
      address: data.address || null,
      notes: data.notes || null,
      is_active: true,
    })
    .select()
    .single()

  if (error) throw new Error(error.message)

  return { contact_id: contact.id }
}

// ============================================================================
// BILLS
// ============================================================================

export async function listBills(organizationId: string, params?: {
  status?: string
  vendor_id?: string
}) {
  const supabase = createServiceClient()
  
  let query = supabase
    .from('bills')
    .select(`
      id,
      number,
      bill_date,
      due_date,
      status,
      total_cents,
      paid_cents,
      contacts!inner(name)
    `)
    .eq('organization_id', organizationId)
    .order('bill_date', { ascending: false })

  if (params?.status) {
    query = query.eq('status', params.status)
  }
  if (params?.vendor_id) {
    query = query.eq('vendor_id', params.vendor_id)
  }

  const { data, error } = await query

  if (error) throw new Error(error.message)
  
  return data.map(bill => ({
    id: bill.id,
    number: bill.number,
    bill_date: bill.bill_date,
    due_date: bill.due_date,
    status: bill.status,
    total: formatMoney(bill.total_cents, 'USD'),
    paid: formatMoney(bill.paid_cents, 'USD'),
    vendor_name: (bill.contacts as any).name,
  }))
}

export async function draftBill(
  organizationId: string,
  data: {
    vendor_id: string
    number: string
    bill_date: string
    due_date?: string
    lines: Array<{
      account_id: string
      amount_cents: number
      description: string
    }>
    notes?: string
  },
  createdBy: string
) {
  const supabase = createServiceClient()

  const { data: vendor, error: vendorError } = await supabase
    .from('contacts')
    .select('id')
    .eq('id', data.vendor_id)
    .eq('organization_id', organizationId)
    .maybeSingle()
  if (vendorError) throw new Error(vendorError.message)
  if (!vendor) throw new Error('Vendor must belong to the organization')

  const accountIds = [...new Set(data.lines.map((line) => line.account_id))]
  if (accountIds.length > 0) {
    const { data: accounts, error: accountError } = await supabase
      .from('accounts')
      .select('id')
      .eq('organization_id', organizationId)
      .in('id', accountIds)
    if (accountError) throw new Error(accountError.message)
    if ((accounts || []).length !== accountIds.length) {
      throw new Error('All bill accounts must belong to the organization')
    }
  }

  const totalCents = data.lines.reduce((sum, line) => sum + line.amount_cents, 0)

  // Create bill
  const { data: bill, error: billError } = await supabase
    .from('bills')
    .insert({
      organization_id: organizationId,
      vendor_id: data.vendor_id,
      number: data.number,
      bill_date: data.bill_date,
      due_date: data.due_date || data.bill_date,
      status: 'Draft',
      total_cents: totalCents,
      notes: data.notes || null,
      created_by: createdBy,
    })
    .select()
    .single()

  if (billError) throw new Error(billError.message)

  // Create bill lines
  const { error: linesError } = await supabase
    .from('bill_lines')
    .insert(
      data.lines.map(line => ({
        organization_id: organizationId,
        bill_id: bill.id,
        account_id: line.account_id,
        amount_cents: line.amount_cents,
        description: line.description,
      }))
    )

  if (linesError) throw new Error(linesError.message)

  return { bill_id: bill.id }
}

export async function postBill(
  organizationId: string,
  billId: string,
  createdBy: string
) {
  const supabase = createServiceClient()

  // Get bill details
  const { data: bill, error: billError } = await supabase
    .from('bills')
    .select(`
      *,
      bill_lines!inner(account_id, amount_cents, description)
    `)
    .eq('id', billId)
    .eq('organization_id', organizationId)
    .single()

  if (billError) throw new Error(billError.message)
  if (bill.status !== 'Draft' || bill.recognition_journal_id) {
    throw new Error('Bill is already posted')
  }

  // Get AP account
  const { data: apAccount, error: apError } = await supabase
    .from('accounts')
    .select('id')
    .eq('organization_id', organizationId)
    .eq('code', '2000')
    .single()

  if (apError) throw new Error('AP account (2000) not found')

  let journalId: string

  await guardedPost(supabase, organizationId, bill.bill_date, createdBy, async (track) => {
    // Create journal (Draft, number assigned at post time)
    const { data: journal, error: journalError } = await supabase
      .from('journals')
      .insert({
        organization_id: organizationId,
        number: null,
        entry_date: bill.bill_date,
        description: `Bill ${bill.number}`,
        status: 'Draft',
        source: 'bill',
        created_by: createdBy,
      })
      .select()
      .single()

    if (journalError) throw new Error(journalError.message)
    track('journals', journal.id)
    journalId = journal.id

    // Create journal lines
    const lines = [
      ...(bill.bill_lines as any[]).map(line => ({
        organization_id: organizationId,
        journal_id: journal.id,
        account_id: line.account_id,
        debit_cents: line.amount_cents,
        credit_cents: 0,
        memo: line.description,
      })),
      {
        organization_id: organizationId,
        journal_id: journal.id,
        account_id: apAccount.id,
        debit_cents: 0,
        credit_cents: bill.total_cents,
        memo: `Bill ${bill.number}`,
      },
    ]

    const { data: insertedLines, error: linesError } = await supabase
      .from('journal_lines')
      .insert(lines)
      .select()

    if (linesError) throw new Error(linesError.message)
    insertedLines?.forEach(line => track('journal_lines', line.id))

    // Post journal
    const { data: postResult, error: postError } = await supabase.rpc('post_journal', {
      p_journal_id: journal.id,
      p_user_id: createdBy,
    })

    if (postError) throw new Error(postError.message)
    if (!postResult?.success) throw new Error(postResult?.error || 'Unknown error')

    // Update bill status to Open (only after successful post)
    await supabase
      .from('bills')
      .update({
        status: 'Open',
        recognition_journal_id: journal.id,
      })
      .eq('id', billId)
  })

  return { bill_id: billId, journal_id: journalId! }
}

export async function payBill(
  organizationId: string,
  data: {
    bill_id: string
    payment_date: string
    amount_cents: number
    cash_account_id: string
    notes?: string
  },
  createdBy: string
) {
  const supabase = createServiceClient()

  if (!data.payment_date) throw new Error('payment_date is required')
  if (!Number.isFinite(data.amount_cents) || data.amount_cents <= 0) {
    throw new Error('amount_cents must be greater than zero')
  }

  const { data: bill, error: billError } = await supabase
    .from('bills')
    .select('id, number, status, total_cents, paid_cents')
    .eq('id', data.bill_id)
    .eq('organization_id', organizationId)
    .maybeSingle()

  if (billError) throw new Error(billError.message)
  if (!bill) throw new Error('Bill not found')
  if (bill.status !== 'Open') {
    throw new Error(`Bill ${bill.number} is ${bill.status}. Only Open bills can be marked paid.`)
  }

  const remainingCents = (bill.total_cents || 0) - (bill.paid_cents || 0)
  if (data.amount_cents > remainingCents) {
    throw new Error('Payment exceeds remaining balance')
  }

  const { data: cashAccount, error: cashError } = await supabase
    .from('accounts')
    .select('id, is_cash, is_active')
    .eq('id', data.cash_account_id)
    .eq('organization_id', organizationId)
    .maybeSingle()

  if (cashError) throw new Error(cashError.message)
  if (!cashAccount) throw new Error('Cash account must belong to the organization')
  if (!cashAccount.is_cash || !cashAccount.is_active) {
    throw new Error('cash_account_id must be an active cash account')
  }

  const { data: apAccount, error: apError } = await supabase
    .from('accounts')
    .select('id')
    .eq('organization_id', organizationId)
    .eq('code', '2000')
    .single()

  if (apError || !apAccount) throw new Error('AP account (2000) not found')

  let journalId: string
  let newPaidCents: number

  await guardedPost(supabase, organizationId, data.payment_date, createdBy, async (track) => {
    const description = data.notes
      ? `Payment for bill ${bill.number}: ${data.notes}`
      : `Payment for bill ${bill.number}`

    const { data: journal, error: journalError } = await supabase
      .from('journals')
      .insert({
        organization_id: organizationId,
        number: null,
        entry_date: data.payment_date,
        description,
        status: 'Draft',
        source: 'bill_payment',
        created_by: createdBy,
      })
      .select()
      .single()

    if (journalError) throw new Error(journalError.message)
    track('journals', journal.id)
    journalId = journal.id

    const { data: insertedLines, error: linesError } = await supabase
      .from('journal_lines')
      .insert([
        {
          organization_id: organizationId,
          journal_id: journal.id,
          account_id: apAccount.id,
          debit_cents: data.amount_cents,
          credit_cents: 0,
          memo: `Bill ${bill.number}`,
        },
        {
          organization_id: organizationId,
          journal_id: journal.id,
          account_id: data.cash_account_id,
          debit_cents: 0,
          credit_cents: data.amount_cents,
          memo: `Bill ${bill.number}`,
        },
      ])
      .select()

    if (linesError) throw new Error(linesError.message)
    insertedLines?.forEach(line => track('journal_lines', line.id))

    const { data: postResult, error: postError } = await supabase.rpc('post_journal', {
      p_journal_id: journal.id,
      p_user_id: createdBy,
    })

    if (postError) throw new Error(postError.message)
    if (!postResult?.success) throw new Error(postResult?.error || 'Unknown error')

    const { data: payment, error: paymentError } = await supabase
      .from('bill_payments')
      .insert({
        organization_id: organizationId,
        bill_id: bill.id,
        payment_journal_id: journal.id,
        payment_date: data.payment_date,
        amount_cents: data.amount_cents,
        created_by: createdBy,
      })
      .select()
      .single()

    if (paymentError) throw new Error(paymentError.message)
    track('bill_payments', payment.id)

    newPaidCents = (bill.paid_cents || 0) + data.amount_cents
    const { error: updateError } = await supabase
      .from('bills')
      .update({
        paid_cents: newPaidCents,
        status: newPaidCents >= bill.total_cents ? 'Paid' : 'Open',
      })
      .eq('id', bill.id)

    if (updateError) throw new Error(updateError.message)
  })

  return {
    success: true,
    bill_id: bill.id,
    journal_id: journalId!,
    paid_cents: newPaidCents!,
    status: newPaidCents! >= bill.total_cents ? 'Paid' : 'Open',
  }
}

// ============================================================================
// INVOICES (AR)
// ============================================================================

export async function listInvoices(organizationId: string, params?: {
  status?: string
  customer_id?: string
}) {
  const supabase = createServiceClient()
  
  let query = supabase
    .from('invoices')
    .select(`
      id,
      number,
      invoice_date,
      due_date,
      status,
      total_cents,
      received_cents,
      contacts!inner(name)
    `)
    .eq('organization_id', organizationId)
    .order('invoice_date', { ascending: false })

  if (params?.status) {
    query = query.eq('status', params.status)
  }
  if (params?.customer_id) {
    query = query.eq('customer_id', params.customer_id)
  }

  const { data, error } = await query

  if (error) throw new Error(error.message)
  
  return data.map(invoice => ({
    id: invoice.id,
    number: invoice.number,
    invoice_date: invoice.invoice_date,
    due_date: invoice.due_date,
    status: invoice.status,
    total: formatMoney(invoice.total_cents, 'USD'),
    received: formatMoney(invoice.received_cents, 'USD'),
    balance: formatMoney(invoice.total_cents - invoice.received_cents, 'USD'),
    customer_name: (invoice.contacts as any).name,
  }))
}

export async function getInvoice(organizationId: string, invoiceId: string) {
  const supabase = createServiceClient()
  
  const { data: invoice, error: invoiceError } = await supabase
    .from('invoices')
    .select(`
      *,
      contacts!inner(id, name, email)
    `)
    .eq('organization_id', organizationId)
    .eq('id', invoiceId)
    .maybeSingle()

  if (invoiceError) throw new Error(invoiceError.message)
  if (!invoice) throw new Error('Invoice not found')

  const { data: lines, error: linesError } = await supabase
    .from('invoice_lines')
    .select(`
      id,
      line_number,
      account_id,
      amount_cents,
      description,
      accounts!inner(code, name)
    `)
    .eq('invoice_id', invoiceId)
    .order('line_number')

  if (linesError) throw new Error(linesError.message)

  return {
    id: invoice.id,
    number: invoice.number,
    customer_id: invoice.customer_id,
    customer_name: (invoice.contacts as any).name,
    customer_email: (invoice.contacts as any).email,
    invoice_date: invoice.invoice_date,
    due_date: invoice.due_date,
    status: invoice.status,
    total: formatMoney(invoice.total_cents, 'USD'),
    received: formatMoney(invoice.received_cents, 'USD'),
    balance: formatMoney(invoice.total_cents - invoice.received_cents, 'USD'),
    notes: invoice.notes,
    created_at: invoice.created_at,
    lines: lines.map(line => ({
      id: line.id,
      line_number: line.line_number,
      account_id: line.account_id,
      account_code: (line.accounts as any).code,
      account_name: (line.accounts as any).name,
      amount: formatMoney(line.amount_cents, 'USD'),
      description: line.description,
    })),
  }
}

export async function draftInvoice(
  organizationId: string,
  data: {
    customer_id: string
    number: string
    invoice_date: string
    due_date?: string
    status?: 'Draft' | 'Quote'
    lines: Array<{
      account_id: string
      amount_cents: number
      description: string
    }>
    notes?: string
  },
  createdBy: string
) {
  const supabase = createServiceClient()

  const { data: customer, error: customerError } = await supabase
    .from('contacts')
    .select('id')
    .eq('id', data.customer_id)
    .eq('organization_id', organizationId)
    .maybeSingle()
  if (customerError) throw new Error(customerError.message)
  if (!customer) throw new Error('Customer must belong to the organization')

  const accountIds = [...new Set(data.lines.map((line) => line.account_id))]
  if (accountIds.length > 0) {
    const { data: accounts, error: accountError } = await supabase
      .from('accounts')
      .select('id')
      .eq('organization_id', organizationId)
      .in('id', accountIds)
    if (accountError) throw new Error(accountError.message)
    if ((accounts || []).length !== accountIds.length) {
      throw new Error('All invoice accounts must belong to the organization')
    }
  }

  const totalCents = data.lines.reduce((sum, line) => sum + line.amount_cents, 0)

  const { data: invoice, error: invoiceError } = await supabase
    .from('invoices')
    .insert({
      organization_id: organizationId,
      customer_id: data.customer_id,
      number: data.number,
      invoice_date: data.invoice_date,
      due_date: data.due_date || null,
      status: data.status || 'Draft',
      total_cents: totalCents,
      received_cents: 0,
      notes: data.notes || null,
      created_by: createdBy,
    })
    .select()
    .single()

  if (invoiceError) throw new Error(invoiceError.message)

  const { error: linesError } = await supabase
    .from('invoice_lines')
    .insert(
      data.lines.map((line, idx) => ({
        organization_id: organizationId,
        invoice_id: invoice.id,
        line_number: idx + 1,
        account_id: line.account_id,
        amount_cents: line.amount_cents,
        description: line.description,
      }))
    )

  if (linesError) throw new Error(linesError.message)

  return { invoice_id: invoice.id }
}

export async function postInvoice(organizationId: string, invoiceId: string, userId?: string) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('post_invoice', {
    p_invoice_id: invoiceId,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!data?.success) throw new Error(data?.error || 'Failed to post invoice')

  return { success: true, invoice_id: invoiceId, journal_id: data.journal_id }
}

export async function recordReceipt(
  organizationId: string,
  data: {
    invoice_id: string
    receipt_date: string
    amount_cents: number
    cash_account_id: string
    notes?: string
  },
  userId?: string
) {
  const supabase = createServiceClient()

  const { data: result, error } = await supabase.rpc('record_receipt', {
    p_invoice_id: data.invoice_id,
    p_receipt_date: data.receipt_date,
    p_amount_cents: data.amount_cents,
    p_cash_account_id: data.cash_account_id,
    p_notes: data.notes || null,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!result?.success) throw new Error(result?.error || 'Failed to record receipt')

  return { success: true, invoice_id: data.invoice_id, journal_id: result.journal_id }
}

export async function issueCreditNote(
  organizationId: string,
  data: {
    invoice_id: string
    credit_date: string
    amount_cents: number
    reason: string
  },
  userId?: string
) {
  const supabase = createServiceClient()

  const { data: result, error } = await supabase.rpc('issue_credit_note', {
    p_invoice_id: data.invoice_id,
    p_credit_date: data.credit_date,
    p_amount_cents: data.amount_cents,
    p_reason: data.reason,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!result?.success) throw new Error(result?.error || 'Failed to issue credit note')

  return { success: true, invoice_id: data.invoice_id, journal_id: result.journal_id }
}

export async function writeOffInvoice(
  organizationId: string,
  data: {
    invoice_id: string
    write_off_date: string
    amount_cents: number
    reason: string
  },
  userId?: string
) {
  const supabase = createServiceClient()

  const { data: result, error } = await supabase.rpc('write_off_invoice', {
    p_invoice_id: data.invoice_id,
    p_write_off_date: data.write_off_date,
    p_amount_cents: data.amount_cents,
    p_reason: data.reason,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!result?.success) throw new Error(result?.error || 'Failed to write off invoice')

  return { success: true, invoice_id: data.invoice_id, journal_id: result.journal_id }
}

export async function sendInvoiceReminder(organizationId: string, invoiceId: string, userId?: string, toEmail?: string) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('send_invoice_reminder', {
    p_invoice_id: invoiceId,
    p_to_email: toEmail || null,
    p_user_id: userId,
    p_organization_id: organizationId,
  })

  if (error) throw new Error(error.message)
  if (!data?.success) throw new Error(data?.error || 'Failed to send reminder')

  return data
}

export async function sendInvoice(
  organizationId: string,
  invoiceId: string,
  userId: string,
  toEmail?: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('send_invoice', {
    p_invoice_id: invoiceId,
    p_to_email: toEmail || null,
    p_user_id: userId,
    p_organization_id: organizationId,
  })

  if (error) {
    // Map authentication errors
    if (error.message?.includes('Not authenticated') || error.message?.includes('authenticated')) {
      throw new Error('Authentication required')
    }
    throw new Error(error.message)
  }
  
  if (!data?.success) throw new Error(data?.error || 'Failed to send invoice')

  return {
    success: true,
    invoice_id: data.invoice_id,
    invoice_number: data.invoice_number,
    to_email: data.to_email,
    last_sent: data.last_sent,
    customer_name: data.customer_name,
    org_legal_name: data.org_legal_name,
    org_registration_id: data.org_registration_id,
    org_address: data.org_address,
    org_email: data.org_email,
    org_phone: data.org_phone,
    org_payment_details: data.org_payment_details,
  }
}

export async function getARAging(organizationId: string, asOfDate: string) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('get_ar_aging', {
    p_organization_id: organizationId,
    p_as_of_date: asOfDate,
  })

  if (error) throw new Error(error.message)

  return (data || []).map((row: any) => ({
    invoice_id: row.invoice_id,
    invoice_number: row.invoice_number,
    customer_name: row.customer_name,
    invoice_date: row.invoice_date,
    due_date: row.due_date,
    amount_due: formatMoney(row.amount_due_cents, 'USD'),
    days_overdue: row.days_overdue,
  }))
}

// ============================================================================
// REPORTS
// ============================================================================

export async function getProfitAndLoss(
  organizationId: string,
  startDate: string,
  endDate: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('get_profit_and_loss', {
    p_organization_id: organizationId,
    p_start_date: startDate,
    p_end_date: endDate,
  })

  if (error) throw new Error(error.message)

  return (data || []).map((row: any) => ({
    section: row.section,
    account_id: row.account_id,
    account_code: row.account_code,
    account_name: row.account_name,
    account_type: row.account_type,
    amount: formatMoney(row.amount_cents, 'USD'),
  }))
}

export async function getBalanceSheet(
  organizationId: string,
  asOfDate: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('get_balance_sheet', {
    p_organization_id: organizationId,
    p_as_of_date: asOfDate,
  })

  if (error) throw new Error(error.message)

  return (data || []).map((row: any) => ({
    section: row.section,
    account_id: row.account_id,
    account_code: row.account_code,
    account_name: row.account_name,
    account_type: row.account_type,
    balance: formatMoney(row.balance_cents, 'USD'),
  }))
}

export async function getTrialBalance(
  organizationId: string,
  asOfDate: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('get_trial_balance', {
    p_organization_id: organizationId,
    p_as_of_date: asOfDate,
  })

  if (error) throw new Error(error.message)

  const rows = (data || []).map((row: any) => ({
    account_id: row.account_id,
    account_code: row.account_code,
    account_name: row.account_name,
    account_type: row.account_type,
    debit: formatMoney(row.debit_cents, 'USD'),
    credit: formatMoney(row.credit_cents, 'USD'),
    debit_cents: row.debit_cents,
    credit_cents: row.credit_cents,
  }))

  // Calculate totals
  const total_debit_cents = rows.reduce((sum: number, row: any) => sum + row.debit_cents, 0)
  const total_credit_cents = rows.reduce((sum: number, row: any) => sum + row.credit_cents, 0)
  const balanced = total_debit_cents === total_credit_cents

  return {
    rows,
    total_debit_cents,
    total_credit_cents,
    balanced,
  }
}

export async function getCashMovement(
  organizationId: string,
  startDate: string,
  endDate: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('get_cash_movement', {
    p_organization_id: organizationId,
    p_start_date: startDate,
    p_end_date: endDate,
  })

  if (error) throw new Error(error.message)

  return (data || []).map((row: any) => ({
    counter_account_id: row.counter_account_id,
    counter_account_code: row.counter_account_code,
    counter_account_name: row.counter_account_name,
    counter_account_type: row.counter_account_type,
    net_change: formatMoney(row.net_change_cents, 'USD'),
  }))
}

export async function getAPAging(
  organizationId: string,
  asOfDate: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('get_ap_aging', {
    p_organization_id: organizationId,
    p_as_of_date: asOfDate,
  })

  if (error) throw new Error(error.message)

  return (data || []).map((row: any) => ({
    bill_id: row.bill_id,
    bill_number: row.bill_number,
    vendor_id: row.vendor_id,
    vendor_name: row.vendor_name,
    bill_date: row.bill_date,
    due_date: row.due_date,
    total: formatMoney(row.total_cents, 'USD'),
    paid: formatMoney(row.paid_cents, 'USD'),
    balance: formatMoney(row.balance_cents, 'USD'),
    days_outstanding: row.days_outstanding,
    aging_bucket: row.aging_bucket,
  }))
}

export async function getAccountLedger(
  organizationId: string,
  accountId: string,
  startDate?: string,
  endDate?: string
) {
  const supabase = createServiceClient()

  // Fetch account details to determine normal balance
  const { data: account, error: accountError } = await supabase
    .from('accounts')
    .select('type')
    .eq('id', accountId)
    .eq('organization_id', organizationId)
    .maybeSingle()

  if (accountError) throw new Error(accountError.message)
  if (!account) {
    const err: any = new Error('Account not found')
    err.code = 'ACCOUNT_NOT_FOUND'
    throw err
  }

  const { data, error } = await supabase.rpc('get_account_ledger', {
    p_organization_id: organizationId,
    p_account_id: accountId,
    p_start_date: startDate || null,
    p_end_date: endDate || null,
  })

  if (error) throw new Error(error.message)

  // Asset/Expense are debit-normal (positive = debit), Liability/Equity/Revenue are credit-normal (positive = credit)
  const isCreditNormal = ['Liability', 'Equity', 'Revenue'].includes(account.type)

  const rows = (data || []).map((row: any) => ({
    journal_id: row.journal_id,
    journal_number: row.journal_number,
    entry_date: row.entry_date,
    description: row.journal_description,
    line_memo: row.line_memo,
    status: row.status,
    debit: formatMoney(row.debit_cents, 'USD'),
    credit: formatMoney(row.credit_cents, 'USD'),
    debit_cents: row.debit_cents,
    credit_cents: row.credit_cents,
    running_balance_cents: row.running_balance_cents,
    signed_running_balance_cents: isCreditNormal ? -row.running_balance_cents : row.running_balance_cents,
  }))

  // Calculate ending balance from last row
  const endingBalanceCents = rows.length > 0 ? rows[rows.length - 1].signed_running_balance_cents : 0

  return {
    account_id: accountId,
    account_type: account.type,
    rows,
    ending_balance_cents: endingBalanceCents,
  }
}

// ============================================================================
// FIXED ASSETS
// ============================================================================

const FIXED_ASSET_CLASSES = [
  'equipment',
  'furniture',
  'leasehold_improvements',
  'intangible',
] as const

function formatFixedAsset(row: {
  id: string
  number: string
  description: string
  class: string
  status: string
  serial_number: string | null
  location: string | null
  vendor_id: string | null
  source_bill_id: string | null
  acquisition_date: string
  in_service_date: string
  cost_cents: number
  residual_cents: number
  useful_life_months: number
  method: string
  asset_account_id: string
  accum_dep_account_id: string
  dep_expense_account_id: string
  accum_dep_cents: number
  pledged: boolean
  idle: boolean
  component_parent_id: string | null
  recognition_journal_id: string | null
  disposal_journal_id: string | null
  disposal_date: string | null
  disposal_proceeds_cents: number | null
  notes: string | null
}) {
  const nbv = row.cost_cents - row.accum_dep_cents
  return {
    id: row.id,
    number: row.number,
    description: row.description,
    class: row.class,
    status: row.status,
    serial_number: row.serial_number,
    location: row.location,
    vendor_id: row.vendor_id,
    source_bill_id: row.source_bill_id,
    acquisition_date: row.acquisition_date,
    in_service_date: row.in_service_date,
    cost: formatMoney(row.cost_cents, 'USD'),
    residual: formatMoney(row.residual_cents, 'USD'),
    useful_life_months: row.useful_life_months,
    method: row.method,
    asset_account_id: row.asset_account_id,
    accum_dep_account_id: row.accum_dep_account_id,
    dep_expense_account_id: row.dep_expense_account_id,
    accum_dep: formatMoney(row.accum_dep_cents, 'USD'),
    net_book_value: formatMoney(nbv, 'USD'),
    pledged: row.pledged,
    idle: row.idle,
    component_parent_id: row.component_parent_id,
    recognition_journal_id: row.recognition_journal_id,
    disposal_journal_id: row.disposal_journal_id,
    disposal_date: row.disposal_date,
    disposal_proceeds: row.disposal_proceeds_cents == null
      ? null
      : formatMoney(row.disposal_proceeds_cents, 'USD'),
    notes: row.notes,
  }
}

export async function listFixedAssets(
  organizationId: string,
  params?: { status?: string; class?: string }
) {
  const supabase = createServiceClient()

  let query = supabase
    .from('fixed_assets')
    .select(
      'id, number, description, class, status, serial_number, location, vendor_id, source_bill_id, acquisition_date, in_service_date, cost_cents, residual_cents, useful_life_months, method, asset_account_id, accum_dep_account_id, dep_expense_account_id, accum_dep_cents, pledged, idle, component_parent_id, recognition_journal_id, disposal_journal_id, disposal_date, disposal_proceeds_cents, notes'
    )
    .eq('organization_id', organizationId)
    .order('number', { nullsFirst: false })
    .order('created_at')

  if (params?.status) query = query.eq('status', params.status)
  if (params?.class) query = query.eq('class', params.class)

  const { data, error } = await query
  if (error) throw new Error(error.message)
  return (data || []).map(formatFixedAsset)
}

export async function getFixedAsset(organizationId: string, assetId: string) {
  const supabase = createServiceClient()

  const { data, error } = await supabase
    .from('fixed_assets')
    .select(
      'id, number, description, class, status, serial_number, location, vendor_id, source_bill_id, acquisition_date, in_service_date, cost_cents, residual_cents, useful_life_months, method, asset_account_id, accum_dep_account_id, dep_expense_account_id, accum_dep_cents, pledged, idle, component_parent_id, recognition_journal_id, disposal_journal_id, disposal_date, disposal_proceeds_cents, notes'
    )
    .eq('organization_id', organizationId)
    .eq('id', assetId)
    .maybeSingle()

  if (error) throw new Error(error.message)
  if (!data) throw new Error('Fixed asset not found')

  const { data: runs, error: runError } = await supabase
    .from('fixed_asset_depreciation_runs')
    .select('id, period_start, period_end, amount_cents, journal_id')
    .eq('organization_id', organizationId)
    .eq('asset_id', assetId)
    .order('period_start')

  if (runError) throw new Error(runError.message)

  return {
    ...formatFixedAsset(data),
    depreciation_runs: (runs || []).map((run) => ({
      id: run.id,
      period_start: run.period_start,
      period_end: run.period_end,
      amount: formatMoney(run.amount_cents, 'USD'),
      journal_id: run.journal_id,
    })),
  }
}

export async function registerFixedAsset(
  organizationId: string,
  data: {
    description: string
    class: string
    cost_cents: number
    useful_life_months: number
    acquisition_date: string
    in_service_date: string
    residual_cents?: number
    asset_account_id?: string
    accum_dep_account_id?: string
    dep_expense_account_id?: string
    credit_account_id?: string
    post_acquisition?: boolean
    existing_journal_id?: string
    brought_forward_accum_dep_cents?: number
    brought_forward_as_of?: string
    brought_forward_journal_id?: string
    vendor_id?: string
    source_bill_id?: string
    serial_number?: string
    location?: string
    notes?: string
    pledged?: boolean
    idle?: boolean
    component_parent_id?: string
  },
  userId?: string
) {
  if (!FIXED_ASSET_CLASSES.includes(data.class as (typeof FIXED_ASSET_CLASSES)[number])) {
    throw new Error('class must be equipment, furniture, leasehold_improvements, or intangible')
  }

  const supabase = createServiceClient()
  const { data: result, error } = await supabase.rpc('register_fixed_asset', {
    p_description: data.description,
    p_class: data.class,
    p_cost_cents: data.cost_cents,
    p_useful_life_months: data.useful_life_months,
    p_acquisition_date: data.acquisition_date,
    p_in_service_date: data.in_service_date,
    p_residual_cents: data.residual_cents ?? 0,
    p_asset_account_id: data.asset_account_id || null,
    p_accum_dep_account_id: data.accum_dep_account_id || null,
    p_dep_expense_account_id: data.dep_expense_account_id || null,
    p_credit_account_id: data.credit_account_id || null,
    p_post_acquisition: data.post_acquisition !== false && !data.existing_journal_id,
    p_existing_journal_id: data.existing_journal_id || null,
    p_brought_forward_accum_dep_cents: data.brought_forward_accum_dep_cents ?? 0,
    p_brought_forward_as_of: data.brought_forward_as_of || null,
    p_brought_forward_journal_id: data.brought_forward_journal_id || null,
    p_vendor_id: data.vendor_id || null,
    p_source_bill_id: data.source_bill_id || null,
    p_serial_number: data.serial_number || null,
    p_location: data.location || null,
    p_notes: data.notes || null,
    p_pledged: data.pledged ?? false,
    p_idle: data.idle ?? false,
    p_component_parent_id: data.component_parent_id || null,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!result?.success) throw new Error(result?.error || 'Failed to register fixed asset')

  return {
    success: true,
    asset_id: result.asset_id,
    number: result.number,
    journal_id: result.journal_id,
    organization_id: organizationId,
  }
}

export async function runDepreciation(
  organizationId: string,
  periodStart: string,
  userId?: string
) {
  const supabase = createServiceClient()
  const { data: result, error } = await supabase.rpc('run_depreciation', {
    p_period_start: periodStart,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!result?.success) throw new Error(result?.error || 'Failed to run depreciation')

  return {
    success: true,
    organization_id: organizationId,
    period_start: result.period_start,
    period_end: result.period_end,
    charged_count: result.charged_count,
    skipped_count: result.skipped_count,
    total: formatMoney(result.total_cents || 0, 'USD'),
    journal_ids: result.journal_ids || [],
    charges: result.charges || [],
  }
}

export async function disposeFixedAsset(
  organizationId: string,
  data: {
    asset_id: string
    disposal_date: string
    proceeds_cents?: number
    cash_account_id?: string
  },
  userId?: string
) {
  const supabase = createServiceClient()
  const { data: result, error } = await supabase.rpc('dispose_fixed_asset', {
    p_asset_id: data.asset_id,
    p_disposal_date: data.disposal_date,
    p_proceeds_cents: data.proceeds_cents ?? 0,
    p_cash_account_id: data.cash_account_id || null,
    p_user_id: userId || null,
  })

  if (error) throw new Error(error.message)
  if (!result?.success) throw new Error(result?.error || 'Failed to dispose fixed asset')

  return {
    success: true,
    asset_id: result.asset_id,
    journal_id: result.journal_id,
    organization_id: organizationId,
    nbv: formatMoney(result.nbv_cents || 0, 'USD'),
    proceeds: formatMoney(result.proceeds_cents || 0, 'USD'),
    gain: formatMoney(result.gain_cents || 0, 'USD'),
    loss: formatMoney(result.loss_cents || 0, 'USD'),
    month_depreciation: formatMoney(result.month_depreciation_cents || 0, 'USD'),
  }
}

export async function getPpeRollforward(
  organizationId: string,
  startDate: string,
  endDate: string
) {
  const supabase = createServiceClient()
  const { data, error } = await supabase.rpc('get_ppe_rollforward', {
    p_organization_id: organizationId,
    p_start_date: startDate,
    p_end_date: endDate,
  })

  if (error) throw new Error(error.message)

  return (data || []).map((row: {
    asset_class: string
    measurement_basis: string
    depreciation_method: string
    useful_lives: string
    opening_gross_cents: number
    additions_cents: number
    disposals_gross_cents: number
    closing_gross_cents: number
    opening_accum_cents: number
    depreciation_cents: number
    disposals_accum_cents: number
    closing_accum_cents: number
    opening_nbv_cents: number
    closing_nbv_cents: number
    pledged_cents: number
    idle_cents: number
    fully_depreciated_in_use_cents: number
  }) => ({
    class: row.asset_class,
    measurement_basis: row.measurement_basis,
    depreciation_method: row.depreciation_method,
    useful_lives: row.useful_lives,
    opening_gross: formatMoney(row.opening_gross_cents, 'USD'),
    additions: formatMoney(row.additions_cents, 'USD'),
    disposals_gross: formatMoney(row.disposals_gross_cents, 'USD'),
    closing_gross: formatMoney(row.closing_gross_cents, 'USD'),
    opening_accum: formatMoney(row.opening_accum_cents, 'USD'),
    depreciation: formatMoney(row.depreciation_cents, 'USD'),
    disposals_accum: formatMoney(row.disposals_accum_cents, 'USD'),
    closing_accum: formatMoney(row.closing_accum_cents, 'USD'),
    opening_nbv: formatMoney(row.opening_nbv_cents, 'USD'),
    closing_nbv: formatMoney(row.closing_nbv_cents, 'USD'),
    pledged: formatMoney(row.pledged_cents, 'USD'),
    idle: formatMoney(row.idle_cents, 'USD'),
    fully_depreciated_in_use: formatMoney(row.fully_depreciated_in_use_cents, 'USD'),
  }))
}

// ============================================================================
// VOID BILL / INVOICE (with credits)
// ============================================================================

export async function voidBill(
  organizationId: string,
  billId: string,
  userId?: string,
  voidDate?: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('void_bill', {
    p_bill_id: billId,
    p_user_id: userId || null,
    p_void_date: voidDate || null,
  })

  if (error) {
    // Parse PERIOD_LOCKED from exception message
    if (error.message.includes('PERIOD_LOCKED:')) {
      const msg = error.message.replace('PERIOD_LOCKED:', '').trim()
      const err: any = new Error(msg)
      err.code = 'PERIOD_LOCKED'
      throw err
    }
    const err: any = new Error(error.message)
    err.code = error.code || 'DATABASE_ERROR'
    throw err
  }
  
  if (!data?.success) {
    const err: any = new Error(data?.error || 'Failed to void bill')
    err.code = data?.error_code || 'UNKNOWN_ERROR'
    if (data?.period_name) err.period_name = data.period_name
    if (data?.period_status) err.period_status = data.period_status
    throw err
  }

  return {
    success: true,
    bill_id: billId,
    credit_id: data.credit_id || null,
    credit_amount_cents: data.credit_amount_cents || 0,
  }
}

export async function voidInvoice(
  organizationId: string,
  invoiceId: string,
  userId?: string,
  voidDate?: string
) {
  const supabase = createServiceClient()

  const { data, error } = await supabase.rpc('void_invoice', {
    p_invoice_id: invoiceId,
    p_user_id: userId || null,
    p_void_date: voidDate || null,
  })

  if (error) {
    // Parse PERIOD_LOCKED from exception message
    if (error.message.includes('PERIOD_LOCKED:')) {
      const msg = error.message.replace('PERIOD_LOCKED:', '').trim()
      const err: any = new Error(msg)
      err.code = 'PERIOD_LOCKED'
      throw err
    }
    const err: any = new Error(error.message)
    err.code = error.code || 'DATABASE_ERROR'
    throw err
  }
  
  if (!data?.success) {
    const err: any = new Error(data?.error || 'Failed to void invoice')
    err.code = data?.error_code || 'UNKNOWN_ERROR'
    if (data?.period_name) err.period_name = data.period_name
    if (data?.period_status) err.period_status = data.period_status
    throw err
  }

  return {
    success: true,
    invoice_id: invoiceId,
    credit_id: data.credit_id || null,
    credit_amount_cents: data.credit_amount_cents || 0,
  }
}

// ============================================================================
// SUPPLIER CREDITS
// ============================================================================

export async function applySupplierCredit(
  organizationId: string,
  data: {
    credit_id: string
    bill_id: string
    amount_cents: number
    idempotency_key?: string
  },
  userId?: string
) {
  const supabase = createServiceClient()

  const { data: result, error } = await supabase.rpc('apply_supplier_credit', {
    p_credit_id: data.credit_id,
    p_bill_id: data.bill_id,
    p_amount_cents: data.amount_cents,
    p_user_id: userId || null,
    p_idempotency_key: data.idempotency_key || null,
  })

  if (error) {
    // Parse exception error codes from RAISE EXCEPTION
    if (error.message.includes('PERIOD_LOCKED:')) {
      const msg = error.message.replace('PERIOD_LOCKED:', '').trim()
      const err: any = new Error(msg)
      err.code = 'PERIOD_LOCKED'
      throw err
    }
    if (error.message.includes('INSUFFICIENT_BALANCE:')) {
      const msg = error.message.replace('INSUFFICIENT_BALANCE:', '').trim()
      const err: any = new Error(msg)
      err.code = 'INSUFFICIENT_BALANCE'
      throw err
    }
    if (error.message.includes('VALIDATION_ERROR:')) {
      const msg = error.message.replace('VALIDATION_ERROR:', '').trim()
      const err: any = new Error(msg)
      err.code = 'VALIDATION_ERROR'
      throw err
    }
    if (error.message.includes('INVALID_STATUS:')) {
      const msg = error.message.replace('INVALID_STATUS:', '').trim()
      const err: any = new Error(msg)
      err.code = 'INVALID_STATUS'
      throw err
    }
    const err: any = new Error(error.message)
    err.code = error.code || 'DATABASE_ERROR'
    throw err
  }
  
  if (!result?.success) {
    const err: any = new Error(result?.error || 'Failed to apply supplier credit')
    err.code = result?.error_code || 'UNKNOWN_ERROR'
    throw err
  }

  return {
    success: true,
    credit_id: data.credit_id,
    bill_id: data.bill_id,
    applied_amount_cents: result.applied_amount_cents,
    credit_remaining_cents: result.credit_remaining_cents,
    bill_status: result.bill_status,
  }
}

export async function refundSupplierCredit(
  organizationId: string,
  data: {
    credit_id: string
    amount_cents: number
    cash_account_id?: string
    refund_date?: string
    idempotency_key?: string
  },
  userId?: string
) {
  const supabase = createServiceClient()

  const { data: result, error } = await supabase.rpc('refund_supplier_credit', {
    p_credit_id: data.credit_id,
    p_amount_cents: data.amount_cents,
    p_cash_account_id: data.cash_account_id || null,
    p_refund_date: data.refund_date || null,
    p_user_id: userId || null,
    p_idempotency_key: data.idempotency_key || null,
  })

  if (error) {
    // Parse exception error codes from RAISE EXCEPTION
    if (error.message.includes('PERIOD_LOCKED:')) {
      const msg = error.message.replace('PERIOD_LOCKED:', '').trim()
      const err: any = new Error(msg)
      err.code = 'PERIOD_LOCKED'
      throw err
    }
    if (error.message.includes('INSUFFICIENT_BALANCE:')) {
      const msg = error.message.replace('INSUFFICIENT_BALANCE:', '').trim()
      const err: any = new Error(msg)
      err.code = 'INSUFFICIENT_BALANCE'
      throw err
    }
    if (error.message.includes('VALIDATION_ERROR:')) {
      const msg = error.message.replace('VALIDATION_ERROR:', '').trim()
      const err: any = new Error(msg)
      err.code = 'VALIDATION_ERROR'
      throw err
    }
    const err: any = new Error(error.message)
    err.code = error.code || 'DATABASE_ERROR'
    throw err
  }
  
  if (!result?.success) {
    const err: any = new Error(result?.error || 'Failed to refund supplier credit')
    err.code = result?.error_code || 'UNKNOWN_ERROR'
    throw err
  }

  return {
    success: true,
    credit_id: data.credit_id,
    refunded_amount_cents: result.refunded_amount_cents,
    credit_remaining_cents: result.credit_remaining_cents,
    journal_id: result.journal_id,
  }
}

export async function listSupplierCredits(organizationId: string, params?: {
  contact_id?: string
  status?: string
}) {
  const supabase = createServiceClient()

  let query = supabase
    .from('supplier_credits')
    .select(`
      id,
      contact_id,
      source_bill_id,
      amount_cents,
      remaining_cents,
      status,
      created_at,
      contacts!inner(name),
      bills!inner(number)
    `)
    .eq('organization_id', organizationId)
    .order('created_at', { ascending: false })

  if (params?.contact_id) {
    query = query.eq('contact_id', params.contact_id)
  }
  if (params?.status) {
    query = query.eq('status', params.status)
  }

  const { data, error } = await query

  if (error) throw new Error(error.message)

  return data.map(credit => ({
    id: credit.id,
    contact_id: credit.contact_id,
    supplier_name: (credit.contacts as any).name,
    source_bill_number: (credit.bills as any).number,
    amount: formatMoney(credit.amount_cents, 'USD'),
    remaining: formatMoney(credit.remaining_cents, 'USD'),
    status: credit.status,
    created_at: credit.created_at,
  }))
}

// ============================================================================
// CUSTOMER CREDITS
// ============================================================================

export async function applyCustomerCredit(
  organizationId: string,
  data: {
    credit_id: string
    invoice_id: string
    amount_cents: number
    idempotency_key?: string
  },
  userId?: string
) {
  const supabase = createServiceClient()

  const { data: result, error } = await supabase.rpc('apply_customer_credit', {
    p_credit_id: data.credit_id,
    p_invoice_id: data.invoice_id,
    p_amount_cents: data.amount_cents,
    p_user_id: userId || null,
    p_idempotency_key: data.idempotency_key || null,
  })

  if (error) {
    // Parse exception error codes from RAISE EXCEPTION
    if (error.message.includes('PERIOD_LOCKED:')) {
      const msg = error.message.replace('PERIOD_LOCKED:', '').trim()
      const err: any = new Error(msg)
      err.code = 'PERIOD_LOCKED'
      throw err
    }
    if (error.message.includes('INSUFFICIENT_BALANCE:')) {
      const msg = error.message.replace('INSUFFICIENT_BALANCE:', '').trim()
      const err: any = new Error(msg)
      err.code = 'INSUFFICIENT_BALANCE'
      throw err
    }
    if (error.message.includes('VALIDATION_ERROR:')) {
      const msg = error.message.replace('VALIDATION_ERROR:', '').trim()
      const err: any = new Error(msg)
      err.code = 'VALIDATION_ERROR'
      throw err
    }
    if (error.message.includes('INVALID_STATUS:')) {
      const msg = error.message.replace('INVALID_STATUS:', '').trim()
      const err: any = new Error(msg)
      err.code = 'INVALID_STATUS'
      throw err
    }
    const err: any = new Error(error.message)
    err.code = error.code || 'DATABASE_ERROR'
    throw err
  }
  
  if (!result?.success) {
    const err: any = new Error(result?.error || 'Failed to apply customer credit')
    err.code = result?.error_code || 'UNKNOWN_ERROR'
    throw err
  }

  return {
    success: true,
    credit_id: data.credit_id,
    invoice_id: data.invoice_id,
    applied_amount_cents: result.applied_amount_cents,
    credit_remaining_cents: result.credit_remaining_cents,
    invoice_status: result.invoice_status,
  }
}

export async function refundCustomerCredit(
  organizationId: string,
  data: {
    credit_id: string
    amount_cents: number
    cash_account_id?: string
    refund_date?: string
    idempotency_key?: string
  },
  userId?: string
) {
  const supabase = createServiceClient()

  const { data: result, error } = await supabase.rpc('refund_customer_credit', {
    p_credit_id: data.credit_id,
    p_amount_cents: data.amount_cents,
    p_cash_account_id: data.cash_account_id || null,
    p_refund_date: data.refund_date || null,
    p_user_id: userId || null,
    p_idempotency_key: data.idempotency_key || null,
  })

  if (error) {
    // Parse exception error codes from RAISE EXCEPTION
    if (error.message.includes('PERIOD_LOCKED:')) {
      const msg = error.message.replace('PERIOD_LOCKED:', '').trim()
      const err: any = new Error(msg)
      err.code = 'PERIOD_LOCKED'
      throw err
    }
    if (error.message.includes('INSUFFICIENT_BALANCE:')) {
      const msg = error.message.replace('INSUFFICIENT_BALANCE:', '').trim()
      const err: any = new Error(msg)
      err.code = 'INSUFFICIENT_BALANCE'
      throw err
    }
    if (error.message.includes('VALIDATION_ERROR:')) {
      const msg = error.message.replace('VALIDATION_ERROR:', '').trim()
      const err: any = new Error(msg)
      err.code = 'VALIDATION_ERROR'
      throw err
    }
    const err: any = new Error(error.message)
    err.code = error.code || 'DATABASE_ERROR'
    throw err
  }
  
  if (!result?.success) {
    const err: any = new Error(result?.error || 'Failed to refund customer credit')
    err.code = result?.error_code || 'UNKNOWN_ERROR'
    throw err
  }

  return {
    success: true,
    credit_id: data.credit_id,
    refunded_amount_cents: result.refunded_amount_cents,
    credit_remaining_cents: result.credit_remaining_cents,
    journal_id: result.journal_id,
  }
}

export async function listCustomerCredits(organizationId: string, params?: {
  contact_id?: string
  status?: string
}) {
  const supabase = createServiceClient()

  let query = supabase
    .from('customer_credits')
    .select(`
      id,
      contact_id,
      source_invoice_id,
      amount_cents,
      remaining_cents,
      status,
      created_at,
      contacts!inner(name),
      invoices!inner(number)
    `)
    .eq('organization_id', organizationId)
    .order('created_at', { ascending: false })

  if (params?.contact_id) {
    query = query.eq('contact_id', params.contact_id)
  }
  if (params?.status) {
    query = query.eq('status', params.status)
  }

  const { data, error } = await query

  if (error) throw new Error(error.message)

  return data.map(credit => ({
    id: credit.id,
    contact_id: credit.contact_id,
    customer_name: (credit.contacts as any).name,
    source_invoice_number: (credit.invoices as any).number,
    amount: formatMoney(credit.amount_cents, 'USD'),
    remaining: formatMoney(credit.remaining_cents, 'USD'),
    status: credit.status,
    created_at: credit.created_at,
  }))
}
