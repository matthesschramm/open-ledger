import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { Paperclip, Plus } from 'lucide-react'
import { EmptyState } from '@/components/app/empty-state'
import { JournalFilters } from '@/components/app/journal-filters'
import { formatDate } from '@/lib/format-date'
import { formatJournalText } from '@/lib/format-journal-text'
import { journalSourceLabel } from '@/lib/journal-source'
import {
  firstSearchParam,
  journalFiltersAreActive,
  parseJournalListFilters,
} from '@/lib/journal-query'

type JournalListRow = {
  id: string
  number: string | null
  description: string
  entry_date: string
  status: string
  source: string
}

type AccountOption = {
  id: string
  code: string
  name: string
}

function parseJournalListRow(value: unknown): JournalListRow | null {
  if (!value || typeof value !== 'object') {
    return null
  }
  if (!('id' in value) || typeof value.id !== 'string') {
    return null
  }
  if (!('number' in value) || (value.number !== null && typeof value.number !== 'string')) {
    return null
  }
  if (!('description' in value) || typeof value.description !== 'string') {
    return null
  }
  if (!('entry_date' in value) || typeof value.entry_date !== 'string') {
    return null
  }
  if (!('status' in value) || typeof value.status !== 'string') {
    return null
  }
  if (!('source' in value) || typeof value.source !== 'string') {
    return null
  }
  return {
    id: value.id,
    number: value.number as string | null,
    description: value.description,
    entry_date: value.entry_date,
    status: value.status,
    source: value.source,
  }
}

function parseAccountOption(value: unknown): AccountOption | null {
  if (!value || typeof value !== 'object') {
    return null
  }
  if (!('id' in value) || typeof value.id !== 'string') {
    return null
  }
  if (!('code' in value) || typeof value.code !== 'string') {
    return null
  }
  if (!('name' in value) || typeof value.name !== 'string') {
    return null
  }
  return { id: value.id, code: value.code, name: value.name }
}

function statusClass(status: string): string {
  if (status === 'Draft') {
    return 'status-pill bg-yellow-50 text-yellow-700'
  }
  if (status === 'Posted') {
    return 'status-pill bg-green-50 text-green-700'
  }
  return 'status-pill bg-neutral-100 text-neutral-600'
}

export default async function JournalsPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>
}) {
  const params = await searchParams
  const showEmpty = firstSearchParam(params.empty) === '1'
  const filters = parseJournalListFilters(params)
  const filtersActive = journalFiltersAreActive(filters)

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  const [{ data: currentRole }, { data: accountsData }] = await Promise.all([
    supabase.rpc('current_role'),
    supabase
      .from('accounts')
      .select('id, code, name')
      .eq('is_header', false)
      .eq('is_active', true)
      .order('code'),
  ])
  const canCreate = currentRole === 'owner' || currentRole === 'bookkeeper'

  const accounts = (accountsData ?? []).flatMap((row) => {
    const parsed = parseAccountOption(row)
    return parsed ? [parsed] : []
  })

  if (showEmpty) {
    return (
      <div className="p-8">
        <div className="mb-8 flex items-center justify-between">
          <div>
            <p className="page-kicker">Books</p>
            <h1 className="text-3xl font-semibold tracking-tight">Journals</h1>
            <p className="text-muted-foreground">Double-entry journal entries</p>
          </div>
          {canCreate && (
            <Link href="/journals/new">
              <Button>
                <Plus className="h-4 w-4 mr-2" />
                New journal
              </Button>
            </Link>
          )}
        </div>
        <EmptyState
          icon={<Plus className="h-8 w-8 text-coral" />}
          title="No journals"
          description="Every amount in the books starts here. Post an opening journal, or record spend."
          actions={[
            { label: 'New journal', href: '/journals/new' },
          ]}
        />
      </div>
    )
  }

  const select = filters.accountId
    ? 'id, number, description, entry_date, status, source, journal_lines!inner(account_id)'
    : 'id, number, description, entry_date, status, source'

  let query = supabase
    .from('journals')
    .select(select)
    .order('entry_date', { ascending: false, nullsFirst: false })
    .order('created_at', { ascending: false, nullsFirst: false })

  if (filters.accountId) {
    query = query.eq('journal_lines.account_id', filters.accountId)
  }
  if (filters.from) {
    query = query.gte('entry_date', filters.from)
  }
  if (filters.to) {
    query = query.lte('entry_date', filters.to)
  }
  if (filters.status) {
    query = query.eq('status', filters.status)
  }
  if (filters.source) {
    query = query.eq('source', filters.source)
  }
  if (filters.q) {
    query = query.or(`number.ilike.%${filters.q}%,description.ilike.%${filters.q}%`)
  }

  const { data: journalRows } = await query

  const seen = new Set<string>()
  const journals: JournalListRow[] = []
  for (const row of journalRows ?? []) {
    const parsed = parseJournalListRow(row)
    if (!parsed || seen.has(parsed.id)) {
      continue
    }
    seen.add(parsed.id)
    journals.push(parsed)
  }

  const attachmentCounts = new Map<string, number>()
  if (journals.length > 0) {
    const { data: attachmentRows } = await supabase
      .from('attachments')
      .select('entity_id')
      .eq('entity_type', 'journal')
      .in('entity_id', journals.map((journal) => journal.id))

    for (const row of attachmentRows ?? []) {
      if (!row || typeof row !== 'object' || !('entity_id' in row) || typeof row.entity_id !== 'string') {
        continue
      }
      attachmentCounts.set(row.entity_id, (attachmentCounts.get(row.entity_id) ?? 0) + 1)
    }
  }

  return (
    <div className="p-8">
      <div className="mb-8 flex items-center justify-between">
        <div>
          <p className="page-kicker">Books</p>
          <h1 className="text-3xl font-semibold tracking-tight">Journals</h1>
          <p className="text-muted-foreground">Double-entry journal entries</p>
        </div>
        {canCreate && (
          <Link href="/journals/new">
            <Button>
              <Plus className="h-4 w-4 mr-2" />
              New journal
            </Button>
          </Link>
        )}
      </div>

      <JournalFilters filters={filters} accounts={accounts} />

      {journals.length > 0 ? (
        <div className="overflow-hidden rounded-[10px] border border-line-strong bg-card">
          <div className="grid grid-cols-[minmax(0,1fr)_auto] gap-4 bg-[#f6f5ef] px-4 py-2.5 font-mono text-[0.58rem] font-semibold uppercase tracking-[0.08em] text-muted-foreground">
            <span>Entry</span>
            <span>Effective date</span>
          </div>
          {journals.map((journal) => {
            const attachmentCount = attachmentCounts.get(journal.id) ?? 0
            return (
              <Link
                key={journal.id}
                href={`/journals/${journal.id}`}
                className="grid grid-cols-[minmax(0,1fr)_auto] gap-4 border-t border-line px-4 py-4 transition-colors hover:bg-surface"
              >
                <div className="min-w-0">
                  <div className="mb-1 flex flex-wrap items-center gap-2.5">
                    <span className={`font-[family-name:var(--serif)] text-[1.05rem] font-medium tracking-[-0.035em] ${!journal.number ? 'text-muted-foreground' : ''}`}>
                      {journal.number || 'Draft'}
                    </span>
                    {journal.number && (
                      <span className={statusClass(journal.status)}>
                        {journal.status}
                      </span>
                    )}
                    {attachmentCount > 0 && (
                      <span className="inline-flex items-center gap-1 font-mono text-[0.58rem] uppercase tracking-[0.06em] text-muted-foreground">
                        <Paperclip className="h-3 w-3" />
                        {attachmentCount}
                      </span>
                    )}
                  </div>
                  <p className="text-[0.78rem] text-ink-soft">
                    {formatJournalText(journal.description, journal.entry_date)}
                  </p>
                </div>
                <div className="text-right text-[0.78rem]">
                  <p className="font-medium tabular-nums">
                    {formatDate(journal.entry_date)}
                  </p>
                  <p className="font-mono text-[0.58rem] uppercase tracking-[0.06em] text-muted-foreground">
                    {journalSourceLabel(journal.source)}
                  </p>
                </div>
              </Link>
            )
          })}
        </div>
      ) : filtersActive ? (
        <Card>
          <CardContent className="pt-6">
            <p className="text-ink-soft">No journals match these filters.</p>
          </CardContent>
        </Card>
      ) : (
        <EmptyState
          icon={<Plus className="h-8 w-8 text-coral" />}
          title="No journals"
          description="Every amount in the books starts here. Post an opening journal, or record spend."
          actions={canCreate ? [{ label: 'New journal', href: '/journals/new' }] : []}
        />
      )}
    </div>
  )
}
