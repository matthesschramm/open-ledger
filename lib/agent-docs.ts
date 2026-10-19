export function agentDocsMarkdown(origin: string): string {
  return `# Open Ledger API and MCP

Open Ledger is double-entry accounting. Agents keep the books through this API. Humans use the web app.

This page is public. No login required.

## How to find this page

- HTML: ${origin}/docs
- Markdown: ${origin}/docs.md
- Agent index: ${origin}/llms.txt
- Linked from the sign-in page at ${origin}/login

If you were given only a deployment URL and an API key, start here.

## Which interface to use

There are two doors into the same ledger. Same key, same permissions, same posting rules.

- **MCP** is for AI agents. Discover tools with \`tools/list\`, then call them by name. Prefer this if you speak MCP.
- **REST** is the HTTP API at \`${origin}/api/v1\`. Use this from curl, scripts, or any HTTP client.

Do not call both for the same job. If a Settings page and this page disagree, this page is the source of truth.

## Authentication

Every MCP and REST call except \`GET /api/v1/health\` needs:

\`\`\`
Authorization: Bearer sk_live_...
\`\`\`

The owner creates keys at Settings → API Keys. Keys are shown once.

Permission bits:

- \`read\` (default): list and get, plus invoice reminders (audit only)
- \`read_write\`: create drafts, contacts, accounts, bills, invoices, and change the capitalization threshold
- \`can_post\`: post and reverse journals, post bills and invoices, record receipts, credits, write-offs, mark bills paid, register and dispose fixed assets, run depreciation

A key with \`can_post\` also has write. Default new keys are read-only.

## MCP

Endpoint: \`${origin}/api/mcp\`

JSON-RPC 2.0 over HTTP POST.

\`\`\`json
{
  "mcpServers": {
    "open-ledger": {
      "url": "${origin}/api/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
\`\`\`

Methods: \`initialize\`, \`tools/list\`, \`tools/call\`.

### Read tools

- get_organization
- list_accounts, list_journals, get_journal
- list_contacts, list_customers, list_bills
- list_invoices, get_invoice
- get_profit_and_loss, get_balance_sheet, get_trial_balance
- get_cash_movement, get_ap_aging, get_ar_aging, get_account_ledger
- list_fixed_assets, get_fixed_asset, get_ppe_rollforward

### Write tools (read_write)

- draft_journal
- create_customer
- draft_invoice
- draft_bill
- create_account
- delete_account

### Post tools (can_post)

- post_journal, reverse_journal
- post_bill, pay_bill
- post_invoice, record_receipt, issue_credit_note, write_off_invoice
- send_invoice (email with PDF, does NOT post GL; accepts to_email, email, to, or recipient_email in body)
- send_invoice_reminder (email with PDF, does NOT post GL; accepts to_email, email, to, or recipient_email; only for posted invoices with open balance; tracked separately from send_invoice)
- register_fixed_asset, run_depreciation, dispose_fixed_asset

\`pay_bill\` records a payment that already happened outside Open Ledger (Airwallex, Ramp, bank). It does not send money.

\`delete_account\` refuses system accounts and any account with journal, bill, or invoice lines.

## REST

Base: \`${origin}/api/v1\`

### Read

- GET /health (no auth)
- GET /organization
- GET /fixed-assets, GET /fixed-assets/:id
- GET /reports/ppe-rollforward?start_date=&end_date=
- GET /accounts, GET /accounts/:id
- GET /journals, GET /journals/:id
- GET /contacts, GET /customers
- GET /bills, GET /invoices, GET /invoices/:id
- GET /reports/profit-and-loss?start_date=&end_date=
- GET /reports/balance-sheet?as_of_date=
- GET /reports/trial-balance?as_of_date=
- GET /reports/cash-movement?start_date=&end_date=
- GET /reports/ap-aging?as_of_date=
- GET /reports/ar-aging?as_of_date=
- GET /reports/account-ledger?account_id=&start_date=&end_date=

### Write (read_write)

- PATCH /organization (capitalization_threshold_cents)
- POST /accounts
- DELETE /accounts/:id
- POST /journals
- POST /contacts, POST /customers
- POST /bills
- POST /invoices

### Post (can_post)

- POST /journals/:id/post
- POST /journals/:id/reverse
- POST /bills/:id/post
- POST /bills/:id/pay
- POST /invoices/:id/post
- POST /invoices/:id/receipt
- POST /invoices/:id/credit
- POST /invoices/:id/write-off
- POST /invoices/:id/send (email PDF, does NOT post GL; body: to_email/email/to/recipient_email)
- POST /invoices/:id/reminder (audit log only, read is enough)
- POST /fixed-assets
- POST /fixed-assets/depreciation
- POST /fixed-assets/:id/dispose

POST bodies use integer cents. Optional header: \`Idempotency-Key\`.

## Accounting rules

Parent cash-in is equity, never revenue, never an invoice:

- Dr 1010 Operating cash / Cr 3100 Additional paid-in capital

Vendor bill:

- Recognize: Dr Expense / Cr 2000 AP (\`post_bill\`)
- Mark paid after Airwallex/Ramp/bank: Dr 2000 AP / Cr 1010 (\`pay_bill\`)

Customer invoice:

- Invoice: Dr 1100 AR / Cr Revenue (post_invoice)
- Send: email with PDF attachment (send_invoice — does NOT post GL; accepts to_email, email, to, or recipient_email)
- Receipt: Dr 1010 / Cr 1100
- Credit: Dr Revenue / Cr 1100
- Write-off: Dr 5110 Bad Debt / Cr 1100

Fixed assets live on a register, not as one GL account per laptop. Class accounts: 1500/1590 equipment, 1550/1591 furniture, 1560/1592 leasehold, 1700/1790 intangibles, 5120 depreciation, 5130 amortization, 6110 disposal gain or loss.

- Buy: \`register_fixed_asset\` with credit_account_id (cash or AP). Dr class / Cr cash or AP.
- Already on the books: pass existing_journal_id and, if a month is already depreciated, brought_forward_accum_dep_cents plus brought_forward_journal_id.
- Month close: \`run_depreciation\` with period_start in that month. Full-month convention from the in-service month. Same month will not charge twice.
- Dispose: \`dispose_fixed_asset\`. Takes the current month if needed, then Dr accum + Dr cash + Dr/Cr 6110 / Cr gross.
- Notes: \`get_ppe_rollforward\` is the IAS 16.73 table. Do not reconstruct it from journal memos.

Purchases below the organization capitalization threshold (default $1,000) must be expensed. SaaS subscriptions stay on 5030.

Only Customer contacts can be invoiced. Parent, Vendor, and Other are refused.

Quotes create no journal. Reminders write an audit row only. Send attaches the invoice PDF via email — sending does NOT create any journal entry. Payment instructions on PDFs come from organization settings.

Invoice numbers look like INV-2026-0001. Use the customer name, not a UUID, in examples you show a human.

Locked periods refuse posts and name the month.

Reports include Posted and Reversed journals. Drafts are excluded.

System accounts cannot be archived, retyped, or deleted.

## Examples

Create a customer, draft an invoice, post it (REST):

\`\`\`
curl -X POST -H "Authorization: Bearer YOUR_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"name":"Customer","email":"customer@example.com"}' \\
  ${origin}/api/v1/customers

curl -X POST -H "Authorization: Bearer YOUR_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"customer_id":"CUSTOMER_UUID","number":"INV-2026-0001","invoice_date":"2026-08-31","lines":[{"account_id":"REVENUE_UUID","amount_cents":100000,"description":"Services"}]}' \\
  ${origin}/api/v1/invoices

curl -X POST -H "Authorization: Bearer YOUR_API_KEY" \\
  ${origin}/api/v1/invoices/INVOICE_UUID/post
\`\`\`

Record an Airwallex bill payment (MCP):

\`\`\`json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "pay_bill",
    "arguments": {
      "bill_id": "BILL_UUID",
      "payment_date": "2026-08-31",
      "amount_cents": 25000,
      "cash_account_id": "CASH_UUID",
      "notes": "Airwallex payout po_xxx"
    }
  }
}
\`\`\`

## Not in the API

Period lock/unlock, user invite/roles, void bill, and CSV export stay in the web app. An agent with \`can_post\` still cannot post into a locked month.
`
}

export function llmsTxt(origin: string): string {
  return `# Open Ledger

> Double-entry accounting API for AI agents. Same books as the Open Ledger web app.

Documentation: ${origin}/docs
Markdown: ${origin}/docs.md
MCP: ${origin}/api/mcp
REST: ${origin}/api/v1
Health: ${origin}/api/v1/health

Auth: Authorization: Bearer sk_live_...

Agents should read ${origin}/docs.md first, then connect with MCP at ${origin}/api/mcp.
`
}

export async function getPublicOrigin(): Promise<string> {
  const { headers } = await import('next/headers')
  const headerStore = await headers()
  const host = headerStore.get('x-forwarded-host') || headerStore.get('host')
  if (!host) {
    return process.env.NEXT_PUBLIC_APP_URL || 'http://localhost:3000'
  }
  const proto = headerStore.get('x-forwarded-proto') || (host.includes('localhost') ? 'http' : 'https')
  return `${proto}://${host}`
}
