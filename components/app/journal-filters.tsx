import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { JOURNAL_SOURCE_OPTIONS } from '@/lib/journal-source'
import {
  JOURNAL_STATUSES,
  type JournalListFilters,
} from '@/lib/journal-query'

type AccountOption = {
  id: string
  code: string
  name: string
}

const fieldClassName =
  'w-full rounded-[9px] border border-input bg-card px-3 py-2 text-sm'

export function JournalFilters({
  filters,
  accounts,
}: {
  filters: JournalListFilters
  accounts: AccountOption[]
}) {
  return (
    <form method="get" action="/journals" className="mb-6 rounded-[13px] border border-line bg-surface p-4">
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <div className="space-y-2">
          <label htmlFor="journal-from" className="page-kicker mb-0 block">
            Effective date from
          </label>
          <input
            id="journal-from"
            type="date"
            name="from"
            defaultValue={filters.from ?? ''}
            className={fieldClassName}
          />
        </div>

        <div className="space-y-2">
          <label htmlFor="journal-to" className="page-kicker mb-0 block">
            Effective date to
          </label>
          <input
            id="journal-to"
            type="date"
            name="to"
            defaultValue={filters.to ?? ''}
            className={fieldClassName}
          />
        </div>

        <div className="space-y-2">
          <label htmlFor="journal-account" className="page-kicker mb-0 block">
            Account
          </label>
          <select
            id="journal-account"
            name="account"
            defaultValue={filters.accountId ?? ''}
            className={fieldClassName}
          >
            <option value="">All accounts</option>
            {accounts.map((account) => (
              <option key={account.id} value={account.id}>
                {account.code} {account.name}
              </option>
            ))}
          </select>
        </div>

        <div className="space-y-2">
          <label htmlFor="journal-status" className="page-kicker mb-0 block">
            Status
          </label>
          <select
            id="journal-status"
            name="status"
            defaultValue={filters.status ?? ''}
            className={fieldClassName}
          >
            <option value="">All statuses</option>
            {JOURNAL_STATUSES.map((status) => (
              <option key={status} value={status}>
                {status}
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-[minmax(0,1fr)_minmax(0,2fr)_auto] xl:items-end">
        <div className="space-y-2">
          <label htmlFor="journal-source" className="page-kicker mb-0 block">
            Source
          </label>
          <select
            id="journal-source"
            name="source"
            defaultValue={filters.source ?? ''}
            className={fieldClassName}
          >
            <option value="">All sources</option>
            {JOURNAL_SOURCE_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
        </div>

        <div className="space-y-2">
          <label htmlFor="journal-q" className="page-kicker mb-0 block">
            Number or description
          </label>
          <input
            id="journal-q"
            type="search"
            name="q"
            defaultValue={filters.q ?? ''}
            placeholder="JE-2026-0046"
            className={fieldClassName}
          />
        </div>

        <div className="flex flex-wrap gap-2 sm:col-span-2 xl:col-span-1">
          <Button type="submit">Apply filters</Button>
          <Link href="/journals">
            <Button type="button" variant="ghost">
              Clear filters
            </Button>
          </Link>
        </div>
      </div>
    </form>
  )
}
