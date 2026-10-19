import type { ReactNode } from 'react'
import { BrandMark } from '@/components/app/brand-mark'

export function AuthShell({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-background px-4 py-10">
      {children}
    </div>
  )
}

export function AuthBrand() {
  return (
    <div className="flex items-center gap-2.5">
      <BrandMark />
      <p className="page-kicker mb-0">Books</p>
    </div>
  )
}
