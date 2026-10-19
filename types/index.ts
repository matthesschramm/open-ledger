// TypeScript type definitions

// Database types will be auto-generated from Supabase schema in future phases

// Example types (placeholders)
export interface Account {
  id: string
  code: string
  name: string
  type: 'Asset' | 'Liability' | 'Equity' | 'Revenue' | 'Expense'
  balance: number
}

export interface JournalEntry {
  id: string
  date: string
  number: string
  description: string
  status: 'Draft' | 'Posted'
  lines: JournalLine[]
}

export interface JournalLine {
  id: string
  accountId: string
  debit: number
  credit: number
  memo?: string
}

export interface Contact {
  id: string
  name: string
  type: 'Customer' | 'Vendor'
  email?: string
  balance: number
}

export interface Bill {
  id: string
  vendorId: string
  number: string
  date: string
  dueDate: string
  amount: number
  status: 'Unpaid' | 'Paid'
}
