import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { FileText, BarChart3, DollarSign, TrendingUp, Clock, Receipt, FileSpreadsheet, Landmark } from 'lucide-react'
import { EmptyState } from '@/components/app/empty-state'

const reports = [
  {
    name: 'Profit & Loss',
    description: 'Activity for a period',
    href: '/reports/profit-and-loss',
    icon: TrendingUp,
  },
  {
    name: 'Balance Sheet',
    description: 'Position as of a date',
    href: '/reports/balance-sheet',
    icon: FileText,
  },
  {
    name: 'Trial Balance',
    description: 'The accountant check',
    href: '/reports/trial-balance',
    icon: BarChart3,
  },
  {
    name: 'Cash Movement',
    description: 'Change in cash, by counter-account',
    href: '/reports/cash-movement',
    icon: DollarSign,
  },
  {
    name: 'AP Aging',
    description: 'Unpaid bills by age',
    href: '/reports/ap-aging',
    icon: Clock,
  },
  {
    name: 'AR Aging',
    description: 'Unpaid invoices by age',
    href: '/reports/ar-aging',
    icon: FileSpreadsheet,
  },
  {
    name: 'Account Ledger',
    description: 'Every posted line in one account',
    href: '/reports/account-ledger',
    icon: Receipt,
  },
  {
    name: 'PPE rollforward',
    description: 'IAS 16 carrying amount by class',
    href: '/reports/ppe-rollforward',
    icon: Landmark,
  },
]

export default function ReportsPage({
  searchParams,
}: {
  searchParams: Promise<{ empty?: string }>
}) {
  return <ReportsContent searchParams={searchParams} />
}

async function ReportsContent({
  searchParams,
}: {
  searchParams: Promise<{ empty?: string }>
}) {
  const params = await searchParams
  const showEmpty = params.empty === '1'
  
  if (showEmpty) {
    return (
      <div className="p-8">
        <div className="mb-8">
          <p className="page-kicker">Books</p>
          <h1 className="text-3xl font-semibold tracking-tight">Reports</h1>
          <p className="text-muted-foreground">Export and verify your books</p>
        </div>
        <EmptyState
          icon={<BarChart3 className="h-8 w-8 text-coral" />}
          title="Nothing to report yet"
          description="Post a journal, then this report can add up."
          actions={[
            { label: 'New journal', href: '/journals/new' },
          ]}
        />
      </div>
    )
  }
  return (
    <div className="p-8">
      <div className="mb-8">
        <p className="page-kicker">Books</p>
        <h1 className="text-3xl font-semibold tracking-tight">Reports</h1>
        <p className="text-muted-foreground">
          Export and verify your books
        </p>
      </div>

      <div className="hairline-grid md:grid-cols-2 lg:grid-cols-3">
        {reports.map((report, index) => {
          const Icon = report.icon
          return (
            <div key={report.name} className="hairline-cell">
              <div className="mb-8 flex items-start justify-between">
                <span className="font-mono text-[0.62rem] font-semibold tracking-[0.08em] text-coral">
                  {String(index + 1).padStart(2, '0')}
                </span>
                <Icon className="h-5 w-5 text-coral" />
              </div>
              <h2 className="text-[clamp(1.35rem,2.1vw,2rem)]">{report.name}</h2>
              <p className="mt-2 text-[0.78rem] text-ink-soft">{report.description}</p>
              <div className="mt-6">
                <Link href={report.href}>
                  <Button variant="outline">View Report</Button>
                </Link>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
