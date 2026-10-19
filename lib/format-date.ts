// Date formatting utilities
// For YYYY-MM-DD dates representing calendar days (not timestamps)

export function formatDate(dateString: string | null | undefined): string {
  if (!dateString) return ''
  
  // Parse YYYY-MM-DD without any Date construction
  const [year, month, day] = dateString.split('T')[0].split('-')
  if (!year || !month || !day) return dateString
  
  // Format as M/D/YYYY directly from string parts
  return `${parseInt(month)}/${parseInt(day)}/${year}`
}

export function formatDateLong(dateString: string | null | undefined): string {
  if (!dateString) return ''
  
  // Parse YYYY-MM-DD without any Date construction
  const [year, month, day] = dateString.split('T')[0].split('-')
  if (!year || !month || !day) return dateString
  
  const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December']
  
  const monthName = monthNames[parseInt(month) - 1]
  return `${monthName} ${parseInt(day)}, ${year}`
}

/**
 * Get company-local today as YYYY-MM-DD
 * @param timezone IANA timezone string (e.g. 'America/New_York')
 * @returns YYYY-MM-DD string for today in the company timezone
 * 
 * CRITICAL ACCOUNTING RULE:
 * This function uses the company's timezone setting to determine what "today" is
 * for NEW journal entries going forward. Changing the company timezone NEVER
 * rewrites existing journal entry_date values or moves journals between periods.
 * Existing journals keep their original entry_date and stay in their original periods.
 * Period lock continues to check each journal's own entry_date field.
 */
export function companyToday(timezone: string): string {
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  })
  
  return formatter.format(new Date())
}

/**
 * @deprecated Use companyToday(timezone) instead
 */
export function getLocalDateString(): string {
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
 * Format a UTC timestamp to company-local date and time with timezone abbreviation
 * @param timestamp ISO timestamp string or null/undefined
 * @param timezone IANA timezone string (e.g. 'America/New_York')
 * @returns Formatted string like "10/14/2026, 1:48 am EDT" or "10/14/2026, 4:48 pm AEDT" or empty string
 */
export function formatTimestamp(
  timestamp: string | null | undefined,
  timezone: string
): string {
  if (!timestamp) return ''
  
  const date = new Date(timestamp)
  
  // Always format date+time with en-US for consistent M/D/YYYY, h:mm am/pm format
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    day: 'numeric',
    month: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
  
  // Build string from parts with lowercase am/pm
  const parts = formatter.formatToParts(date)
  let result = ''
  for (const part of parts) {
    if (part.type === 'dayPeriod') {
      result += part.value.toLowerCase()
    } else {
      result += part.value
    }
  }
  
  // Replace narrow no-break space with normal space
  result = result.replace(/\u202f/g, ' ')
  
  // Extract timezone abbreviation using locale-specific formatter for proper abbreviations
  let locale = 'en-US'
  if (timezone.startsWith('Australia/')) {
    locale = 'en-AU'
  } else if (timezone.startsWith('Europe/London')) {
    locale = 'en-GB'
  } else if (timezone.startsWith('Pacific/Auckland') || timezone.startsWith('Pacific/Fiji')) {
    locale = 'en-NZ'
  }
  
  const tzFormatter = new Intl.DateTimeFormat(locale, {
    timeZone: timezone,
    timeZoneName: 'short',
  })
  const tzParts = tzFormatter.formatToParts(date)
  let tzAbbr = tzParts.find(part => part.type === 'timeZoneName')?.value || ''
  
  // If we got a GMT offset, try falling back to en-US then region-specific locale
  if (tzAbbr.includes('GMT')) {
    // Try en-US first if we haven't already
    if (locale !== 'en-US') {
      const fallbackFormatter = new Intl.DateTimeFormat('en-US', {
        timeZone: timezone,
        timeZoneName: 'short',
      })
      const fallbackParts = fallbackFormatter.formatToParts(date)
      const fallbackAbbr = fallbackParts.find(part => part.type === 'timeZoneName')?.value || ''
      if (!fallbackAbbr.includes('GMT')) {
        tzAbbr = fallbackAbbr
      }
    }
    
    // If still GMT and not already tried, try region-specific locale
    if (tzAbbr.includes('GMT')) {
      const secondaryLocale = timezone.startsWith('Australia/') ? 'en-AU' : 
                              timezone.startsWith('Europe/London') ? 'en-GB' : null
      if (secondaryLocale && secondaryLocale !== locale) {
        const secondaryFormatter = new Intl.DateTimeFormat(secondaryLocale, {
          timeZone: timezone,
          timeZoneName: 'short',
        })
        const secondaryParts = secondaryFormatter.formatToParts(date)
        const secondaryAbbr = secondaryParts.find(part => part.type === 'timeZoneName')?.value || ''
        if (!secondaryAbbr.includes('GMT')) {
          tzAbbr = secondaryAbbr
        }
      }
    }
  }
  
  return `${result} ${tzAbbr}`
}

/**
 * Format a UTC timestamp to company-local date only (M/D/YYYY)
 * @param timestamp ISO timestamp string or null/undefined
 * @param timezone IANA timezone string (e.g. 'America/New_York')
 * @returns Formatted string like "10/14/2026" or empty string
 */
export function formatTimestampDate(
  timestamp: string | null | undefined,
  timezone: string
): string {
  if (!timestamp) return ''
  
  const date = new Date(timestamp)
  
  // Format to company timezone with US locale (month-first)
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    day: 'numeric',
    month: 'numeric',
    year: 'numeric',
  })
  
  return formatter.format(date)
}
