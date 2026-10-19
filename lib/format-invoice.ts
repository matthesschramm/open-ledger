// Invoice number formatting utilities

/**
 * Format an invoice number for display.
 * Converts bare sequences like "1" to "INV-YYYY-NNNN" format.
 * Already-formatted numbers pass through unchanged.
 * 
 * @param number - Raw invoice number from database
 * @param invoiceDate - Invoice date (YYYY-MM-DD format)
 * @returns Formatted invoice number (e.g., "INV-2026-0001")
 */
export function formatInvoiceNumber(number: string, invoiceDate: string): string {
  if (!number) return ''
  
  // If already formatted (contains "INV-"), return as-is
  if (number.includes('INV-')) {
    return number
  }
  
  // Extract year from invoice date
  const year = invoiceDate.split('-')[0]
  
  // Parse the raw number and zero-pad to 4 digits
  const sequence = parseInt(number, 10)
  if (isNaN(sequence)) {
    // If parsing fails, return original
    return number
  }
  
  return `INV-${year}-${String(sequence).padStart(4, '0')}`
}
