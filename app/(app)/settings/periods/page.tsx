'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { Lock, Unlock, LockKeyhole } from 'lucide-react'
import { formatDate } from '@/lib/fiscal-year'

type PeriodStatus = 'Open' | 'Soft-closed' | 'Locked'

interface AccountingPeriod {
  id: string
  name: string
  start_date: string
  end_date: string
  status: PeriodStatus
  is_locked: boolean
  locked_at?: string
  locked_by?: string
  reopen_reason?: string
  reopened_at?: string
}

interface FiscalYearMonth {
  year: number
  month: number
  name: string
  period?: AccountingPeriod
}

export default function PeriodsPage() {
  const router = useRouter()
  const supabase = createClient()
  const [periods, setPeriods] = useState<AccountingPeriod[]>([])
  const [fiscalYearMonths, setFiscalYearMonths] = useState<FiscalYearMonth[]>([])
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [reopenDialogOpen, setReopenDialogOpen] = useState(false)
  const [softCloseDialogOpen, setSoftCloseDialogOpen] = useState(false)
  const [lockDialogOpen, setLockDialogOpen] = useState(false)
  const [selectedPeriod, setSelectedPeriod] = useState<AccountingPeriod | null>(null)
  const [reopenReason, setReopenReason] = useState('')
  const [fiscalYearEnd, setFiscalYearEnd] = useState<{ month: number; day: number } | null>(null)
  const [hasPostedJournals, setHasPostedJournals] = useState(false)

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    // Check authentication first
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    await Promise.all([loadPeriods(), loadCurrentRole(), loadFiscalYear()])
  }

  async function loadFiscalYear() {
    const { data } = await supabase
      .from('organizations')
      .select('fiscal_year_end_month, fiscal_year_end_day')
      .single()
    
    if (data) {
      setFiscalYearEnd({
        month: data.fiscal_year_end_month,
        day: data.fiscal_year_end_day
      })
    }
  }

  async function loadPeriods() {
    const { data, error } = await supabase
      .from('accounting_periods')
      .select('*')
      .order('start_date', { ascending: false })

    if (!error && data) {
      setPeriods(data)
    }
    
    // Check if there are any posted journals
    const { count } = await supabase
      .from('journals')
      .select('*', { count: 'exact', head: true })
      .neq('status', 'Draft')
    
    setHasPostedJournals((count || 0) > 0)
    setLoading(false)
  }

  async function loadCurrentRole() {
    const { data } = await supabase.rpc('current_role')
    if (data) {
      setCurrentRole(data)
    }
  }

  useEffect(() => {
    if (fiscalYearEnd && periods) {
      const months = calculateFiscalYearMonths(fiscalYearEnd.month, fiscalYearEnd.day, periods)
      setFiscalYearMonths(months)
    }
  }, [fiscalYearEnd, periods])

  function calculateFiscalYearMonths(
    fyEndMonth: number,
    fyEndDay: number,
    existingPeriods: AccountingPeriod[]
  ): FiscalYearMonth[] {
    const now = new Date()
    const currentYear = now.getFullYear()
    
    // Start month is month after FY end
    const fyStartMonth = (fyEndMonth % 12) + 1
    
    // Determine fiscal year based on current date
    const currentMonth = now.getMonth() + 1
    const isBeforeFYE = currentMonth < fyEndMonth || (currentMonth === fyEndMonth && now.getDate() <= fyEndDay)
    
    // If FY ends in Dec, FY 2026 is Jan-Dec 2026
    // If FY ends in Jun, FY 2026 is Jul 2025-Jun 2026
    let fyYear = currentYear
    if (fyStartMonth > fyEndMonth && isBeforeFYE) {
      fyYear = currentYear - 1
    }
    
    const months: FiscalYearMonth[] = []
    
    for (let i = 0; i < 12; i++) {
      const monthNum = ((fyStartMonth - 1 + i) % 12) + 1
      const year = monthNum < fyStartMonth ? fyYear + 1 : fyYear
      
      const monthNames = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
      ]
      const monthName = `${monthNames[monthNum - 1]} ${year}`
      
      // Find matching period by start_date
      const startDate = `${year}-${String(monthNum).padStart(2, '0')}-01`
      const period = existingPeriods.find(p => p.start_date === startDate)
      
      months.push({
        year,
        month: monthNum,
        name: monthName,
        period
      })
    }
    
    return months
  }

  async function handleOpenPeriod(year?: number, month?: number) {
    let targetYear = year
    let targetMonth = month
    
    if (!targetYear || !targetMonth) {
      const now = new Date()
      targetYear = now.getFullYear()
      targetMonth = now.getMonth() + 1
    }
    
    const { data, error } = await supabase.rpc('open_period', {
      p_year: targetYear,
      p_month: targetMonth
    })
    
    if (error) {
      alert(`Error: ${error.message}`)
    } else if (data && !data.success) {
      alert(`Error: ${data.error}`)
    } else {
      await loadPeriods()
    }
  }

  async function handleSoftClose(periodId: string) {
    const period = periods.find(p => p.id === periodId)
    if (!period) return
    setSelectedPeriod(period)
    setSoftCloseDialogOpen(true)
  }

  async function confirmSoftClose() {
    if (!selectedPeriod) return
    
    const { data, error } = await supabase.rpc('soft_close_period', { p_period_id: selectedPeriod.id })
    
    if (error) {
      alert(`Error: ${error.message}`)
    } else if (data && !data.success) {
      alert(`Error: ${data.error}`)
    } else {
      await loadPeriods()
      router.refresh()
    }
    setSoftCloseDialogOpen(false)
    setSelectedPeriod(null)
  }

  async function handleLock(periodId: string) {
    const period = periods.find(p => p.id === periodId)
    if (!period) return
    setSelectedPeriod(period)
    setLockDialogOpen(true)
  }

  async function confirmLock() {
    if (!selectedPeriod) return
    
    const { data, error } = await supabase.rpc('lock_period', { p_period_id: selectedPeriod.id })
    
    if (error) {
      alert(`Error: ${error.message}`)
    } else if (data && !data.success) {
      alert(`Error: ${data.error}`)
    } else {
      await loadPeriods()
      router.refresh()
    }
    setLockDialogOpen(false)
    setSelectedPeriod(null)
  }

  function openReopenDialog(period: AccountingPeriod) {
    setSelectedPeriod(period)
    setReopenReason('')
    setReopenDialogOpen(true)
  }

  async function handleReopen() {
    if (!selectedPeriod) return
    if (!reopenReason.trim()) {
      alert('Please provide a reason for reopening')
      return
    }
    
    const { data, error } = await supabase.rpc('reopen_period', {
      p_period_id: selectedPeriod.id,
      p_reason: reopenReason
    })
    
    if (error) {
      alert(`Error: ${error.message}`)
    } else if (data && !data.success) {
      alert(`Error: ${data.error}`)
    } else {
      setReopenDialogOpen(false)
      setSelectedPeriod(null)
      setReopenReason('')
      loadPeriods()
    }
  }

  const isOwner = currentRole === 'owner'
  const isReadOnly = currentRole === 'read_only'

  function getCurrentMonthName() {
    const now = new Date()
    return now.toLocaleString('en-US', { month: 'long', year: 'numeric' })
  }

  function getStatusBadge(status: PeriodStatus) {
    switch (status) {
      case 'Open':
        return (
          <span className="inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-medium bg-green-50 text-green-700">
            <Unlock className="h-3 w-3" />
            Open
          </span>
        )
      case 'Soft-closed':
        return (
          <span className="inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-medium bg-yellow-50 text-yellow-700">
            <LockKeyhole className="h-3 w-3" />
            Soft-closed
          </span>
        )
      case 'Locked':
        return (
          <span className="inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-medium bg-red-50 text-red-700">
            <Lock className="h-3 w-3" />
            Locked
          </span>
        )
    }
  }

  if (loading) {
    return (
      <div className="p-8">
        <p className="text-neutral-600">Loading...</p>
      </div>
    )
  }

  return (
    <div className="p-8 space-y-8">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight">Accounting Periods</h1>
        <p className="text-muted-foreground">Manage monthly close controls</p>
      </div>

      {isReadOnly && (
        <Card className="border-yellow-200 bg-yellow-50">
          <CardContent className="pt-6">
            <p className="text-sm text-yellow-800">
              Only the owner can lock or reopen a month.
            </p>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Periods</CardTitle>
          <CardDescription>
            {periods.length === 0
              ? 'Fiscal year by month'
              : `Fiscal year by month`}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {periods.length === 0 ? (
            <div className="space-y-4">
              <p className="text-sm text-neutral-600">
                {hasPostedJournals 
                  ? 'Fiscal year by month. Open the first period to enable close controls.'
                  : 'No months open yet.'}
              </p>
              {isOwner && (
                <Button onClick={() => handleOpenPeriod()}>
                  Open {getCurrentMonthName()}
                </Button>
              )}
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Period</TableHead>
                  <TableHead>Start Date</TableHead>
                  <TableHead>End Date</TableHead>
                  <TableHead>Status</TableHead>
                  {isOwner && <TableHead className="text-right">Actions</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {fiscalYearMonths.map((fyMonth) => (
                  <TableRow key={`${fyMonth.year}-${fyMonth.month}`}>
                    <TableCell className="font-medium">{fyMonth.name}</TableCell>
                    {fyMonth.period ? (
                      <>
                        <TableCell>
                          {formatDate(fyMonth.period.start_date)}
                        </TableCell>
                        <TableCell>
                          {formatDate(fyMonth.period.end_date)}
                        </TableCell>
                        <TableCell>{getStatusBadge(fyMonth.period.status)}</TableCell>
                        {isOwner && (
                          <TableCell className="text-right">
                            <div className="flex justify-end gap-2">
                              {fyMonth.period.status === 'Open' && (
                                <>
                                  <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => handleSoftClose(fyMonth.period!.id)}
                                  >
                                    <LockKeyhole className="h-4 w-4 mr-2" />
                                    Soft-close
                                  </Button>
                                  <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => handleLock(fyMonth.period!.id)}
                                  >
                                    <Lock className="h-4 w-4 mr-2" />
                                    Lock
                                  </Button>
                                </>
                              )}
                              {fyMonth.period.status === 'Soft-closed' && (
                                <>
                                  <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => handleLock(fyMonth.period!.id)}
                                  >
                                    <Lock className="h-4 w-4 mr-2" />
                                    Lock
                                  </Button>
                                  <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => openReopenDialog(fyMonth.period!)}
                                  >
                                    <Unlock className="h-4 w-4 mr-2" />
                                    Reopen
                                  </Button>
                                </>
                              )}
                              {fyMonth.period.status === 'Locked' && (
                                <Button
                                  variant="outline"
                                  size="sm"
                                  onClick={() => openReopenDialog(fyMonth.period!)}
                                >
                                  <Unlock className="h-4 w-4 mr-2" />
                                  Reopen
                                </Button>
                              )}
                            </div>
                          </TableCell>
                        )}
                      </>
                    ) : (
                      <>
                        <TableCell className="text-neutral-400">—</TableCell>
                        <TableCell className="text-neutral-400">—</TableCell>
                        <TableCell>
                          <span className="text-sm text-neutral-500">Not opened</span>
                        </TableCell>
                        {isOwner && (
                          <TableCell className="text-right">
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => handleOpenPeriod(fyMonth.year, fyMonth.month)}
                            >
                              Open {fyMonth.name}
                            </Button>
                          </TableCell>
                        )}
                      </>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <div className="text-sm text-neutral-600 space-y-2">
        <p><strong>Close Controls:</strong></p>
        <ul className="list-disc list-inside space-y-1 ml-4">
          <li><strong>Open:</strong> Owners and bookkeepers can post or reverse journals</li>
          <li><strong>Soft-closed:</strong> Only owners can post; bookkeepers are blocked</li>
          <li><strong>Locked:</strong> No one can post or reverse journals (not even owner)</li>
          <li>Close months in order; reopen in reverse order</li>
          <li>Reopening requires a reason for audit trail</li>
        </ul>
      </div>

      <Dialog open={reopenDialogOpen} onOpenChange={setReopenDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Reopen {selectedPeriod?.name}</DialogTitle>
            <DialogDescription>
              Provide a reason for reopening this period. This will be recorded in the audit trail.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="reason">Reason</Label>
              <Textarea
                id="reason"
                placeholder="e.g., Correct accounting error in depreciation entry"
                value={reopenReason}
                onChange={(e) => setReopenReason(e.target.value)}
                rows={3}
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => {
                setReopenDialogOpen(false)
                setSelectedPeriod(null)
                setReopenReason('')
              }}
            >
              Cancel
            </Button>
            <Button onClick={handleReopen}>Reopen Month</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Soft Close Confirm Dialog */}
      <Dialog open={softCloseDialogOpen} onOpenChange={setSoftCloseDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Soft close {selectedPeriod?.name}?</DialogTitle>
            <DialogDescription>
              Only owners will be able to post journals in this month.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setSoftCloseDialogOpen(false)}>
              Cancel
            </Button>
            <Button onClick={confirmSoftClose}>
              Soft close period
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Lock Confirm Dialog */}
      <Dialog open={lockDialogOpen} onOpenChange={setLockDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Lock {selectedPeriod?.name}?</DialogTitle>
            <DialogDescription>
              No journals can be posted or reversed in locked periods.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setLockDialogOpen(false)}>
              Cancel
            </Button>
            <Button onClick={confirmLock}>
              Lock period
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
