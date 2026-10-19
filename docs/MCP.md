# Open Ledger MCP Server

Open Ledger implements the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) to provide structured access to accounting data and operations for AI agents.

## Authentication

The MCP server uses the same API key authentication as the REST API. Pass your API key via the `Authorization` header:

```
Authorization: Bearer sk_live_...
```

## Connection

```json
{
  "mcpServers": {
    "open-ledger": {
      "url": "https://your-domain.com/api/mcp",
      "headers": {
        "Authorization": "Bearer sk_live_..."
      }
    }
  }
}
```

## Available Tools

### Organization

#### get_organization
Get organization details including currency, timezone, and fiscal year settings.

### Chart of Accounts

#### list_accounts
List chart of accounts entries.

Parameters:
- `type` (optional) - Filter by account type: Asset, Liability, Equity, Revenue, Expense
- `is_active` (optional) - Filter by active status

#### create_account
Create a new chart of accounts entry (requires `read_write` permission).

Parameters:
- `code` - Account number (e.g., "5100")
- `name` - Account name
- `type` - Asset, Liability, Equity, Revenue, or Expense
- `category` (optional) - Cash, AR, AP, Equity, Revenue, COGS, Expense, Other
- `is_cash` (optional) - True for bank/cash accounts (Asset only)
- `parent_id` (optional) - Parent account UUID

#### delete_account
Delete an unused account (requires `read_write` permission).

Parameters:
- `account_id` - Account UUID

### Journals

#### list_journals
List journal entries.

Parameters:
- `status` (optional) - Filter by status: Draft, Posted, Reversed
- `limit` (optional) - Limit number of results

#### get_journal
Get a specific journal entry with lines.

Parameters:
- `journal_id` - Journal UUID

#### draft_journal
Create a draft journal entry (requires `read_write` permission).

Parameters:
- `number` - Journal number (e.g., "JE-2026-0001")
- `entry_date` - Entry date (YYYY-MM-DD)
- `description` - Journal description
- `lines` - Array of journal lines:
  - `account_id` - Account UUID
  - `debit_cents` - Debit amount in cents
  - `credit_cents` - Credit amount in cents
  - `memo` (optional) - Line memo

#### post_journal
Post a draft journal entry (requires `can_post` permission).

Parameters:
- `journal_id` - Journal UUID

#### reverse_journal
Reverse a posted journal entry (requires `can_post` permission).

Parameters:
- `journal_id` - Posted journal UUID
- `reversal_date` - Reversal date (YYYY-MM-DD)
- `reversal_description` (optional) - Reversal memo

#### delete_journal
Delete a draft journal (requires `read_write` permission).

Only draft journals can be deleted. Posted and reversed journals cannot be deleted. Drafts never appeared on reports or the general ledger, so deletion does not affect GL balances.

Parameters:
- `journal_id` - Draft journal UUID

Returns:
```json
{
  "success": true,
  "journal_number": "JE-2026-0001"
}
```

### Journal Supporting Documents

Attach and manage supporting documents (invoices, receipts, tax notices) for journal entries. Files are never used to create journals, change amounts, post/reverse entries, or bypass period locks.

#### list_journal_attachments
List supporting documents attached to a journal (requires `read` permission).

Parameters:
- `journal_id` - Journal UUID

Returns:
```json
{
  "journal_id": "uuid",
  "attachments": [
    {
      "id": "uuid",
      "file_name": "invoice.pdf",
      "file_size": 524288,
      "content_type": "application/pdf",
      "created_at": "2026-09-01T12:00:00Z"
    }
  ]
}
```

#### get_journal_attachment_url
Get a signed download URL for a supporting document (requires `read` permission). URL is valid for 5 minutes.

Parameters:
- `journal_id` - Journal UUID
- `attachment_id` - Attachment UUID

Returns:
```json
{
  "attachment_id": "uuid",
  "file_name": "invoice.pdf",
  "url": "https://storage.example.com/...",
  "expires_in": 300
}
```

#### upload_journal_attachment
Upload a supporting document to a journal (requires `read_write` permission).

Accepts PDF, PNG, JPEG, or WebP files up to 10 MB. File data must be base64-encoded.

Parameters:
- `journal_id` - Journal UUID
- `file_name` - Original file name with extension (e.g., "invoice.pdf")
- `file_data` - Base64-encoded file content
- `content_type` - MIME type: `application/pdf`, `image/png`, `image/jpeg`, or `image/webp`

Returns:
```json
{
  "success": true,
  "attachment": {
    "id": "uuid",
    "file_name": "invoice.pdf",
    "file_size": 524288,
    "content_type": "application/pdf",
    "created_at": "2026-09-01T12:00:00Z"
  }
}
```

#### delete_journal_attachment
Delete a supporting document from a journal (requires `read_write` permission).

Parameters:
- `journal_id` - Journal UUID
- `attachment_id` - Attachment UUID

Returns:
```json
{
  "success": true,
  "attachment_id": "uuid"
}
```

### Contacts

#### list_contacts
List contacts (vendors, customers).

Parameters:
- `type` (optional) - Filter by contact type: Vendor, Customer, Other

#### list_customers
List customer contacts (convenience method).

#### create_customer
Create a new customer contact (requires `read_write` permission).

Parameters:
- `name` - Customer name
- `email` (optional) - Customer email
- `phone` (optional) - Customer phone
- `address` (optional) - Customer address
- `notes` (optional) - Additional notes

### Bills (Accounts Payable)

#### list_bills
List vendor bills.

Parameters:
- `status` (optional) - Filter by status: Draft, Open, Paid, Void

#### draft_bill
Create a draft vendor bill (requires `read_write` permission).

Parameters:
- `vendor_id` - Vendor contact UUID
- `number` - Bill number (e.g., "BILL-2026-0001")
- `bill_date` - Bill date (YYYY-MM-DD)
- `due_date` (optional) - Due date (YYYY-MM-DD)
- `lines` - Array of bill lines:
  - `account_id` - Expense account UUID
  - `amount_cents` - Line amount in cents
  - `description` - Line description
- `notes` (optional) - Bill notes

#### post_bill
Post a draft vendor bill (requires `can_post` permission).

Creates Dr Expense / Cr 2000 AP journal entry.

Parameters:
- `bill_id` - Bill UUID

#### pay_bill
Record bill payment outside Open Ledger (requires `can_post` permission).

Use after paying in Airwallex, Ramp, or bank. Creates Dr 2000 AP / Cr Cash journal entry.

Parameters:
- `bill_id` - Open bill UUID
- `payment_date` - Payment date (YYYY-MM-DD)
- `amount_cents` - Payment amount in cents
- `cash_account_id` - Cash account UUID (typically 1010)
- `notes` (optional) - Payment notes (e.g., Airwallex payout ID)

### Invoices (Accounts Receivable)

#### list_invoices
List customer invoices.

Parameters:
- `status` (optional) - Filter by status: Draft, Quote, Posted, Paid, Void
- `customer_id` (optional) - Filter by customer UUID

#### get_invoice
Get a specific invoice with lines.

Parameters:
- `invoice_id` - Invoice UUID

#### draft_invoice
Create a draft customer invoice (requires `read_write` permission).

Parameters:
- `customer_id` - Customer UUID
- `number` - Invoice number (e.g., "INV-2026-0001")
- `invoice_date` - Invoice date (YYYY-MM-DD)
- `due_date` (optional) - Due date (YYYY-MM-DD)
- `status` (optional) - "Draft" (default, can be posted) or "Quote" (estimate only, no journal)
- `lines` - Array of invoice lines:
  - `account_id` - Revenue account UUID
  - `amount_cents` - Line amount in cents
  - `description` - Line description
- `notes` (optional) - Invoice notes

#### post_invoice
Post a draft invoice (requires `can_post` permission).

Creates Dr 1100 AR / Cr Revenue journal entry.

Parameters:
- `invoice_id` - Invoice UUID

#### record_receipt
Record a cash receipt against an invoice (requires `can_post` permission).

Creates Dr Cash / Cr 1100 AR journal entry.

Parameters:
- `invoice_id` - Invoice UUID
- `receipt_date` - Receipt date (YYYY-MM-DD)
- `amount_cents` - Receipt amount in cents
- `cash_account_id` - Cash account UUID (typically 1010)
- `notes` (optional) - Receipt notes

#### issue_credit_note
Issue a credit note against an invoice (requires `can_post` permission).

Creates Dr Revenue / Cr 1100 AR journal entry.

Parameters:
- `invoice_id` - Invoice UUID
- `credit_date` - Credit note date (YYYY-MM-DD)
- `amount_cents` - Credit amount in cents
- `reason` - Reason for credit note

#### write_off_invoice
Write off an uncollectible invoice (requires `can_post` permission).

Creates Dr 5110 Bad Debt Expense / Cr 1100 AR journal entry.

Parameters:
- `invoice_id` - Invoice UUID
- `write_off_date` - Write-off date (YYYY-MM-DD)
- `amount_cents` - Write-off amount in cents
- `reason` - Reason for write-off

#### send_invoice_reminder
Log an invoice reminder event (requires `read` permission).

This logs a reminder in the audit trail but does not send email. Quote status invoices cannot be reminded.

Parameters:
- `invoice_id` - Invoice UUID

### Reports

#### get_profit_and_loss
Get Profit & Loss statement for a date range.

Parameters:
- `start_date` - Start date (YYYY-MM-DD)
- `end_date` - End date (YYYY-MM-DD)

#### get_balance_sheet
Get Balance Sheet as of a specific date.

Parameters:
- `as_of_date` (optional) - As-of date (YYYY-MM-DD), defaults to today

#### get_trial_balance
Get Trial Balance as of a specific date.

Parameters:
- `as_of_date` (optional) - As-of date (YYYY-MM-DD), defaults to today

#### get_cash_movement
Get cash movement report for a date range.

Parameters:
- `start_date` - Start date (YYYY-MM-DD)
- `end_date` - End date (YYYY-MM-DD)

#### get_ar_aging
Get Accounts Receivable aging report.

Parameters:
- `as_of_date` (optional) - As-of date (YYYY-MM-DD), defaults to today

#### get_ap_aging
Get Accounts Payable aging report.

Parameters:
- `as_of_date` (optional) - As-of date (YYYY-MM-DD), defaults to today

#### get_account_ledger
Get ledger for a specific account.

Parameters:
- `account_id` - Account UUID
- `start_date` (optional) - Start date filter (YYYY-MM-DD)
- `end_date` (optional) - End date filter (YYYY-MM-DD)

### Fixed Assets

#### list_fixed_assets
List the fixed-asset register.

Parameters:
- `status` (optional) - in_use, held_for_sale, disposed, or impaired
- `class` (optional) - equipment, furniture, leasehold_improvements, or intangible

#### get_fixed_asset
Get one fixed asset and its depreciation runs.

Parameters:
- `asset_id` - Fixed asset UUID

#### register_fixed_asset
Register a fixed asset (requires `can_post` permission).

Posts Dr PPE / Cr cash or AP unless `existing_journal_id` is set for an asset already on the books.

Parameters:
- `description` - Asset description
- `class` - equipment, furniture, leasehold_improvements, or intangible
- `cost_cents` - Acquisition cost in cents
- `useful_life_months` - Useful life in months
- `acquisition_date` - Acquisition date (YYYY-MM-DD)
- `in_service_date` - In-service date (YYYY-MM-DD)
- `residual_cents` (optional) - Residual value in cents
- `credit_account_id` (optional) - Cash or AP account for purchase journal
- `post_acquisition` (optional) - Whether to post the acquisition journal
- `existing_journal_id` (optional) - Posted journal if asset already on GL
- Additional optional parameters: `vendor_id`, `source_bill_id`, `serial_number`, `location`, `notes`, `pledged`, `idle`

#### run_depreciation
Post straight-line depreciation for a calendar month (requires `can_post` permission).

One journal per class. Skips assets already charged that month.

Parameters:
- `period_start` - Any date in the month (YYYY-MM-DD)

#### dispose_fixed_asset
Dispose a register asset (requires `can_post` permission).

Takes remaining month depreciation, clears gross and accumulated depreciation, and records gain/loss on 6110.

Parameters:
- `asset_id` - Fixed asset UUID
- `disposal_date` - Disposal date (YYYY-MM-DD)
- `proceeds_cents` (optional) - Disposal proceeds in cents
- `cash_account_id` (optional) - Required when proceeds_cents > 0

#### get_ppe_rollforward
IAS 16 PPE rollforward by class for a date range.

Parameters:
- `start_date` - Period start (YYYY-MM-DD)
- `end_date` - Period end (YYYY-MM-DD)

## Error Handling

Errors are returned in the MCP error format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32000,
    "message": "Permission denied: can_post permission required"
  }
}
```

## Terminology Notes

- **Supporting documents**: Attachments to journals (invoices, receipts, tax notices). Never called "receipts" to avoid confusion with cash application.
- **Receipt**: Cash application against an invoice (Dr Cash / Cr AR).
- **Journal**: Manual or system-generated journal entry.
- **Post**: Commit a draft journal to the general ledger (cannot be undone, only reversed).
- **Reverse**: Create an offsetting journal entry to cancel a posted journal.
