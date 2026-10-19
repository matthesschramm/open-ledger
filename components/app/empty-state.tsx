'use client'

import { Button } from '@/components/ui/button'
import Link from 'next/link'

interface EmptyStateProps {
  icon?: React.ReactNode
  title: string
  description?: string
  actions?: {
    label: string
    href?: string
    onClick?: () => void
    variant?: 'default' | 'outline'
  }[]
}

export function EmptyState({ icon, title, description, actions }: EmptyStateProps) {
  return (
    <div className="flex min-h-[400px] flex-col items-center justify-center p-8 text-center">
      {icon && (
        <div className="mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-coral-soft text-coral">
          {icon}
        </div>
      )}
      <h3 className="mb-2 font-heading text-[clamp(1.35rem,2.1vw,2rem)] font-medium tracking-[-0.035em]">
        {title}
      </h3>
      {description && <p className="mb-6 max-w-sm text-sm text-ink-soft">{description}</p>}
      {actions && actions.length > 0 && (
        <div className="flex gap-3">
          {actions.map((action, idx) =>
            action.href ? (
              <Link key={idx} href={action.href}>
                <Button variant={action.variant || 'default'}>{action.label}</Button>
              </Link>
            ) : (
              <Button
                key={idx}
                variant={action.variant || 'default'}
                onClick={action.onClick}
              >
                {action.label}
              </Button>
            )
          )}
        </div>
      )}
    </div>
  )
}
