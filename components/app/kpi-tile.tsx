import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

export function KpiTile({
  label,
  value,
  hint,
  className,
}: {
  label: string
  value: ReactNode
  hint?: ReactNode
  className?: string
}) {
  return (
    <div className={cn('kpi-tile', className)}>
      <p className="kpi-tile-label">{label}</p>
      <p className="kpi-tile-value">{value}</p>
      {hint ? <p className="kpi-tile-hint">{hint}</p> : null}
    </div>
  )
}
