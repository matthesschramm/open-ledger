'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { createAPIKey } from '@/lib/actions'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Key, Trash2, Copy } from 'lucide-react'
import { toast } from 'sonner'
import { formatTimestampDate } from '@/lib/format-date'

interface APIKey {
  id: string
  name: string
  created_at: string
  last_used_at?: string
  expires_at?: string
  is_active: boolean
}

interface APIKeysPageClientProps {
  currentOrgId: string | null
  currentOrgName: string
}

export function APIKeysPageClient({ currentOrgId, currentOrgName }: APIKeysPageClientProps) {
  const [apiKeys, setApiKeys] = useState<APIKey[]>([])
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [keyName, setKeyName] = useState('')
  const [keyPermission, setKeyPermission] = useState<'read' | 'read_write' | 'can_post'>('read')
  const [creating, setCreating] = useState(false)
  const [newKeySecret, setNewKeySecret] = useState<string | null>(null)
  const [baseUrl, setBaseUrl] = useState<string>('')
  const [error, setError] = useState<string | null>(null)
  const [orgTimezone, setOrgTimezone] = useState<string>('UTC')
  const [revokeDialog, setRevokeDialog] = useState<{ open: boolean; keyId: string | null; keyName: string | null }>({
    open: false,
    keyId: null,
    keyName: null,
  })

  useEffect(() => {
    loadAPIKeys()
    loadCurrentRole()
    loadOrgTimezone()
    setBaseUrl(window.location.origin)
  }, [currentOrgId])

  async function loadOrgTimezone() {
    const supabase = createClient()
    const { data } = await supabase.from('organizations').select('timezone').single()
    if (data?.timezone) {
      setOrgTimezone(data.timezone)
    }
  }

  async function loadAPIKeys() {
    const supabase = createClient()
    const { data, error } = await supabase
      .from('api_keys')
      .select('id, name, created_at, last_used_at, expires_at, is_active')
      .order('created_at', { ascending: false })

    if (!error && data) {
      setApiKeys(data)
    }
    setLoading(false)
  }

  async function loadCurrentRole() {
    const supabase = createClient()
    const { data } = await supabase.rpc('current_role')
    if (data) {
      setCurrentRole(data)
    }
  }

  async function handleCreate(e?: React.MouseEvent) {
    if (e) {
      e.preventDefault()
      e.stopPropagation()
    }
    
    if (!keyName || creating) return
    
    setCreating(true)
    setError(null)
    
    try {
      const permissions = {
        can_read: true,
        can_write: keyPermission === 'read_write' || keyPermission === 'can_post',
        can_post: keyPermission === 'can_post',
      }
      const result = await createAPIKey(keyName, permissions)
      
      if (result.success) {
        setNewKeySecret(result.key)
        setKeyName('')
        setKeyPermission('read')
        await loadAPIKeys()
      } else {
        setError(result.error)
      }
    } catch (err) {
      console.error('Create API key error:', err)
      setError(err instanceof Error ? err.message : 'Failed to create API key')
    } finally {
      setCreating(false)
    }
  }

  async function handleRevoke(keyId: string) {
    const supabase = createClient()
    const { error } = await supabase
      .from('api_keys')
      .update({ is_active: false })
      .eq('id', keyId)
    
    if (!error) {
      loadAPIKeys()
      setRevokeDialog({ open: false, keyId: null, keyName: null })
      toast.success('API key revoked')
    } else {
      toast.error('Failed to revoke key')
    }
  }

  const canManageKeys = currentRole === 'owner'

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
        <h1 className="text-3xl font-semibold tracking-tight">API Keys</h1>
        <p className="text-muted-foreground">
          Manage API keys for programmatic access
          {currentOrgName && <span className="font-medium"> · {currentOrgName}</span>}
        </p>
      </div>

      {!canManageKeys && (
        <Card className="border-yellow-200 bg-yellow-50">
          <CardContent className="pt-6">
            <p className="text-sm text-yellow-800">
              Only owners can manage API keys.
            </p>
          </CardContent>
        </Card>
      )}

      {newKeySecret && (
        <Card className="border-green-200 bg-green-50">
          <CardHeader>
            <CardTitle className="text-green-900">API Key Created</CardTitle>
            <CardDescription className="text-green-700">
              Save this key now. You won't be able to see it again.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="flex items-center gap-4">
              <code className="flex-1 rounded bg-white px-4 py-3 text-sm font-mono border border-green-300 select-all">
                {newKeySecret}
              </code>
              <Button
                onClick={async () => {
                  try {
                    await navigator.clipboard.writeText(newKeySecret)
                    toast.success('Copied to clipboard')
                  } catch (err) {
                    console.error('Failed to copy:', err)
                    toast.error("Couldn't copy — select the key and copy manually")
                  }
                }}
              >
                Copy
              </Button>
              <Button
                variant="outline"
                onClick={() => setNewKeySecret(null)}
              >
                Done
              </Button>
            </div>
          </CardContent>
        </Card>
      )}

      {error && (
        <Card className="border-red-200 bg-red-50">
          <CardContent className="pt-6">
            <div className="flex items-start gap-3">
              <div className="flex-1">
                <p className="text-sm font-medium text-red-900">Failed to create API key</p>
                <p className="text-sm text-red-700 mt-1">{error}</p>
              </div>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setError(null)}
                className="text-red-700 hover:text-red-900"
              >
                Dismiss
              </Button>
            </div>
          </CardContent>
        </Card>
      )}

      {canManageKeys && (
        <Card>
          <CardHeader>
            <CardTitle>Create API Key</CardTitle>
            <CardDescription>
              Generate a new API key with selected permissions.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={(e) => { e.preventDefault(); handleCreate(); }} className="space-y-4">
              <div>
                <label className="block text-sm font-medium mb-2">Key Name</label>
                <input
                  type="text"
                  value={keyName}
                  onChange={(e) => setKeyName(e.target.value)}
                  placeholder="Key name (e.g., Production API)"
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm focus:border-neutral-500 focus:outline-none"
                  disabled={creating}
                />
              </div>
              <div>
                <label className="block text-sm font-medium mb-2">Permissions</label>
                <select
                  value={keyPermission}
                  onChange={(e) => setKeyPermission(e.target.value as 'read' | 'read_write' | 'can_post')}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm focus:border-neutral-500 focus:outline-none"
                  disabled={creating}
                >
                  <option value="read">Read Only - List and get operations (default)</option>
                  <option value="read_write">Read + Write - Create drafts (journals, invoices)</option>
                  <option value="can_post">Read + Write + Post - Post journals/invoices (affects GL)</option>
                </select>
                <p className="mt-2 text-xs text-neutral-600">
                  Default is read-only. Only grant <code className="bg-neutral-100 px-1 py-0.5 rounded">can_post</code> when necessary.
                </p>
              </div>
              <Button type="button" onClick={handleCreate} disabled={creating || !keyName} className="w-full">
                <Key className="h-4 w-4 mr-2" />
                {creating ? 'Creating...' : 'Create Key'}
              </Button>
            </form>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Active Keys</CardTitle>
          <CardDescription>{apiKeys.filter(k => k.is_active).length} active keys</CardDescription>
        </CardHeader>
        <CardContent>
          {apiKeys.length === 0 ? (
            <p className="text-sm text-neutral-600">No API keys yet</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>Last Used</TableHead>
                  <TableHead>Status</TableHead>
                  {canManageKeys && <TableHead className="text-right">Actions</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {apiKeys.map((key) => (
                  <TableRow key={key.id}>
                    <TableCell className="font-medium">{key.name}</TableCell>
                    <TableCell>
                      {formatTimestampDate(key.created_at, orgTimezone)}
                    </TableCell>
                    <TableCell>
                      {key.last_used_at
                        ? formatTimestampDate(key.last_used_at, orgTimezone)
                        : 'Never'}
                    </TableCell>
                    <TableCell>
                      <span
                        className={`inline-flex items-center rounded-full px-2 py-1 text-xs font-medium ${
                          key.is_active
                            ? 'bg-green-50 text-green-700'
                            : 'bg-neutral-100 text-neutral-600'
                        }`}
                      >
                        {key.is_active ? 'Active' : 'Revoked'}
                      </span>
                    </TableCell>
                    {canManageKeys && (
                      <TableCell className="text-right">
                        {key.is_active && (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => setRevokeDialog({ open: true, keyId: key.id, keyName: key.name })}
                          >
                            <Trash2 className="h-4 w-4" />
                          </Button>
                        )}
                      </TableCell>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <div className="border-t pt-8">
        <h2 className="text-2xl font-semibold tracking-tight mb-4">How agents connect</h2>
        
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>Public documentation</CardTitle>
              <CardDescription>Agents can read this without signing in</CardDescription>
            </CardHeader>
            <CardContent className="space-y-2 text-sm">
              <p>
                Give teammates the key plus this URL. Their agent does not need the repo.
              </p>
              <code className="block rounded bg-neutral-100 px-3 py-2 text-sm font-mono">
                {baseUrl || 'https://your-deployment.com'}/docs
              </code>
              <p className="text-xs text-neutral-600">
                Also published at{' '}
                <a href="/docs.md" className="underline">
                  /docs.md
                </a>{' '}
                and{' '}
                <a href="/llms.txt" className="underline">
                  /llms.txt
                </a>
                . Linked from the sign-in page.
              </p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Base URL</CardTitle>
              <CardDescription>Use your deployment URL for all API requests</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="flex items-center gap-2">
                <code className="flex-1 rounded bg-neutral-100 px-3 py-2 text-sm font-mono select-all">
                  {baseUrl || process.env.NEXT_PUBLIC_APP_URL || 'https://your-deployment.com'}
                </code>
                {baseUrl && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={async () => {
                      try {
                        await navigator.clipboard.writeText(baseUrl)
                        toast.success('Copied to clipboard')
                      } catch (err) {
                        console.error('Failed to copy:', err)
                        toast.error("Couldn't copy — select the URL and copy manually")
                      }
                    }}
                  >
                    <Copy className="h-4 w-4" />
                  </Button>
                )}
              </div>
              <p className="mt-2 text-xs text-neutral-600">
                Never hardcode internal URLs. Use this deployment's base URL.
              </p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Authentication</CardTitle>
              <CardDescription>Include your API key in the Authorization header</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div>
                <code className="block rounded bg-neutral-100 px-3 py-2 text-sm font-mono">
                  Authorization: Bearer sk_live_...
                </code>
              </div>
              
              <div>
                <p className="text-sm font-medium mb-2">Permission Scopes</p>
                <ul className="space-y-2 text-sm text-neutral-600">
                  <li><code className="text-xs bg-neutral-100 px-1.5 py-0.5 rounded">read</code> - List and get operations (default: true)</li>
                  <li><code className="text-xs bg-neutral-100 px-1.5 py-0.5 rounded">read_write</code> - Create drafts, contacts, accounts, bills, invoices (default: false)</li>
                  <li><code className="text-xs bg-neutral-100 px-1.5 py-0.5 rounded">can_post</code> - Post/reverse journals, post bills, mark bills paid, post invoices (default: false)</li>
                </ul>
                <p className="mt-2 text-xs text-neutral-600">
                  <strong>Default:</strong> New keys are draft-only and cannot post transactions until explicitly granted can_post permission by owner.
                </p>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Example: Create Invoice via REST API</CardTitle>
              <CardDescription>Use INV-2026-0001 format and Customer (not UUIDs or Acme)</CardDescription>
            </CardHeader>
            <CardContent>
              <pre className="rounded bg-neutral-900 text-neutral-100 px-4 py-3 text-xs overflow-x-auto">
{`# Create customer (requires read_write)
curl -X POST -H "Authorization: Bearer YOUR_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"name":"Customer","email":"customer@example.com"}' \\
  "${baseUrl || 'https://your-deployment.com'}/api/v1/customers

# Create draft invoice (requires read_write)
curl -X POST -H "Authorization: Bearer YOUR_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{
    "customer_id":"CUSTOMER_UUID",
    "number":"INV-2026-0001",
    "invoice_date":"2026-08-30",
    "lines":[{"account_id":"REVENUE_UUID","amount_cents":100000,"description":"Services"}]
  }' \\
  "${baseUrl || 'https://your-deployment.com'}/api/v1/invoices

# Post invoice (requires can_post) - Dr 1100 / Cr Revenue
curl -X POST -H "Authorization: Bearer YOUR_API_KEY" \\
  "${baseUrl || 'https://your-deployment.com'}/api/v1/invoices/INVOICE_UUID/post"`}
              </pre>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>MCP Server Configuration</CardTitle>
              <CardDescription>Connect AI agents via Model Context Protocol</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div>
                <p className="text-sm mb-2">MCP endpoint:</p>
                <code className="block rounded bg-neutral-100 px-3 py-2 text-sm font-mono">
                  {baseUrl || 'https://your-deployment.com'}/api/mcp
                </code>
              </div>
              
              <div>
                <p className="text-sm mb-2">Configuration snippet:</p>
                <pre className="rounded bg-neutral-900 text-neutral-100 px-4 py-3 text-xs overflow-x-auto">
{`{
  "mcpServers": {
    "open-ledger": {
      "url": "${baseUrl || 'https://your-deployment.com'}/api/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}`}
                </pre>
              </div>

              <div>
                <p className="text-sm font-medium mb-2">Available MCP Tools</p>
                <div className="text-xs text-neutral-600 space-y-1">
                  <p><strong>Read operations (all keys):</strong></p>
                  <ul className="list-disc list-inside ml-4 space-y-0.5">
                    <li>get_organization, list_accounts, list_journals, get_journal</li>
                    <li><strong>list_customers</strong>, <strong>list_invoices</strong>, <strong>get_invoice</strong></li>
                    <li><strong>send_invoice_reminder</strong> (audit log only, no email, no Pay now)</li>
                    <li>Reports: profit_and_loss, balance_sheet, trial_balance, cash_movement, ap_aging, <strong>ar_aging</strong>, account_ledger, <strong>ppe_rollforward</strong></li>
                    <li><strong>list_fixed_assets</strong>, <strong>get_fixed_asset</strong></li>
                  </ul>
                  <p className="mt-2"><strong>Write operations (read_write):</strong></p>
                  <ul className="list-disc list-inside ml-4 space-y-0.5">
                    <li>draft_journal, create_customer, draft_invoice, draft_bill</li>
                    <li>create_account, delete_account (unused accounts only; system accounts refused)</li>
                    <li>Invoice examples use INV-2026-0001 and Customer (not UUIDs, not Acme)</li>
                  </ul>
                  <p className="mt-2"><strong>Post operations (can_post):</strong></p>
                  <ul className="list-disc list-inside ml-4 space-y-0.5">
                    <li>post_journal, reverse_journal, post_bill, pay_bill</li>
                    <li>post_invoice, record_receipt, issue_credit_note, write_off_invoice</li>
                    <li>register_fixed_asset, run_depreciation, dispose_fixed_asset</li>
                    <li>pay_bill records a payment already made in Airwallex, Ramp, or a bank. It does not send money.</li>
                  </ul>
                </div>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>REST API Endpoints</CardTitle>
              <CardDescription>Complete endpoint reference</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="text-xs space-y-3">
                <div>
                  <p className="font-medium mb-1">Core Resources</p>
                  <ul className="list-disc list-inside ml-4 space-y-0.5 text-neutral-600">
                    <li>GET /api/v1/organization, PATCH /api/v1/organization (capitalization threshold)</li>
                    <li>GET /api/v1/fixed-assets, GET /api/v1/fixed-assets/:id</li>
                    <li>POST /api/v1/fixed-assets, POST /api/v1/fixed-assets/depreciation, POST /api/v1/fixed-assets/:id/dispose</li>
                    <li>GET /api/v1/accounts, GET /api/v1/accounts/:id</li>
                    <li>POST /api/v1/accounts, DELETE /api/v1/accounts/:id (requires read_write)</li>
                    <li>GET /api/v1/journals, GET /api/v1/journals/:id</li>
                    <li>POST /api/v1/journals (requires read_write)</li>
                    <li>POST /api/v1/journals/:id/post (requires can_post)</li>
                    <li>POST /api/v1/journals/:id/reverse (requires can_post)</li>
                    <li>GET /api/v1/contacts, POST /api/v1/contacts (requires read_write)</li>
                    <li>GET /api/v1/customers, POST /api/v1/customers (requires read_write)</li>
                    <li>GET /api/v1/bills, POST /api/v1/bills (requires read_write)</li>
                    <li>POST /api/v1/bills/:id/post (requires can_post)</li>
                    <li>POST /api/v1/bills/:id/pay (requires can_post; records an external payment)</li>
                    <li>GET /api/v1/invoices, GET /api/v1/invoices/:id, POST /api/v1/invoices (requires read_write)</li>
                    <li>POST /api/v1/invoices/:id/post (requires can_post)</li>
                    <li>POST /api/v1/invoices/:id/receipt (requires can_post)</li>
                    <li>POST /api/v1/invoices/:id/credit (requires can_post)</li>
                    <li>POST /api/v1/invoices/:id/write-off (requires can_post)</li>
                    <li>POST /api/v1/invoices/:id/reminder (requires read, audit log only)</li>
                  </ul>
                </div>
                <div>
                  <p className="font-medium mb-1">Reports (all require read)</p>
                  <ul className="list-disc list-inside ml-4 space-y-0.5 text-neutral-600">
                    <li>GET /api/v1/reports/profit-and-loss</li>
                    <li>GET /api/v1/reports/balance-sheet</li>
                    <li>GET /api/v1/reports/trial-balance</li>
                    <li>GET /api/v1/reports/cash-movement</li>
                    <li>GET /api/v1/reports/ap-aging</li>
                    <li>GET /api/v1/reports/ar-aging</li>
                    <li>GET /api/v1/reports/account-ledger</li>
                    <li>GET /api/v1/reports/ppe-rollforward</li>
                  </ul>
                </div>
                <p className="text-neutral-600 mt-3">
                  Full documentation (public, no login):{' '}
                  <a href="/docs" className="underline">
                    /docs
                  </a>
                </p>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Accounting Rules (AR Posting)</CardTitle>
              <CardDescription>Standard journal entries for invoices, receipts, credits, write-offs</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="text-sm space-y-3">
                <div className="bg-blue-50 border border-blue-200 rounded px-3 py-2">
                  <p className="font-medium mb-1 text-blue-900">Invoice: Dr 1100 / Cr Revenue</p>
                  <code className="block text-xs bg-white px-2 py-1 rounded mt-1">
                    Dr 1100 Accounts Receivable / Cr Revenue (4xxx)
                  </code>
                  <p className="text-xs text-blue-800 mt-1">
                    Use <strong>draft_invoice</strong> then <strong>post_invoice</strong>. Only Customer contacts can be invoiced.
                  </p>
                </div>
                <div className="bg-blue-50 border border-blue-200 rounded px-3 py-2">
                  <p className="font-medium mb-1 text-blue-900">Receipt: Dr 1010 / Cr 1100</p>
                  <code className="block text-xs bg-white px-2 py-1 rounded mt-1">
                    Dr 1010 Operating Cash / Cr 1100 Accounts Receivable
                  </code>
                  <p className="text-xs text-blue-800 mt-1">
                    Use <strong>record_receipt</strong> against a posted invoice.
                  </p>
                </div>
                <div className="bg-blue-50 border border-blue-200 rounded px-3 py-2">
                  <p className="font-medium mb-1 text-blue-900">Credit: Dr Revenue / Cr 1100</p>
                  <code className="block text-xs bg-white px-2 py-1 rounded mt-1">
                    Dr Revenue (4xxx) / Cr 1100 Accounts Receivable
                  </code>
                  <p className="text-xs text-blue-800 mt-1">
                    Use <strong>issue_credit_note</strong> to reverse recognized revenue.
                  </p>
                </div>
                <div className="bg-blue-50 border border-blue-200 rounded px-3 py-2">
                  <p className="font-medium mb-1 text-blue-900">Write-off: Dr 5110 / Cr 1100</p>
                  <code className="block text-xs bg-white px-2 py-1 rounded mt-1">
                    Dr 5110 Bad Debt Expense / Cr 1100 Accounts Receivable
                  </code>
                  <p className="text-xs text-blue-800 mt-1">
                    Use <strong>write_off_invoice</strong> for uncollectible invoices.
                  </p>
                </div>
                <div className="bg-blue-50 border border-blue-200 rounded px-3 py-2">
                  <p className="font-medium mb-1 text-blue-900">Bill payment: Dr 2000 / Cr 1010</p>
                  <code className="block text-xs bg-white px-2 py-1 rounded mt-1">
                    Dr 2000 Accounts Payable / Cr 1010 Operating Cash
                  </code>
                  <p className="text-xs text-blue-800 mt-1">
                    Use <strong>pay_bill</strong> after the money already left via Airwallex, Ramp, or a bank. Open Ledger does not send the payment.
                  </p>
                </div>
                <div className="bg-yellow-50 border border-yellow-300 rounded px-3 py-2">
                  <p className="font-medium mb-1 text-yellow-900">Parent cash-in: Dr 1010 / Cr 3100 (never an invoice)</p>
                  <code className="block text-xs bg-white px-2 py-1 rounded mt-1">
                    Dr 1010 Operating Cash / Cr 3100 Additional Paid-In Capital
                  </code>
                  <p className="text-xs text-yellow-800 mt-1">
                    Never book as revenue or invoice parent. This is proper equity capitalization (APIC). Use <strong>draft_journal</strong>, never an invoice.
                  </p>
                </div>
                <div>
                  <p className="font-medium mb-1">Reminder: Audit Log only (no email, no Pay now)</p>
                  <p className="text-xs text-neutral-600 mt-1">
                    Use <strong>send_invoice_reminder</strong> to log an audit event. No email is sent. No journal entry. No Pay now button.
                  </p>
                </div>
                <div>
                  <p className="font-medium mb-1">Locked-month refuse</p>
                  <p className="text-xs text-neutral-600 mt-1">
                    If you try to post to a locked month, the error will name the month: <em>"Cannot post invoice with date Aug 20, 2026: August 2026 is Locked. No one can post to a locked month. Reopen the period in Settings → Periods first."</em>
                  </p>
                </div>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>API Key Security</CardTitle>
            </CardHeader>
            <CardContent>
              <ul className="list-disc list-inside space-y-1 text-sm text-neutral-600">
                <li>Keys are shown once after creation. Save them securely.</li>
                <li>Never commit API keys to git or share them publicly.</li>
                <li>Use environment variables or secrets managers in production.</li>
                <li>Revoke keys immediately if compromised.</li>
                <li>Grant can_post permission only when necessary - posting affects the general ledger.</li>
                <li>Monitor key usage via audit logs at /settings/audit</li>
              </ul>
            </CardContent>
          </Card>
        </div>
      </div>

      <Dialog open={revokeDialog.open} onOpenChange={(open) => setRevokeDialog({ open, keyId: null, keyName: null })}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Revoke {revokeDialog.keyName}?</DialogTitle>
            <DialogDescription>
              Anything using this key will stop working right away. You can't undo this.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setRevokeDialog({ open: false, keyId: null, keyName: null })}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={() => {
                if (revokeDialog.keyId) {
                  handleRevoke(revokeDialog.keyId)
                }
              }}
            >
              Revoke key
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
