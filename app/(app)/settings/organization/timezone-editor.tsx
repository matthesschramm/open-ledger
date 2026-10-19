'use client'

import { useEffect, useState, useTransition } from 'react'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { updateOrganizationTimezone } from '@/lib/actions'
import { useRouter } from 'next/navigation'

export function TimezoneEditor({ 
  initialTimezone, 
  isOwner 
}: { 
  initialTimezone: string
  isOwner: boolean
}) {
  const [options, setOptions] = useState<Array<{ value: string; label: string }>>([])
  const [timezone, setTimezone] = useState(initialTimezone)
  const [message, setMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null)
  const [isPending, startTransition] = useTransition()
  const router = useRouter()

  useEffect(() => {
    try {
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
    }
  }, [])

  async function handleSave() {
    setMessage(null)
    startTransition(async () => {
      const result = await updateOrganizationTimezone(timezone)
      if (result.success) {
        setMessage({ type: 'success', text: 'Time zone updated.' })
        router.refresh()
      } else {
        setMessage({ type: 'error', text: result.error || 'Failed to update time zone' })
      }
    })
  }

  return (
    <div className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor="timezone">Time zone</Label>
        <select
          id="timezone"
          name="timezone"
          value={timezone}
          onChange={(e) => {
            setTimezone(e.target.value)
            setMessage(null)
          }}
          disabled={!isOwner}
          className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm disabled:bg-neutral-50 disabled:text-neutral-500"
        >
          {options.length === 0 && <option value={timezone}>{timezone}</option>}
          {options.map(opt => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
        <p className="text-sm text-muted-foreground">
          Used for posting times and period dates.
        </p>
        {!isOwner && (
          <p className="text-sm text-muted-foreground">
            Only company owners can change the time zone.
          </p>
        )}
      </div>
      {message && (
        <div className={`rounded-md px-3 py-2 text-sm ${
          message.type === 'success' 
            ? 'bg-green-50 text-green-800 border border-green-200' 
            : 'bg-destructive/15 text-destructive'
        }`}>
          {message.text}
        </div>
      )}
      {isOwner && (
        <Button
          onClick={handleSave}
          disabled={isPending || timezone === initialTimezone}
        >
          {isPending ? 'Saving...' : 'Save time zone'}
        </Button>
      )}
    </div>
  )
}
