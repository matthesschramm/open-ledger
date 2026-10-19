// Local date utilities for Australia/Melbourne timezone
// All dates in Open Ledger represent calendar days in Melbourne time,
// not UTC. This ensures consistent date handling across the application.

const MELBOURNE_TZ = 'Australia/Melbourne'

/**
 * Get the current date in Melbourne timezone as YYYY-MM-DD
 * @param date - Optional date to convert (defaults to now)
 * @returns YYYY-MM-DD string for Melbourne calendar day
 */
export function getMelbourneLocalDate(date?: Date): string {
  const d = date || new Date()
  
  // Use Intl.DateTimeFormat to get date parts in Melbourne timezone
  const formatter = new Intl.DateTimeFormat('en-AU', {
    timeZone: MELBOURNE_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  })
  
  const parts = formatter.formatToParts(d)
  const year = parts.find(p => p.type === 'year')?.value
  const month = parts.find(p => p.type === 'month')?.value
  const day = parts.find(p => p.type === 'day')?.value
  
  return `${year}-${month}-${day}`
}

/**
 * Format a UTC timestamp to Melbourne local date and time
 * @param timestamp - ISO timestamp string or null/undefined
 * @returns Formatted string like "31/8/2026, 12:30 am" or empty string
 */
export function formatMelbourneTimestamp(
  timestamp: string | null | undefined
): string {
  if (!timestamp) return ''
  
  const date = new Date(timestamp)
  
  // Format to Melbourne timezone
  const formatter = new Intl.DateTimeFormat('en-AU', {
    timeZone: MELBOURNE_TZ,
    day: 'numeric',
    month: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
  
  return formatter.format(date)
}

/**
 * Get the Melbourne local date for a timestamp (YYYY-MM-DD)
 * Useful for converting posted_at timestamps to date strings
 */
export function getMelbourneDateFromTimestamp(
  timestamp: string | null | undefined
): string {
  if (!timestamp) return ''
  return getMelbourneLocalDate(new Date(timestamp))
}
