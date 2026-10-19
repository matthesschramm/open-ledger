/**
 * Mock data for Phase 2 - Acme Corp
 * Organization: Acme Corp
 * Currency: USD
 * Current Period: August 2026 (Open)
 * FYE: December 31
 * 
 * ACCOUNTING RULES:
 * - All balances derived from journal lines only (no preset balances)
 * - Liabilities and equity are credit-normal
 * - Parent funding on 3100 APIC only
 * - Reports include Posted AND Reversed status (not Draft)
 */

export type AccountType = 'Asset' | 'Liability' | 'Equity' | 'Revenue' | 'Expense'
export type JournalStatus = 'Draft' | 'Posted' | 'Reversed'
export type BillStatus = 'Draft' | 'Awaiting Payment' | 'Paid' | 'Overdue'
export type ContactType = 'Vendor' | 'Other'
export type UserRole = 'owner' | 'bookkeeper' | 'read_only'

export interface Account {
  id: string
  code: string
  name: string
  type: AccountType
  category: string
  isHeader: boolean
  isCash: boolean
  isActive: boolean
}

export interface JournalEntry {
  id: string
  date: string
  number: string
  description: string
  status: JournalStatus
  createdBy: string
  lines: JournalLine[]
  reversalOf?: string
  reversedBy?: string
}

export interface JournalLine {
  accountId: string
  accountCode: string
  accountName: string
  debit: number
  credit: number
  memo?: string
}

export interface Contact {
  id: string
  name: string
  type: ContactType
  email?: string
  phone?: string
  address?: string
  isActive: boolean
}

export interface Bill {
  id: string
  vendorId: string
  vendorName: string
  billNumber: string
  date: string
  dueDate: string
  amount: number
  status: BillStatus
  description: string
  journalEntryId?: string
}

export const mockOrganization = {
  name: 'Acme Corp',
  currency: 'USD',
  fiscalYearEnd: { month: 12, day: 31 },
  currentPeriod: {
    month: 'August',
    year: 2026,
    status: 'Open',
    startDate: '2026-08-01',
    endDate: '2026-08-31',
  },
}

// Locked compact US Chart of Accounts
export const mockAccounts: Account[] = [
  // Assets
  { id: 'acc-1000', code: '1000', name: 'Cash', type: 'Asset', category: 'Cash', isHeader: true, isCash: false, isActive: true },
  { id: 'acc-1010', code: '1010', name: 'Operating cash', type: 'Asset', category: 'Cash', isHeader: false, isCash: true, isActive: true },
  { id: 'acc-1020', code: '1020', name: 'Savings / reserves', type: 'Asset', category: 'Cash', isHeader: false, isCash: true, isActive: true },
  { id: 'acc-1200', code: '1200', name: 'Prepaid expenses', type: 'Asset', category: 'Current Assets', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-1400', code: '1400', name: 'Due from parent', type: 'Asset', category: 'Current Assets', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-1500', code: '1500', name: 'Computer and equipment', type: 'Asset', category: 'Fixed Assets', isHeader: false, isCash: false, isActive: true },
  
  // Liabilities
  { id: 'acc-2000', code: '2000', name: 'Accounts payable', type: 'Liability', category: 'Current Liabilities', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-2100', code: '2100', name: 'Accrued expenses', type: 'Liability', category: 'Current Liabilities', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-2200', code: '2200', name: 'Due to parent', type: 'Liability', category: 'Current Liabilities', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-2300', code: '2300', name: 'Credit cards', type: 'Liability', category: 'Current Liabilities', isHeader: false, isCash: false, isActive: true },
  
  // Equity
  { id: 'acc-3000', code: '3000', name: 'Common stock', type: 'Equity', category: 'Equity', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-3100', code: '3100', name: 'Additional paid-in capital', type: 'Equity', category: 'Equity', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-3200', code: '3200', name: 'Retained earnings', type: 'Equity', category: 'Equity', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-3900', code: '3900', name: 'Opening balance equity', type: 'Equity', category: 'Equity', isHeader: false, isCash: false, isActive: true },
  
  // Revenue
  { id: 'acc-4000', code: '4000', name: 'Revenue', type: 'Revenue', category: 'Operating Revenue', isHeader: true, isCash: false, isActive: true },
  { id: 'acc-4010', code: '4010', name: 'Product / service revenue', type: 'Revenue', category: 'Operating Revenue', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-4100', code: '4100', name: 'Other income', type: 'Revenue', category: 'Operating Revenue', isHeader: false, isCash: false, isActive: true },
  
  // Expenses
  { id: 'acc-5000', code: '5000', name: 'Operating expenses', type: 'Expense', category: 'Operating Expenses', isHeader: true, isCash: false, isActive: true },
  { id: 'acc-5010', code: '5010', name: 'Contractors and professional', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5020', code: '5020', name: 'Legal and formation', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5030', code: '5030', name: 'Software and subscriptions', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5040', code: '5040', name: 'Banking and payments', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5050', code: '5050', name: 'Travel', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5060', code: '5060', name: 'Insurance', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5070', code: '5070', name: 'Payroll and benefits', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5080', code: '5080', name: 'Office and admin', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-5090', code: '5090', name: 'Tax expense', type: 'Expense', category: 'Operating Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-6000', code: '6000', name: 'Other expenses', type: 'Expense', category: 'Other Expenses', isHeader: false, isCash: false, isActive: true },
  { id: 'acc-6100', code: '6100', name: 'FX and rounding', type: 'Expense', category: 'Other Expenses', isHeader: false, isCash: false, isActive: true },
]

export const mockContacts: Contact[] = [
  { id: 'con-1', name: 'CloudTech Services', type: 'Vendor', email: 'billing@example.com', phone: '555-0101', address: '123 Tech St, San Francisco, CA', isActive: true },
  { id: 'con-2', name: 'Legal Partners LLP', type: 'Vendor', email: 'invoices@legalpartners.com', phone: '555-0102', address: '456 Law Ave, New York, NY', isActive: true },
  { id: 'con-3', name: 'Office Depot', type: 'Vendor', email: 'accounts@officedepot.com', phone: '555-0103', address: '789 Supply Dr, Chicago, IL', isActive: true },
  { id: 'con-4', name: 'Acme Parent Co', type: 'Other', email: 'treasury@acmeparent.com', phone: '555-0200', address: '100 Main St, Delaware', isActive: true },
]

export const mockBills: Bill[] = [
  { id: 'bill-1', vendorId: 'con-1', vendorName: 'CloudTech Services', billNumber: 'CT-2026-0815', date: '2026-08-15', dueDate: '2026-09-14', amount: 3200.00, status: 'Awaiting Payment', description: 'Cloud infrastructure - August 2026', journalEntryId: 'je-102' },
  { id: 'bill-2', vendorId: 'con-2', vendorName: 'Legal Partners LLP', billNumber: 'LP-445', date: '2026-08-10', dueDate: '2026-09-09', amount: 5500.00, status: 'Awaiting Payment', description: 'Legal services and consultation' },
  { id: 'bill-3', vendorId: 'con-3', vendorName: 'Office Depot', billNumber: 'OD-98234', date: '2026-08-05', dueDate: '2026-09-04', amount: 450.00, status: 'Paid', description: 'Office supplies', journalEntryId: 'je-103' },
]

// Journal entries: ALL balances derive from these only
// Reports include Posted AND Reversed status (not Draft)
export const mockJournalEntries: JournalEntry[] = [
  // Parent funding (required: Dr 1010 Operating cash, Cr 3100 APIC)
  {
    id: 'je-101',
    date: '2026-08-01',
    number: 'JE-2026-0101',
    description: 'Parent funding - initial capital',
    status: 'Posted',
    createdBy: 'Sarah Johnson',
    lines: [
      { accountId: 'acc-1010', accountCode: '1010', accountName: 'Operating cash', debit: 100000.00, credit: 0, memo: 'Initial funding from parent' },
      { accountId: 'acc-3100', accountCode: '3100', accountName: 'Additional paid-in capital', debit: 0, credit: 100000.00 },
    ],
  },
  
  // Bill: CloudTech Services
  {
    id: 'je-102',
    date: '2026-08-15',
    number: 'JE-2026-0102',
    description: 'CloudTech Services - Cloud infrastructure',
    status: 'Posted',
    createdBy: 'Mike Chen',
    lines: [
      { accountId: 'acc-5030', accountCode: '5030', accountName: 'Software and subscriptions', debit: 3200.00, credit: 0, memo: 'Cloud hosting August' },
      { accountId: 'acc-2000', accountCode: '2000', accountName: 'Accounts payable', debit: 0, credit: 3200.00, memo: 'Bill CT-2026-0815' },
    ],
  },
  
  // Cash payment for office supplies
  {
    id: 'je-103',
    date: '2026-08-05',
    number: 'JE-2026-0103',
    description: 'Office supplies - Office Depot',
    status: 'Posted',
    createdBy: 'Sarah Johnson',
    lines: [
      { accountId: 'acc-5080', accountCode: '5080', accountName: 'Office and admin', debit: 450.00, credit: 0 },
      { accountId: 'acc-1010', accountCode: '1010', accountName: 'Operating cash', debit: 0, credit: 450.00 },
    ],
  },
  
  // Professional services
  {
    id: 'je-104',
    date: '2026-08-12',
    number: 'JE-2026-0104',
    description: 'Contractor payment',
    status: 'Posted',
    createdBy: 'Mike Chen',
    lines: [
      { accountId: 'acc-5010', accountCode: '5010', accountName: 'Contractors and professional', debit: 8500.00, credit: 0 },
      { accountId: 'acc-1010', accountCode: '1010', accountName: 'Operating cash', debit: 0, credit: 8500.00 },
    ],
  },
  
  // Legal services bill
  {
    id: 'je-105',
    date: '2026-08-10',
    number: 'JE-2026-0105',
    description: 'Legal services - formation',
    status: 'Posted',
    createdBy: 'Sarah Johnson',
    lines: [
      { accountId: 'acc-5020', accountCode: '5020', accountName: 'Legal and formation', debit: 5500.00, credit: 0 },
      { accountId: 'acc-2000', accountCode: '2000', accountName: 'Accounts payable', debit: 0, credit: 5500.00 },
    ],
  },
  
  // Travel expense
  {
    id: 'je-106',
    date: '2026-08-18',
    number: 'JE-2026-0106',
    description: 'Business travel',
    status: 'Posted',
    createdBy: 'Mike Chen',
    lines: [
      { accountId: 'acc-5050', accountCode: '5050', accountName: 'Travel', debit: 1200.00, credit: 0 },
      { accountId: 'acc-2300', accountCode: '2300', accountName: 'Credit cards', debit: 0, credit: 1200.00 },
    ],
  },
  
  // Intercompany charge from parent
  {
    id: 'je-107',
    date: '2026-08-20',
    number: 'JE-2026-0107',
    description: 'IC charge: shared services allocation',
    status: 'Posted',
    createdBy: 'Sarah Johnson',
    lines: [
      { accountId: 'acc-5080', accountCode: '5080', accountName: 'Office and admin', debit: 2400.00, credit: 0, memo: 'Shared services' },
      { accountId: 'acc-2200', accountCode: '2200', accountName: 'Due to parent', debit: 0, credit: 2400.00 },
    ],
  },
  
  // Service revenue (original, will be reversed)
  {
    id: 'je-108',
    date: '2026-08-22',
    number: 'JE-2026-0108',
    description: 'Service revenue recognition',
    status: 'Reversed',
    createdBy: 'Mike Chen',
    reversedBy: 'je-109',
    lines: [
      { accountId: 'acc-1400', accountCode: '1400', accountName: 'Due from parent', debit: 5000.00, credit: 0, memo: 'Services to parent' },
      { accountId: 'acc-4010', accountCode: '4010', accountName: 'Product / service revenue', debit: 0, credit: 5000.00 },
    ],
  },
  
  // Reversal of service revenue
  {
    id: 'je-109',
    date: '2026-08-25',
    number: 'JE-2026-0109',
    description: 'REVERSAL: Service revenue recognition',
    status: 'Posted',
    createdBy: 'Mike Chen',
    reversalOf: 'je-108',
    lines: [
      { accountId: 'acc-4010', accountCode: '4010', accountName: 'Product / service revenue', debit: 5000.00, credit: 0, memo: 'Reversing prior revenue' },
      { accountId: 'acc-1400', accountCode: '1400', accountName: 'Due from parent', debit: 0, credit: 5000.00 },
    ],
  },
  
  // Banking fees
  {
    id: 'je-110',
    date: '2026-08-28',
    number: 'JE-2026-0110',
    description: 'Bank fees',
    status: 'Posted',
    createdBy: 'Sarah Johnson',
    lines: [
      { accountId: 'acc-5040', accountCode: '5040', accountName: 'Banking and payments', debit: 45.00, credit: 0 },
      { accountId: 'acc-1010', accountCode: '1010', accountName: 'Operating cash', debit: 0, credit: 45.00 },
    ],
  },
  
  // Draft entry (not included in reports)
  {
    id: 'je-draft-1',
    date: '2026-08-30',
    number: 'JE-2026-DRAFT-001',
    description: 'Pending insurance payment',
    status: 'Draft',
    createdBy: 'Sarah Johnson',
    lines: [
      { accountId: 'acc-5060', accountCode: '5060', accountName: 'Insurance', debit: 1800.00, credit: 0 },
      { accountId: 'acc-1010', accountCode: '1010', accountName: 'Operating cash', debit: 0, credit: 1800.00 },
    ],
  },
]

// Current user (for role-based UI)
export const mockCurrentUser = {
  id: 'user-1',
  name: 'Sarah Johnson',
  email: 'sarah@acme.example.com',
  role: 'owner' as UserRole,
}

// Helper functions for reports
// CRITICAL: Include Posted AND Reversed status (both visible on reports)
export function getPostedJournalEntries(): JournalEntry[] {
  return mockJournalEntries.filter(je => je.status === 'Posted' || je.status === 'Reversed')
}

export function getDraftJournalEntries(): JournalEntry[] {
  return mockJournalEntries.filter(je => je.status === 'Draft')
}

// Calculate account balance from journal lines only
export function calculateAccountBalance(accountId: string): number {
  const account = mockAccounts.find(a => a.id === accountId)
  if (!account || account.isHeader) return 0
  
  const postedEntries = getPostedJournalEntries()
  let debitTotal = 0
  let creditTotal = 0
  
  postedEntries.forEach(entry => {
    entry.lines.forEach(line => {
      if (line.accountId === accountId) {
        debitTotal += line.debit
        creditTotal += line.credit
      }
    })
  })
  
  // Return signed balance (debit-positive)
  return debitTotal - creditTotal
}

// Get cash accounts for Cash page
export function getCashAccounts(): Account[] {
  return mockAccounts.filter(a => a.isCash && a.isActive)
}

// Calculate total cash position
export function getTotalCash(): number {
  return getCashAccounts().reduce((sum, acc) => sum + calculateAccountBalance(acc.id), 0)
}

// Get bills by status
export function getBillsByStatus(status: BillStatus): Bill[] {
  return mockBills.filter(b => b.status === status)
}

// Calculate total due bills
export function getTotalDueBills(): number {
  return mockBills
    .filter(b => b.status === 'Awaiting Payment' || b.status === 'Overdue')
    .reduce((sum, bill) => sum + bill.amount, 0)
}

// Report calculations (only use posted and reversed journal entries)
export interface TrialBalanceRow {
  accountCode: string
  accountName: string
  accountType: AccountType
  debit: number
  credit: number
}

export function calculateTrialBalance(): { rows: TrialBalanceRow[], totalDebit: number, totalCredit: number } {
  const postedEntries = getPostedJournalEntries()
  const accountBalances = new Map<string, { debit: number, credit: number }>()
  
  // Calculate balances from posted and reversed journal entries
  postedEntries.forEach(entry => {
    entry.lines.forEach(line => {
      const existing = accountBalances.get(line.accountId) || { debit: 0, credit: 0 }
      accountBalances.set(line.accountId, {
        debit: existing.debit + line.debit,
        credit: existing.credit + line.credit,
      })
    })
  })
  
  // Build trial balance rows (exclude headers)
  const rows: TrialBalanceRow[] = []
  let totalDebit = 0
  let totalCredit = 0
  
  mockAccounts.forEach(account => {
    if (account.isHeader) return
    
    const balance = accountBalances.get(account.id)
    if (balance && (balance.debit > 0 || balance.credit > 0)) {
      // Show on normal balance side
      let debit = 0
      let credit = 0
      const signed = balance.debit - balance.credit
      
      if (account.type === 'Asset' || account.type === 'Expense') {
        // Debit-normal: show as debit if positive, credit if negative
        if (signed >= 0) {
          debit = signed
        } else {
          credit = -signed
        }
      } else {
        // Credit-normal (Liability, Equity, Revenue): show as credit if positive, debit if negative
        if (signed <= 0) {
          credit = -signed
        } else {
          debit = signed
        }
      }
      
      if (debit > 0 || credit > 0) {
        rows.push({
          accountCode: account.code,
          accountName: account.name,
          accountType: account.type,
          debit,
          credit,
        })
        totalDebit += debit
        totalCredit += credit
      }
    }
  })
  
  // Sort by account code
  rows.sort((a, b) => a.accountCode.localeCompare(b.accountCode))
  
  return { rows, totalDebit, totalCredit }
}

export interface PLRow {
  accountCode: string
  accountName: string
  amount: number
}

export function calculateProfitAndLoss(): {
  revenue: PLRow[]
  expenses: PLRow[]
  totalRevenue: number
  totalExpenses: number
  netIncome: number
} {
  const postedEntries = getPostedJournalEntries()
  const accountTotals = new Map<string, number>()
  
  // Calculate totals from posted and reversed journal entries
  postedEntries.forEach(entry => {
    entry.lines.forEach(line => {
      const account = mockAccounts.find(a => a.id === line.accountId)
      if (account && !account.isHeader && (account.type === 'Revenue' || account.type === 'Expense')) {
        const existing = accountTotals.get(line.accountId) || 0
        // signed = debit - credit (debit-positive)
        const change = line.debit - line.credit
        accountTotals.set(line.accountId, existing + change)
      }
    })
  })
  
  const revenue: PLRow[] = []
  const expenses: PLRow[] = []
  let totalRevenue = 0
  let totalExpenses = 0
  
  mockAccounts.forEach(account => {
    if (account.isHeader) return
    const signed = accountTotals.get(account.id) || 0
    if (signed !== 0) {
      if (account.type === 'Revenue') {
        // Revenue is credit-normal, so we display credit balance as positive
        const amount = -signed
        if (amount !== 0) {
          revenue.push({ accountCode: account.code, accountName: account.name, amount })
          totalRevenue += amount
        }
      } else if (account.type === 'Expense') {
        // Expense is debit-normal, so debit balance is positive
        const amount = signed
        if (amount !== 0) {
          expenses.push({ accountCode: account.code, accountName: account.name, amount })
          totalExpenses += amount
        }
      }
    }
  })
  
  revenue.sort((a, b) => a.accountCode.localeCompare(b.accountCode))
  expenses.sort((a, b) => a.accountCode.localeCompare(b.accountCode))
  
  return {
    revenue,
    expenses,
    totalRevenue,
    totalExpenses,
    netIncome: totalRevenue - totalExpenses,
  }
}

export interface BalanceSheetSection {
  accounts: { code: string, name: string, amount: number }[]
  total: number
}

export interface BalanceSheetData {
  assets: BalanceSheetSection
  liabilities: BalanceSheetSection
  equity: BalanceSheetSection
  totalAssets: number
  totalLiabilitiesAndEquity: number
}

export function calculateBalanceSheet(): BalanceSheetData {
  const postedEntries = getPostedJournalEntries()
  const accountBalances = new Map<string, number>()
  
  // Calculate signed balance for each account (debit - credit)
  postedEntries.forEach(entry => {
    entry.lines.forEach(line => {
      const existing = accountBalances.get(line.accountId) || 0
      accountBalances.set(line.accountId, existing + (line.debit - line.credit))
    })
  })
  
  const assets: { code: string, name: string, amount: number }[] = []
  const liabilities: { code: string, name: string, amount: number }[] = []
  const equity: { code: string, name: string, amount: number }[] = []
  
  // Calculate revenue and expense totals for equity section
  let revenueExpenseTotal = 0
  
  mockAccounts.forEach(account => {
    if (account.isHeader) return
    
    const signed = accountBalances.get(account.id) || 0
    if (signed !== 0) {
      if (account.type === 'Asset') {
        // Asset is debit-normal, show as-is
        assets.push({ code: account.code, name: account.name, amount: signed })
      } else if (account.type === 'Liability') {
        // Liability is credit-normal, show as positive credit
        liabilities.push({ code: account.code, name: account.name, amount: -signed })
      } else if (account.type === 'Equity') {
        // Equity is credit-normal, show as positive credit
        equity.push({ code: account.code, name: account.name, amount: -signed })
      } else if (account.type === 'Revenue' || account.type === 'Expense') {
        // For revenue/expense: revenue is credit (negative signed), expense is debit (positive signed)
        // Net income = revenue - expense = (-signed_revenue) - signed_expense
        revenueExpenseTotal += signed
      }
    }
  })
  
  // Add net income to equity (revenue - expense = -revenueExpenseTotal)
  const netIncome = -revenueExpenseTotal
  if (netIncome !== 0) {
    equity.push({ code: '', name: 'Net income (current period)', amount: netIncome })
  }
  
  const totalAssets = assets.reduce((sum, a) => sum + a.amount, 0)
  const totalLiabilities = liabilities.reduce((sum, l) => sum + l.amount, 0)
  const totalEquity = equity.reduce((sum, e) => sum + e.amount, 0)
  
  return {
    assets: { accounts: assets, total: totalAssets },
    liabilities: { accounts: liabilities, total: totalLiabilities },
    equity: { accounts: equity, total: totalEquity },
    totalAssets,
    totalLiabilitiesAndEquity: totalLiabilities + totalEquity,
  }
}
