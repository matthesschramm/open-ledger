/**
 * Validates if a timezone string is supported by Intl
 */
export function isValidTimeZone(timezone: string): boolean {
  if (!timezone || timezone.trim() === '') {
    return false
  }

  const supportedZones = Intl.supportedValuesOf('timeZone')
  const validZones = supportedZones.includes('UTC') ? supportedZones : [...supportedZones, 'UTC']
  return validZones.includes(timezone.trim())
}
