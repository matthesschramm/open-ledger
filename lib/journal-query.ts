import { isJournalSource, type JournalSource } from '@/lib/journal-source'

export const JOURNAL_STATUSES = ['Draft', 'Posted', 'Reversed'] as const
export type JournalStatus = (typeof JOURNAL_STATUSES)[number]

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

export function firstSearchParam(
  value: string | string[] | undefined
): string | undefined {
  if (Array.isArray(value)) {
    return value[0]
  }
  return value
}

export function parseIsoDate(value: string | undefined): string | null {
  if (!value || !ISO_DATE.test(value)) {
    return null
  }
  return value
}

export function parseUuid(value: string | undefined): string | null {
  if (!value || !UUID.test(value)) {
    return null
  }
  return value
}

export function parseJournalStatus(value: string | undefined): JournalStatus | null {
  if (!value) {
    return null
  }
  if (value === 'draft' || value === 'Draft') {
    return 'Draft'
  }
  if (value === 'Posted' || value === 'Reversed') {
    return value
  }
  return null
}

export function parseJournalSource(value: string | undefined): JournalSource | null {
  if (!value || !isJournalSource(value)) {
    return null
  }
  return value
}

export function sanitizeJournalSearch(value: string | undefined): string | null {
  if (!value) {
    return null
  }
  const safe = value.replace(/[^a-zA-Z0-9 .\-/]/g, '').trim().slice(0, 80)
  return safe || null
}

export type JournalListFilters = {
  from: string | null
  to: string | null
  accountId: string | null
  status: JournalStatus | null
  source: JournalSource | null
  q: string | null
}

export function parseJournalListFilters(params: {
  from?: string | string[]
  to?: string | string[]
  account?: string | string[]
  status?: string | string[]
  source?: string | string[]
  q?: string | string[]
}): JournalListFilters {
  return {
    from: parseIsoDate(firstSearchParam(params.from)),
    to: parseIsoDate(firstSearchParam(params.to)),
    accountId: parseUuid(firstSearchParam(params.account)),
    status: parseJournalStatus(firstSearchParam(params.status)),
    source: parseJournalSource(firstSearchParam(params.source)),
    q: sanitizeJournalSearch(firstSearchParam(params.q)),
  }
}

export function journalFiltersAreActive(filters: JournalListFilters): boolean {
  return Boolean(
    filters.from ||
      filters.to ||
      filters.accountId ||
      filters.status ||
      filters.source ||
      filters.q
  )
}
