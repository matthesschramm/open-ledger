export const JOURNAL_SOURCES = [
  'manual',
  'bill',
  'bill_payment',
  'opening',
  'reversal',
  'cash',
  'fixed_asset',
  'depreciation',
  'disposal',
] as const

export type JournalSource = (typeof JOURNAL_SOURCES)[number]

const JOURNAL_SOURCE_LABELS = {
  manual: 'Manual',
  bill: 'Bill',
  bill_payment: 'Payment',
  opening: 'Opening',
  reversal: 'Reversal',
  cash: 'Cash',
  fixed_asset: 'Fixed asset',
  depreciation: 'Depreciation',
  disposal: 'Disposal',
} as const satisfies Record<JournalSource, string>

export function isJournalSource(value: string): value is JournalSource {
  for (const source of JOURNAL_SOURCES) {
    if (source === value) {
      return true
    }
  }
  return false
}

export function journalSourceLabel(source: string): string {
  if (isJournalSource(source)) {
    return JOURNAL_SOURCE_LABELS[source]
  }
  return source
}

export const JOURNAL_SOURCE_OPTIONS = JOURNAL_SOURCES.map((value) => ({
  value,
  label: JOURNAL_SOURCE_LABELS[value],
}))
