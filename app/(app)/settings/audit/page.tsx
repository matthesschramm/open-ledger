'use client'

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { formatInvoiceNumber } from '@/lib/format-invoice'
import { formatTimestamp as formatTs } from '@/lib/format-date'

type AuditEvent = {
  id: string
  entity_type: string
  entity_id: string
  action: string
  actor_id: string
  changes: any
  created_at: string
}

export default function AuditPage() {
  const router = useRouter()
  const supabase = createClient()
  const [auditEntries, setAuditEntries] = useState<AuditEvent[]>([])
  const [loading, setLoading] = useState(true)
  const [orgTimezone, setOrgTimezone] = useState<string>('UTC')

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    
    if (!user) {
      router.push('/login')
      return
    }

    const [{ data: orgData }, { data: auditData, error }] = await Promise.all([
      supabase.from('organizations').select('timezone').single(),
      supabase
        .from('audit_events')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(100)
    ])

    if (orgData?.timezone) {
      setOrgTimezone(orgData.timezone)
    }

    if (error) {
      console.error('Error loading audit events:', error)
      setLoading(false)
      return
    }

    if (auditData) {
      setAuditEntries(auditData)
    }

    setLoading(false)
  }

  function formatAction(action: string, changes: any): string {
    switch (action) {
      case 'period_opened':
        return `Opened period ${changes?.period_name || ''}`
      case 'period_soft_closed':
        return `Soft-closed period ${changes?.period_name || ''}`
      case 'period_locked':
        return `Locked period ${changes?.period_name || ''}`
      case 'period_reopened':
        return `Reopened period ${changes?.period_name || ''}`
      case 'journal_posted':
        if (changes?.source === 'bill') {
          return `Posted bill ${changes?.journal_number || ''}`
        } else if (changes?.source === 'reversal') {
          return `Reversed journal ${changes?.reverses_journal_number || ''}`
        }
        return `Posted journal ${changes?.journal_number || ''}`
      case 'journal_deleted':
        return `Deleted draft journal ${changes?.journal_number || ''}`
      case 'invoice_posted':
        return `Posted invoice ${changes?.invoice_number ? formatInvoiceNumber(changes.invoice_number, changes.invoice_date || '') : ''}`
      case 'receipt_recorded':
        return `Recorded receipt for invoice ${changes?.invoice_number ? formatInvoiceNumber(changes.invoice_number, changes.invoice_date || '') : ''}`
      case 'credit_note_issued':
        return `Issued credit note for invoice ${changes?.invoice_number ? formatInvoiceNumber(changes.invoice_number, changes.invoice_date || '') : ''}`
      case 'invoice_written_off':
        return `Wrote off invoice ${changes?.invoice_number ? formatInvoiceNumber(changes.invoice_number, changes.invoice_date || '') : ''}`
      case 'invoice_reminder_sent':
      case 'invoice_reminder':
        const reminderText = `Sent reminder for invoice ${changes?.invoice_number ? formatInvoiceNumber(changes.invoice_number, changes.invoice_date || '') : ''}`
        return changes?.to_email ? `${reminderText} to ${changes.to_email}` : reminderText
      case 'invoice_sent':
        return `Sent invoice ${changes?.invoice_number ? formatInvoiceNumber(changes.invoice_number, changes.invoice_date || '') : ''} to ${changes?.to_email || ''}`
      case 'member_invited':
        return `Invited ${changes?.email || 'user'} as ${formatRole(changes?.role)}`
      case 'member_role_changed':
        return `Changed ${changes?.email || 'user'} from ${formatRole(changes?.old_role)} to ${formatRole(changes?.new_role)}`
      case 'member_removed':
        return `Removed ${changes?.email || 'user'} (${formatRole(changes?.role)})`
      case 'asset_registered':
        return `Registered fixed asset ${changes?.number || ''}`
      case 'depreciation_run':
        return `Ran depreciation for ${changes?.period_start || ''}`
      case 'asset_disposed':
        return `Disposed fixed asset ${changes?.number || ''}`
      default:
        return action
    }
  }

  function formatRole(role: string | undefined): string {
    if (!role) return 'unknown'
    switch (role) {
      case 'owner': return 'Owner'
      case 'bookkeeper': return 'Bookkeeper'
      case 'read_only': return 'Read only'
      default: return role
    }
  }

  function getEntityLink(entry: AuditEvent): { href: string; label: string } | null {
    switch (entry.entity_type) {
      case 'accounting_period':
        return {
          href: '/settings/periods',
          label: 'Periods'
        }
      case 'journal':
        return {
          href: `/journals/${entry.entity_id}`,
          label: entry.changes?.journal_number || 'Journal'
        }
      case 'invoice':
        return {
          href: `/invoices/${entry.entity_id}`,
          label: entry.changes?.invoice_number ? formatInvoiceNumber(entry.changes.invoice_number, entry.changes.invoice_date || '') : 'Invoice'
        }
      case 'membership':
        return {
          href: '/settings/users',
          label: 'Users'
        }
      case 'fixed_asset':
        return {
          href: entry.action === 'depreciation_run' ? '/fixed-assets' : `/fixed-assets/${entry.entity_id}`,
          label: entry.changes?.number || 'Fixed asset'
        }
      default:
        return null
    }
  }

  function getReasonText(entry: AuditEvent): string | null {
    if (entry.action === 'period_reopened' && entry.changes?.reopen_reason) {
      return entry.changes.reopen_reason
    }
    return null
  }

  if (loading) {
    return (
      <div className="p-8">
        <p className="text-neutral-600">Loading...</p>
      </div>
    )
  }

  return (
    <div className="p-8">
      <div className="mb-8">
        <Link href="/settings">
          <Button variant="ghost" size="sm" className="mb-4">← Back to Settings</Button>
        </Link>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Audit Log</h1>
            <p className="text-muted-foreground">
              System activity and change history
            </p>
          </div>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Recent Activity</CardTitle>
          <CardDescription>Latest system events and changes</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>When</TableHead>
                <TableHead>Who</TableHead>
                <TableHead>What</TableHead>
                <TableHead>Link</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {auditEntries.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={4} className="h-24 text-center text-sm text-muted-foreground">
                    No audit events yet.
                  </TableCell>
                </TableRow>
              ) : (
                auditEntries.map((entry) => {
                  const entityLink = getEntityLink(entry)
                  const reasonText = getReasonText(entry)
                  const actionText = formatAction(entry.action, entry.changes)
                  
                  return (
                    <TableRow key={entry.id}>
                      <TableCell className="text-sm text-neutral-600">
                        {formatTs(entry.created_at, orgTimezone)}
                      </TableCell>
                      <TableCell className="text-sm">
                        {entry.changes?.actor_email || 'Unknown'}
                      </TableCell>
                      <TableCell className="text-sm">
                        {actionText}
                        {reasonText && (
                          <div className="text-xs text-muted-foreground mt-1">
                            Reason: {reasonText}
                          </div>
                        )}
                      </TableCell>
                      <TableCell className="text-sm">
                        {entityLink ? (
                          <Link 
                            href={entityLink.href}
                            className="text-blue-600 hover:underline"
                          >
                            {entityLink.label}
                          </Link>
                        ) : (
                          <span className="text-neutral-400">—</span>
                        )}
                      </TableCell>
                    </TableRow>
                  )
                })
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  )
}
