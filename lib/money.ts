// Money formatting utilities
// Money is always stored as integer cents in the database
// API responses include both integer cents and formatted decimal string

export interface MoneyValue {
  amount_cents: number
  amount: string
  currency: string
}

/**
 * Format cents as a money value with both integer cents and decimal string
 */
export function formatMoney(cents: number, currency: string = 'USD'): MoneyValue {
  return {
    amount_cents: cents,
    amount: (cents / 100).toFixed(2),
    currency,
  }
}

/**
 * Parse a decimal amount string to cents
 */
export function parseMoney(amount: string): number {
  const parsed = parseFloat(amount)
  if (isNaN(parsed)) {
    throw new Error('Invalid money amount')
  }
  return Math.round(parsed * 100)
}

/**
 * Format money for CSV export (just the decimal string)
 */
export function formatMoneyCSV(cents: number): string {
  return (cents / 100).toFixed(2)
}

/**
 * Format money for display with US locale grouping separators.
 * Always shows 2 decimal places with comma thousands separators.
 * Negative amounts are formatted as -$200.00, not $-200.00
 * 
 * @param cents - Amount in cents
 * @returns Formatted string like "$5,000.00" or "-$200.00"
 */
export function formatCurrency(cents: number): string {
  const abs = Math.abs(cents)
  const formatted = '$' + (abs / 100).toLocaleString('en-US', { 
    minimumFractionDigits: 2, 
    maximumFractionDigits: 2 
  })
  return cents < 0 ? '-' + formatted : formatted
}
