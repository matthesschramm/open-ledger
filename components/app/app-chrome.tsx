'use client'

import type { ReactNode } from 'react'
import { usePathname } from 'next/navigation'

const SECTIONS: { prefix: string; label: string }[] = [
  { prefix: '/journals', label: 'Journals' },
  { prefix: '/accounts', label: 'Chart of accounts' },
  { prefix: '/bills', label: 'Bills' },
  { prefix: '/invoices', label: 'Invoices' },
  { prefix: '/fixed-assets', label: 'Fixed assets' },
  { prefix: '/cash', label: 'Cash' },
  { prefix: '/contacts', label: 'Contacts' },
  { prefix: '/reports', label: 'Reports' },
  { prefix: '/settings', label: 'Settings' },
]

function sectionLabel(pathname: string | null): string {
  if (!pathname || pathname === '/') {
    return 'Home'
  }
  return SECTIONS.find((section) => pathname === section.prefix || pathname.startsWith(`${section.prefix}/`))?.label ?? 'Books'
}

export function AppChrome({ children }: { children: ReactNode }) {
  const pathname = usePathname()

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="flex h-[66px] shrink-0 items-center border-b border-line bg-[#f6f5ef] px-8">
        <p className="font-mono text-[0.58rem] font-semibold uppercase tracking-[0.08em] text-muted-foreground">
          {sectionLabel(pathname)}
        </p>
      </header>
      <main className="flex-1 overflow-auto bg-card">{children}</main>
    </div>
  )
}
