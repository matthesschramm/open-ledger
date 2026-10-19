'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'
import {
  Home,
  FileText,
  Users,
  CreditCard,
  Receipt,
  Wallet,
  BarChart3,
  Settings,
  FolderOpen,
  Landmark,
  LogOut,
} from 'lucide-react'
import { BrandMark } from '@/components/app/brand-mark'
import { CompanySwitcher } from '@/components/app/company-switcher'
import { signOut } from '@/lib/actions'

const navigation = [
  { name: 'Home', href: '/', icon: Home },
  { name: 'Journals', href: '/journals', icon: FileText },
  { name: 'Chart of accounts', href: '/accounts', icon: FolderOpen },
  { name: 'Bills', href: '/bills', icon: CreditCard },
  { name: 'Invoices', href: '/invoices', icon: Receipt },
  { name: 'Fixed assets', href: '/fixed-assets', icon: Landmark },
  { name: 'Cash', href: '/cash', icon: Wallet },
  { name: 'Contacts', href: '/contacts', icon: Users },
  { name: 'Reports', href: '/reports', icon: BarChart3 },
]

const footerNavigation = [
  { name: 'Settings', href: '/settings', icon: Settings },
]

function NavLink({
  href,
  name,
  icon: Icon,
  isActive,
}: {
  href: string
  name: string
  icon: typeof Home
  isActive: boolean
}) {
  return (
    <Link
      href={href}
      className={cn(
        'flex items-center gap-3 rounded-[7px] px-3 py-2 text-[0.78rem] font-medium transition-colors duration-150',
        isActive
          ? 'bg-primary text-primary-foreground'
          : 'text-ink-soft hover:bg-sidebar-accent hover:text-foreground'
      )}
    >
      <Icon className={cn('h-4 w-4', isActive ? 'text-primary-foreground' : 'text-coral')} />
      {name}
    </Link>
  )
}

type Company = {
  id: string
  name: string
  role: string
  isActive: boolean
}

type AppNavProps = {
  companies: Company[]
  currentCompany: Company | null
}

export function AppNav({ companies, currentCompany }: AppNavProps) {
  const pathname = usePathname()

  return (
    <nav className="flex h-full w-64 flex-col border-r border-sidebar-border bg-sidebar px-3 py-4">
      <div className="mb-8 flex items-start gap-2.5 px-3">
        <BrandMark />
        <div className="flex-1 min-w-0">
          <p className="font-sans text-[0.95rem] font-semibold tracking-[-0.02em]">
            Open Ledger
          </p>
        </div>
      </div>
      <div className="mb-4 px-3">
        <p className="mb-2 font-mono text-[0.58rem] font-semibold uppercase tracking-[0.08em] text-muted-foreground">
          Company
        </p>
        <CompanySwitcher companies={companies} currentCompany={currentCompany} />
      </div>
      <p className="mb-2 px-3 font-mono text-[0.58rem] font-semibold uppercase tracking-[0.08em] text-coral">
        Books
      </p>
      <div className="flex-1 space-y-1">
        {navigation.map((item) => (
          <NavLink
            key={item.name}
            href={item.href}
            name={item.name}
            icon={item.icon}
            isActive={pathname === item.href || Boolean(pathname?.startsWith(item.href + '/'))}
          />
        ))}
      </div>
      <div className="border-t border-sidebar-border pt-4 space-y-1">
        <p className="mb-2 px-3 font-mono text-[0.58rem] font-semibold uppercase tracking-[0.08em] text-muted-foreground">
          Account
        </p>
        {footerNavigation.map((item) => (
          <NavLink
            key={item.name}
            href={item.href}
            name={item.name}
            icon={item.icon}
            isActive={pathname === item.href || Boolean(pathname?.startsWith(item.href + '/'))}
          />
        ))}
        <form action={signOut}>
          <button
            type="submit"
            className="flex w-full items-center gap-3 rounded-[7px] px-3 py-2 text-[0.78rem] font-medium text-ink-soft transition-colors duration-150 hover:bg-sidebar-accent hover:text-foreground"
          >
            <LogOut className="h-4 w-4" />
            Sign out
          </button>
        </form>
      </div>
    </nav>
  )
}
