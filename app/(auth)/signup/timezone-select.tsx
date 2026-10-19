'use client'

import { useEffect, useState } from 'react'
import { Label } from '@/components/ui/label'

export function TimezoneSelect() {
  const [options, setOptions] = useState<Array<{ value: string; label: string }>>([])
  const [detected, setDetected] = useState<string>('')

  useEffect(() => {
    try {
      const detectedTz = Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/New_York'
      setDetected(detectedTz)

      const now = new Date()
      const allZones = Intl.supportedValuesOf('timeZone')
      
      // Ensure UTC is in the list
      const zones = allZones.includes('UTC') ? allZones : [...allZones, 'UTC']
      
      const formatted = zones.map(tz => {
        try {
          // Try en-US first
          let locale = 'en-US'
          if (tz.startsWith('Australia/')) {
            locale = 'en-AU'
          } else if (tz.startsWith('Europe/London')) {
            locale = 'en-GB'
          } else if (tz.startsWith('Pacific/Auckland') || tz.startsWith('Pacific/Fiji')) {
            locale = 'en-NZ'
          }

          const fmt = new Intl.DateTimeFormat(locale, {
            timeZone: tz,
            timeZoneName: 'short'
          })
          const parts = fmt.formatToParts(now)
          let abbr = parts.find(p => p.type === 'timeZoneName')?.value || ''
          
          // If we got a GMT offset, try fallback locales
          if (abbr.includes('GMT')) {
            if (locale !== 'en-US') {
              const fallbackFmt = new Intl.DateTimeFormat('en-US', {
                timeZone: tz,
                timeZoneName: 'short'
              })
              const fallbackParts = fallbackFmt.formatToParts(now)
              const fallbackAbbr = fallbackParts.find(p => p.type === 'timeZoneName')?.value || ''
              if (!fallbackAbbr.includes('GMT')) {
                abbr = fallbackAbbr
              }
            }
            
            if (abbr.includes('GMT')) {
              const secondaryLocale = tz.startsWith('Australia/') ? 'en-AU' : 
                                      tz.startsWith('Europe/London') ? 'en-GB' : null
              if (secondaryLocale && secondaryLocale !== locale) {
                const secondaryFmt = new Intl.DateTimeFormat(secondaryLocale, {
                  timeZone: tz,
                  timeZoneName: 'short'
                })
                const secondaryParts = secondaryFmt.formatToParts(now)
                const secondaryAbbr = secondaryParts.find(p => p.type === 'timeZoneName')?.value || ''
                if (!secondaryAbbr.includes('GMT')) {
                  abbr = secondaryAbbr
                }
              }
            }
          }

          return {
            value: tz,
            label: abbr ? `${tz} (${abbr})` : tz
          }
        } catch {
          return { value: tz, label: tz }
        }
      })

      setOptions(formatted)
    } catch (e) {
      console.warn('Could not populate timezones:', e)
      setOptions([{ value: 'America/New_York', label: 'America/New_York (EST)' }])
      setDetected('America/New_York')
    }
  }, [])

  return (
    <div className="space-y-2">
      <Label htmlFor="timezone">Time zone</Label>
      <select
        id="timezone"
        name="timezone"
        value={detected}
        onChange={(e) => setDetected(e.target.value)}
        className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
        required
      >
        {options.length === 0 && <option value="">Loading...</option>}
        {options.map(opt => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
      </select>
      <p className="text-sm text-muted-foreground">
        Used for posting times and period dates.
      </p>
    </div>
  )
}
