// Fiscal year utilities
// Calculate fiscal year start date based on fiscal year end configuration

/**
 * Get the fiscal year start date for the current fiscal year
 * @param fiscalYearEndMonth - 1-12 (e.g., 12 for December)
 * @param fiscalYearEndDay - 1-31
 * @returns YYYY-MM-DD string for fiscal year start
 */
export function getFiscalYearStart(fiscalYearEndMonth: number, fiscalYearEndDay: number): string {
  const today = new Date()
  const currentYear = today.getFullYear()
  const currentMonth = today.getMonth() + 1
  const currentDay = today.getDate()
  
  // Calculate fiscal year start: day after fiscal year end
  let fyStartMonth = fiscalYearEndMonth
  let fyStartDay = fiscalYearEndDay + 1
  
  // Handle month rollover
  const daysInMonth = new Date(currentYear, fiscalYearEndMonth, 0).getDate()
  if (fyStartDay > daysInMonth) {
    fyStartDay = 1
    fyStartMonth = (fiscalYearEndMonth % 12) + 1
  }
  
  // Determine fiscal year
  // If FYE is 12/31, FY start is 1/1 of same year
  // If FYE is 6/30, FY start is 7/1 of previous year (if before 7/1) or current year (if after 6/30)
  let fyStartYear = currentYear
  
  // Check if we're currently before the fiscal year end
  const isBeforeFYE = 
    currentMonth < fiscalYearEndMonth ||
    (currentMonth === fiscalYearEndMonth && currentDay <= fiscalYearEndDay)
  
  // If fiscal year starts in month > FYE month (e.g., FYE 6/30, start 7/1)
  // and we're before the FYE, we need previous year's start
  if (fyStartMonth > fiscalYearEndMonth && isBeforeFYE) {
    fyStartYear = currentYear - 1
  }
  // If fiscal year starts in month <= FYE month (e.g., FYE 12/31, start 1/1)
  // and we're before the FYE, we're still in current FY which started in current year
  // (no adjustment needed)
  
  // Format as YYYY-MM-DD without timezone conversion
  const monthStr = String(fyStartMonth).padStart(2, '0')
  const dayStr = String(fyStartDay).padStart(2, '0')
  
  return `${fyStartYear}-${monthStr}-${dayStr}`
}

/**
 * Get current date as YYYY-MM-DD in Australia/Melbourne timezone
 */
export function getCurrentDateString(): string {
  // Use Australia/Melbourne timezone for consistent date handling
  const formatter = new Intl.DateTimeFormat('en-AU', {
    timeZone: 'Australia/Melbourne',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  })
  
  const parts = formatter.formatToParts(new Date())
  const year = parts.find(p => p.type === 'year')?.value
  const month = parts.find(p => p.type === 'month')?.value
  const day = parts.find(p => p.type === 'day')?.value
  
  return `${year}-${month}-${day}`
}

/**
 * Format a YYYY-MM-DD date string for display without timezone conversion
 * @param dateString - YYYY-MM-DD string
 * @returns Formatted date like "8/1/2026"
 */
export function formatDate(dateString: string): string {
  const [year, month, day] = dateString.split('-').map(Number)
  return `${month}/${day}/${year}`
}
