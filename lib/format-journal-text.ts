// Format journal descriptions and memos that reference invoices
// Converts "Posted Invoice 1" to "Posted Invoice INV-2026-0001"

/**
 * Format invoice references in journal text.
 * Finds patterns like "Invoice 1" or "invoice 42" and replaces with INV-YYYY-NNNN format.
 * 
 * @param text - Journal description or memo text
 * @param entryDate - Journal entry date (YYYY-MM-DD format), used for year in invoice number
 * @returns Formatted text with invoice numbers as INV-YYYY-NNNN
 */
export function formatJournalText(text: string, entryDate: string): string {
  if (!text || !entryDate) return text || ''
  
  // Extract year from entry date
  const year = entryDate.split('-')[0]
  
  // Pattern matches "Invoice 123" or "invoice 123" (case insensitive)
  // Captures the number part for formatting
  const pattern = /\b(invoice)\s+(\d+)\b/gi
  
  return text.replace(pattern, (match, invoiceWord, numberStr) => {
    const sequence = parseInt(numberStr, 10)
    if (isNaN(sequence)) {
      return match // Return original if parsing fails
    }
    
    // Preserve original case of "Invoice" vs "invoice"
    const formattedInvoice = invoiceWord.charAt(0) === 'I' ? 'Invoice' : 'invoice'
    const formattedNumber = `INV-${year}-${String(sequence).padStart(4, '0')}`
    
    return `${formattedInvoice} ${formattedNumber}`
  })
}
