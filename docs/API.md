# Open Ledger API Documentation

## Authentication

All API requests require an API key passed via the `Authorization` header:

```
Authorization: Bearer sk_live_...
```

API keys have different permission levels:
- `read` - Read-only access to journals, accounts, reports, etc.
- `read_write` - Can create and modify draft journals, invoices, bills, etc.
- `can_post` - Can post journals and invoices (affects the general ledger)

## Base URL

```
https://your-domain.com/api/v1
```

## Endpoints

### Journals

#### List Journals
```
GET /journals
```

Query parameters:
- `status` (optional) - Filter by status: `Draft`, `Posted`, `Reversed`
- `limit` (optional) - Number of results
- `offset` (optional) - Pagination offset

Response:
```json
{
  "journals": [
    {
      "id": "uuid",
      "number": "JE-2026-0001",
      "entry_date": "2026-09-01",
      "description": "Opening entry",
      "status": "Posted",
      "source": "manual",
      "created_at": "2026-09-01T10:00:00Z",
      "posted_at": "2026-09-01T11:00:00Z"
    }
  ]
}
```

#### Get Journal
```
GET /journals/:id
```

Response:
```json
{
  "journal": {
    "id": "uuid",
    "number": "JE-2026-0001",
    "entry_date": "2026-09-01",
    "description": "Opening entry",
    "status": "Posted",
    "source": "manual",
    "created_at": "2026-09-01T10:00:00Z",
    "posted_at": "2026-09-01T11:00:00Z",
    "lines": [
      {
        "id": "uuid",
        "account_id": "uuid",
        "account_code": "1010",
        "account_name": "Operating Cash",
        "account_type": "Asset",
        "debit": "10,000.00 USD",
        "credit": "0.00 USD",
        "memo": "Initial capital"
      }
    ]
  }
}
```

Errors:
- `400` - Invalid journal_id format (not a valid UUID)
- `404` - Journal not found
- `500` - Internal server error

#### Create Draft Journal
```
POST /journals
```

Request body:
```json
{
  "number": "JE-2026-0001",
  "entry_date": "2026-09-01",
  "description": "Opening entry",
  "lines": [
    {
      "account_id": "uuid",
      "debit_cents": 1000000,
      "credit_cents": 0,
      "memo": "Initial capital"
    },
    {
      "account_id": "uuid",
      "debit_cents": 0,
      "credit_cents": 1000000,
      "memo": "Initial capital"
    }
  ]
}
```

Response:
```json
{
  "journal_id": "uuid"
}
```

#### Post Journal
```
POST /journals/:id/post
```

Requires `can_post` permission. Posts a draft journal to the general ledger.

Response:
```json
{
  "success": true,
  "journal_id": "uuid"
}
```

#### Reverse Journal
```
POST /journals/:id/reverse
```

Requires `can_post` permission. Creates a reversing entry for a posted journal.

Request body:
```json
{
  "reversal_date": "2026-09-15",
  "reversal_description": "Correction"
}
```

Response:
```json
{
  "success": true,
  "original_journal_id": "uuid",
  "reversal_journal_id": "uuid"
}
```

#### Delete Draft Journal
```
DELETE /journals/:id
```

Requires `read_write` permission. Deletes a draft journal. Only draft journals can be deleted; posted and reversed journals cannot be deleted.

Response:
```
204 No Content
```

Errors:
- `400` - Invalid journal_id format (not a valid UUID)
- `403` - Insufficient permissions (requires `read_write`)
- `404` - Journal not found
- `409` - Journal is not a draft (only drafts can be deleted)
- `500` - Internal server error

### Journal Supporting Documents

Attach PDF, PNG, JPEG, or WebP files to journals as supporting documentation (invoices, receipts, tax notices, etc.). Files are scoped to the journal and never affect posting, amounts, or period locks.

**Authorization:**
- List/Download: `read` permission (journal read access)
- Upload/Delete: `read_write` permission (journal write access)

#### List Attachments
```
GET /journals/:id/attachments
```

Response:
```json
{
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

#### Upload Attachment
```
POST /journals/:id/attachments
Content-Type: multipart/form-data
```

Form fields:
- `file` - The file to upload (PDF, PNG, JPEG, or WebP, max 10 MB)

Response:
```json
{
  "attachment": {
    "id": "uuid",
    "file_name": "invoice.pdf",
    "file_size": 524288,
    "content_type": "application/pdf",
    "created_at": "2026-09-01T12:00:00Z"
  }
}
```

#### Get Download URL
```
GET /journals/:id/attachments/:attachmentId
```

Returns a signed URL valid for 5 minutes.

Response:
```json
{
  "url": "https://storage.example.com/...",
  "expires_in": 300
}
```

#### Delete Attachment
```
DELETE /journals/:id/attachments/:attachmentId
```

Response:
```json
{
  "success": true,
  "attachment_id": "uuid"
}
```

### Accounts

#### List Accounts
```
GET /accounts
```

Query parameters:
- `type` (optional) - Filter by type: `Asset`, `Liability`, `Equity`, `Revenue`, `Expense`
- `is_active` (optional) - Filter by active status

Response:
```json
{
  "accounts": [
    {
      "id": "uuid",
      "code": "1010",
      "name": "Operating Cash",
      "type": "Asset",
      "category": "Cash",
      "is_header": false,
      "is_cash": true,
      "is_active": true,
      "parent_id": null
    }
  ]
}
```

### Reports

#### Trial Balance
```
GET /reports/trial-balance?as_of_date=2026-09-30
```

Query parameters:
- `as_of_date` (required) - Date in YYYY-MM-DD format

Response:
```json
{
  "report": {
    "rows": [
      {
        "account_id": "uuid",
        "account_code": "1010",
        "account_name": "Operating cash",
        "account_type": "Asset",
        "debit": "100,000.00 USD",
        "credit": "0.00 USD",
        "debit_cents": 10000000,
        "credit_cents": 0
      }
    ],
    "total_debit_cents": 10000000,
    "total_credit_cents": 10000000,
    "balanced": true
  }
}
```

#### Balance Sheet
```
GET /reports/balance-sheet?as_of_date=2026-09-30
```

#### Profit & Loss
```
GET /reports/profit-and-loss?start_date=2026-01-01&end_date=2026-12-31
```

#### Cash Movement
```
GET /reports/cash-movement?start_date=2026-01-01&end_date=2026-12-31
```

#### AR Aging
```
GET /reports/ar-aging?as_of_date=2026-09-30
```

#### AP Aging
```
GET /reports/ap-aging?as_of_date=2026-09-30
```

#### Account Ledger
```
GET /reports/account-ledger?account_id=uuid&start_date=2026-01-01&end_date=2026-12-31
```

Query parameters:
- `account_id` (required) - Account UUID (must be a valid UUID format)
- `start_date` (optional) - Start date in YYYY-MM-DD format
- `end_date` (optional) - End date in YYYY-MM-DD format

Response:
```json
{
  "report": {
    "account_id": "uuid",
    "account_type": "Asset",
    "rows": [
      {
        "journal_id": "uuid",
        "journal_number": "JE-2026-0001",
        "entry_date": "2026-01-15",
        "description": "Parent funding",
        "line_memo": "Initial capital",
        "status": "Posted",
        "debit": "100,000.00 USD",
        "credit": "0.00 USD",
        "debit_cents": 10000000,
        "credit_cents": 0,
        "running_balance_cents": 10000000,
        "signed_running_balance_cents": 10000000
      }
    ],
    "ending_balance_cents": 10000000
  }
}
```

Notes:
- `signed_running_balance_cents` is signed by account normal balance: Asset/Expense accounts show positive for debits, Liability/Equity/Revenue accounts show positive for credits
- `ending_balance_cents` is the signed balance from the last row
- Invalid `account_id` (non-UUID) returns 400 error: `"account_id must be a UUID, like 3f6c1e2a-b4c7-4d8e-9f1a-2b3c4d5e6f7a"`

## Error Responses

All error responses follow this format:

```json
{
  "error": {
    "code": "permission_denied",
    "message": "API key does not have post permission (can_post)"
  }
}
```

Common error codes:
- `missing_auth` - Missing Authorization header
- `invalid_auth` - Invalid Authorization header format
- `invalid_key` - Invalid API key
- `key_revoked` - API key has been revoked
- `key_expired` - API key has expired
- `permission_denied` - Insufficient permissions
- `not_found` - Resource not found
- `not_draft` - Journal is not a draft (only drafts can be deleted)
- `invalid_journal_id` - Invalid journal_id format (not a valid UUID)
- `invalid_account_id` - Invalid account_id format (not a valid UUID)
- `invalid_invoice_id` - Invalid invoice_id format (not a valid UUID)
- `invalid_fixed_asset_id` - Invalid fixed_asset_id format (not a valid UUID)
- `invalid_request` - Invalid request parameters
- `internal_error` - Server error

## Rate Limits

API requests are logged for audit purposes. There are currently no rate limits, but excessive usage may be throttled.

## Idempotency

For POST requests that create resources, you can provide an `Idempotency-Key` header to prevent duplicate operations. The value must be a valid UUID:

```
Idempotency-Key: 3f6c1e2a-b4c7-4d8e-9f1a-2b3c4d5e6f7a
```

If the same key is used within 24 hours, the original response will be returned without creating a duplicate resource.
