// MCP Server for Open Ledger
// Implements Model Context Protocol over Streamable HTTP
import { NextRequest, NextResponse } from 'next/server'
import { validateAPIKey, checkPermission, logAPIUsage } from '@/lib/api-auth'
import {
  getOrganization,
  listAccounts,
  listJournals,
  getJournal,
  draftJournal,
  deleteJournal,
  postJournal,
  reverseJournal,
  listContacts,
  createContact,
  createAccount,
  deleteAccount,
  listBills,
  draftBill,
  postBill,
  payBill,
  listInvoices,
  getInvoice,
  draftInvoice,
  postInvoice,
  recordReceipt,
  issueCreditNote,
  writeOffInvoice,
  sendInvoiceReminder,
  getARAging,
  getProfitAndLoss,
  getBalanceSheet,
  getTrialBalance,
  getCashMovement,
  getAPAging,
  getAccountLedger,
  listFixedAssets,
  getFixedAsset,
  registerFixedAsset,
  runDepreciation,
  disposeFixedAsset,
  getPpeRollforward,
} from '@/lib/ledger'
import { createServerClient } from '@supabase/ssr'
import {
  listJournalAttachments,
  uploadJournalAttachment,
  deleteJournalAttachment,
  createAttachmentSignedUrl,
} from '@/lib/journal-attachments'

interface MCPRequest {
  jsonrpc: '2.0'
  id?: string | number
  method: string
  params?: any
}

interface MCPResponse {
  jsonrpc: '2.0'
  id?: string | number
  result?: any
  error?: {
    code: number
    message: string
    data?: any
  }
}

export async function POST(request: NextRequest) {
  try {
    // Validate API key
    const authHeader = request.headers.get('authorization')
    const auth = await validateAPIKey(authHeader)

    if ('error' in auth) {
      return NextResponse.json(
        {
          jsonrpc: '2.0',
          error: {
            code: -32001,
            message: auth.error.message,
          },
        },
        { status: 401 }
      )
    }

    // Parse MCP request
    const mcpRequest: MCPRequest = await request.json()

    // Handle different MCP methods
    let response: MCPResponse

    switch (mcpRequest.method) {
      case 'tools/list':
        response = await handleToolsList(auth)
        response.id = mcpRequest.id
        break

      case 'tools/call':
        response = await handleToolsCall(auth, mcpRequest)
        break

      case 'initialize':
        response = {
          jsonrpc: '2.0',
          id: mcpRequest.id,
          result: {
            protocolVersion: '2024-11-05',
            serverInfo: {
              name: 'open-ledger',
              version: '1.0.0',
            },
            capabilities: {
              tools: {},
            },
          },
        }
        break

      default:
        response = {
          jsonrpc: '2.0',
          id: mcpRequest.id,
          error: {
            code: -32601,
            message: `Method not found: ${mcpRequest.method}`,
          },
        }
    }

    await logAPIUsage(auth, 'POST', '/api/mcp', 200)

    return NextResponse.json(response)
  } catch (error: any) {
    return NextResponse.json(
      {
        jsonrpc: '2.0',
        error: {
          code: -32603,
          message: error.message || 'Internal error',
        },
      },
      { status: 500 }
    )
  }
}

async function handleToolsList(auth: any): Promise<MCPResponse> {
  const tools = [
    {
      name: 'get_organization',
      description: 'Get organization details',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'list_accounts',
      description: 'List all chart of accounts entries',
      inputSchema: {
        type: 'object',
        properties: {
          type: {
            type: 'string',
            description: 'Filter by account type (Asset, Liability, Equity, Revenue, Expense)',
          },
          is_active: {
            type: 'boolean',
            description: 'Filter by active status',
          },
        },
      },
    },
    {
      name: 'list_journals',
      description: 'List journal entries',
      inputSchema: {
        type: 'object',
        properties: {
          status: {
            type: 'string',
            description: 'Filter by status (Draft, Posted, Reversed)',
          },
          limit: {
            type: 'number',
            description: 'Limit number of results',
          },
        },
      },
    },
    {
      name: 'get_journal',
      description: 'Get a specific journal entry with lines',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: {
            type: 'string',
            description: 'Journal ID (UUID)',
          },
        },
        required: ['journal_id'],
      },
    },
    {
      name: 'list_journal_attachments',
      description: 'List supporting documents attached to a journal',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: {
            type: 'string',
            description: 'Journal ID (UUID)',
          },
        },
        required: ['journal_id'],
      },
    },
    {
      name: 'get_journal_attachment_url',
      description: 'Get a signed download URL for a journal supporting document',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: {
            type: 'string',
            description: 'Journal ID (UUID)',
          },
          attachment_id: {
            type: 'string',
            description: 'Attachment ID (UUID)',
          },
        },
        required: ['journal_id', 'attachment_id'],
      },
    },
    {
      name: 'list_contacts',
      description: 'List contacts (vendors, customers)',
      inputSchema: {
        type: 'object',
        properties: {
          type: {
            type: 'string',
            description: 'Filter by contact type (Vendor, Customer, Other)',
          },
        },
      },
    },
    {
      name: 'list_customers',
      description: 'List customer contacts',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'list_bills',
      description: 'List vendor bills',
      inputSchema: {
        type: 'object',
        properties: {
          status: {
            type: 'string',
            description: 'Filter by status (Draft, Open, Paid, Void)',
          },
        },
      },
    },
    {
      name: 'list_invoices',
      description: 'List customer invoices',
      inputSchema: {
        type: 'object',
        properties: {
          status: {
            type: 'string',
            description: 'Filter by status (Draft, Quote, Posted, Paid, Void)',
          },
          customer_id: {
            type: 'string',
            description: 'Filter by customer ID (UUID)',
          },
        },
      },
    },
    {
      name: 'get_invoice',
      description: 'Get a specific invoice with lines',
      inputSchema: {
        type: 'object',
        properties: {
          invoice_id: {
            type: 'string',
            description: 'Invoice ID (UUID)',
          },
        },
        required: ['invoice_id'],
      },
    },
    {
      name: 'get_profit_and_loss',
      description: 'Get Profit & Loss statement for a date range',
      inputSchema: {
        type: 'object',
        properties: {
          start_date: {
            type: 'string',
            description: 'Start date (YYYY-MM-DD)',
          },
          end_date: {
            type: 'string',
            description: 'End date (YYYY-MM-DD)',
          },
        },
        required: ['start_date', 'end_date'],
      },
    },
    {
      name: 'get_balance_sheet',
      description: 'Get Balance Sheet as of a specific date',
      inputSchema: {
        type: 'object',
        properties: {
          as_of_date: {
            type: 'string',
            description: 'As-of date (YYYY-MM-DD), defaults to today',
          },
        },
      },
    },
    {
      name: 'get_trial_balance',
      description: 'Get Trial Balance as of a specific date',
      inputSchema: {
        type: 'object',
        properties: {
          as_of_date: {
            type: 'string',
            description: 'As-of date (YYYY-MM-DD), defaults to today',
          },
        },
      },
    },
    {
      name: 'get_cash_movement',
      description: 'Get cash movement report for a date range',
      inputSchema: {
        type: 'object',
        properties: {
          start_date: {
            type: 'string',
            description: 'Start date (YYYY-MM-DD)',
          },
          end_date: {
            type: 'string',
            description: 'End date (YYYY-MM-DD)',
          },
        },
        required: ['start_date', 'end_date'],
      },
    },
    {
      name: 'get_ap_aging',
      description: 'Get Accounts Payable aging report',
      inputSchema: {
        type: 'object',
        properties: {
          as_of_date: {
            type: 'string',
            description: 'As-of date (YYYY-MM-DD), defaults to today',
          },
        },
      },
    },
    {
      name: 'get_account_ledger',
      description: 'Get ledger for a specific account',
      inputSchema: {
        type: 'object',
        properties: {
          account_id: {
            type: 'string',
            description: 'Account ID (UUID)',
          },
          start_date: {
            type: 'string',
            description: 'Optional start date filter (YYYY-MM-DD)',
          },
          end_date: {
            type: 'string',
            description: 'Optional end date filter (YYYY-MM-DD)',
          },
        },
        required: ['account_id'],
      },
    },
  ]

  // Only include write tools if write permission
  if (auth.canWrite) {
    tools.push({
      name: 'upload_journal_attachment',
      description: 'Upload a supporting document to a journal (requires read_write permission). Accepts PDF, PNG, JPEG, or WebP up to 10 MB. File must be provided as base64-encoded data.',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: {
            type: 'string',
            description: 'Journal ID (UUID)',
          },
          file_name: {
            type: 'string',
            description: 'Original file name with extension (e.g., "invoice.pdf")',
          },
          file_data: {
            type: 'string',
            description: 'Base64-encoded file content',
          },
          content_type: {
            type: 'string',
            description: 'MIME type: application/pdf, image/png, image/jpeg, or image/webp',
          },
        },
        required: ['journal_id', 'file_name', 'file_data', 'content_type'],
      },
    } as any)

    tools.push({
      name: 'delete_journal_attachment',
      description: 'Delete a supporting document from a journal (requires read_write permission)',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: {
            type: 'string',
            description: 'Journal ID (UUID)',
          },
          attachment_id: {
            type: 'string',
            description: 'Attachment ID (UUID)',
          },
        },
        required: ['journal_id', 'attachment_id'],
      },
    } as any)

    tools.push({
      name: 'draft_journal',
      description: 'Create a draft journal entry (requires read_write permission)',
      inputSchema: {
        type: 'object',
        properties: {
          number: {
            type: 'string',
            description: 'Journal number (e.g., JE-2026-0001)',
          },
          entry_date: {
            type: 'string',
            description: 'Entry date (YYYY-MM-DD)',
          },
          description: {
            type: 'string',
            description: 'Journal description',
          },
          lines: {
            type: 'array',
            description: 'Journal lines',
            items: {
              type: 'object',
              properties: {
                account_id: { type: 'string' },
                debit_cents: { type: 'number' },
                credit_cents: { type: 'number' },
                memo: { type: 'string' },
              },
              required: ['account_id'],
            },
          },
        },
        required: ['number', 'entry_date', 'description', 'lines'],
      },
    } as any)

    tools.push({
      name: 'delete_journal',
      description: 'Delete a draft journal (requires read_write permission). Only draft journals can be deleted. Posted and Reversed journals cannot be deleted.',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: {
            type: 'string',
            description: 'Journal ID (UUID) to delete',
          },
        },
        required: ['journal_id'],
      },
    } as any)

    tools.push({
      name: 'create_customer',
      description: 'Create a new customer contact (requires read_write permission)',
      inputSchema: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: 'Customer name (e.g., "Customer")',
          },
          email: {
            type: 'string',
            description: 'Customer email address',
          },
          phone: {
            type: 'string',
            description: 'Customer phone number',
          },
          address: {
            type: 'string',
            description: 'Customer address',
          },
          notes: {
            type: 'string',
            description: 'Additional notes',
          },
        },
        required: ['name'],
      },
    } as any)

    tools.push({
      name: 'draft_invoice',
      description: 'Create a draft customer invoice (requires read_write permission). Invoice examples use "INV-2026-0001" format and "Customer" as customer name. Status can be Draft (default) or Quote (no journal).',
      inputSchema: {
        type: 'object',
        properties: {
          customer_id: {
            type: 'string',
            description: 'Customer ID (UUID)',
          },
          number: {
            type: 'string',
            description: 'Invoice number (e.g., INV-2026-0001)',
          },
          invoice_date: {
            type: 'string',
            description: 'Invoice date (YYYY-MM-DD)',
          },
          due_date: {
            type: 'string',
            description: 'Due date (YYYY-MM-DD)',
          },
          status: {
            type: 'string',
            description: 'Invoice status: Draft (default, can be posted) or Quote (estimate only, no journal)',
          },
          lines: {
            type: 'array',
            description: 'Invoice lines with revenue accounts',
            items: {
              type: 'object',
              properties: {
                account_id: { type: 'string', description: 'Revenue account ID' },
                amount_cents: { type: 'number', description: 'Line amount in cents' },
                description: { type: 'string', description: 'Line description' },
              },
              required: ['account_id', 'amount_cents', 'description'],
            },
          },
          notes: {
            type: 'string',
            description: 'Invoice notes',
          },
        },
        required: ['customer_id', 'number', 'invoice_date', 'lines'],
      },
    } as any)

    tools.push({
      name: 'draft_bill',
      description: 'Create a draft vendor bill (requires read_write permission). Post separately with post_bill.',
      inputSchema: {
        type: 'object',
        properties: {
          vendor_id: { type: 'string', description: 'Vendor contact ID (UUID)' },
          number: { type: 'string', description: 'Bill number (e.g., BILL-2026-0001)' },
          bill_date: { type: 'string', description: 'Bill date (YYYY-MM-DD)' },
          due_date: { type: 'string', description: 'Due date (YYYY-MM-DD)' },
          lines: {
            type: 'array',
            description: 'Bill lines with expense accounts',
            items: {
              type: 'object',
              properties: {
                account_id: { type: 'string' },
                amount_cents: { type: 'number' },
                description: { type: 'string' },
              },
              required: ['account_id', 'amount_cents', 'description'],
            },
          },
          notes: { type: 'string', description: 'Bill notes' },
        },
        required: ['vendor_id', 'number', 'bill_date', 'lines'],
      },
    } as any)

    tools.push({
      name: 'create_account',
      description: 'Create a chart of accounts entry (requires read_write permission). Cannot create system accounts. Cash accounts must be Asset type.',
      inputSchema: {
        type: 'object',
        properties: {
          code: { type: 'string', description: 'Account number (e.g., 5100)' },
          name: { type: 'string', description: 'Account name' },
          type: { type: 'string', description: 'Asset, Liability, Equity, Revenue, or Expense' },
          category: { type: 'string', description: 'Optional: Cash, AR, AP, Equity, Revenue, COGS, Expense, Other' },
          is_cash: { type: 'boolean', description: 'True for bank or cash accounts (Asset only)' },
          parent_id: { type: 'string', description: 'Optional parent account ID' },
        },
        required: ['code', 'name', 'type'],
      },
    } as any)

    tools.push({
      name: 'delete_account',
      description: 'Delete an unused account (requires read_write permission). Refuses system accounts and accounts with journal, bill, or invoice lines.',
      inputSchema: {
        type: 'object',
        properties: {
          account_id: { type: 'string', description: 'Account ID (UUID)' },
        },
        required: ['account_id'],
      },
    } as any)
  }

  // Only include post_journal if can_post permission
  if (auth.canPost) {
    tools.push({
      name: 'post_journal',
      description:
        'Post a draft journal entry (requires can_post permission). WARNING: This operation affects the general ledger and cannot be undone directly. Posted journals can only be reversed.',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: {
            type: 'string',
            description: 'Journal ID (UUID) to post',
          },
        },
        required: ['journal_id'],
      },
    })

    tools.push({
      name: 'post_invoice',
      description:
        'Post a draft invoice (requires can_post permission). Creates Dr 1100 Accounts Receivable / Cr Revenue journal entry. Validates period locks and revenue account types. Parent/Vendor/Other contacts cannot be invoiced.',
      inputSchema: {
        type: 'object',
        properties: {
          invoice_id: {
            type: 'string',
            description: 'Invoice ID (UUID) to post',
          },
        },
        required: ['invoice_id'],
      },
    } as any)

    tools.push({
      name: 'record_receipt',
      description:
        'Record a cash receipt against an invoice (requires can_post permission). Creates Dr Cash / Cr 1100 AR journal entry.',
      inputSchema: {
        type: 'object',
        properties: {
          invoice_id: {
            type: 'string',
            description: 'Invoice ID (UUID)',
          },
          receipt_date: {
            type: 'string',
            description: 'Receipt date (YYYY-MM-DD)',
          },
          amount_cents: {
            type: 'number',
            description: 'Receipt amount in cents',
          },
          cash_account_id: {
            type: 'string',
            description: 'Cash account ID (UUID, typically 1010 Operating Cash)',
          },
          notes: {
            type: 'string',
            description: 'Receipt notes',
          },
        },
        required: ['invoice_id', 'receipt_date', 'amount_cents', 'cash_account_id'],
      },
    } as any)

    tools.push({
      name: 'issue_credit_note',
      description:
        'Issue a credit note against an invoice (requires can_post permission). Creates Dr Revenue / Cr 1100 AR journal entry.',
      inputSchema: {
        type: 'object',
        properties: {
          invoice_id: {
            type: 'string',
            description: 'Invoice ID (UUID)',
          },
          credit_date: {
            type: 'string',
            description: 'Credit note date (YYYY-MM-DD)',
          },
          amount_cents: {
            type: 'number',
            description: 'Credit amount in cents',
          },
          reason: {
            type: 'string',
            description: 'Reason for credit note',
          },
        },
        required: ['invoice_id', 'credit_date', 'amount_cents', 'reason'],
      },
    } as any)

    tools.push({
      name: 'write_off_invoice',
      description:
        'Write off an uncollectible invoice (requires can_post permission). Creates Dr 5110 Bad Debt Expense / Cr 1100 AR journal entry.',
      inputSchema: {
        type: 'object',
        properties: {
          invoice_id: {
            type: 'string',
            description: 'Invoice ID (UUID)',
          },
          write_off_date: {
            type: 'string',
            description: 'Write-off date (YYYY-MM-DD)',
          },
          amount_cents: {
            type: 'number',
            description: 'Write-off amount in cents',
          },
          reason: {
            type: 'string',
            description: 'Reason for write-off',
          },
        } as any,
        required: ['invoice_id', 'write_off_date', 'amount_cents', 'reason'],
      },
    } as any)

    tools.push({
      name: 'reverse_journal',
      description:
        'Reverse a posted journal (requires can_post permission). Creates a reversing entry. Original status becomes Reversed.',
      inputSchema: {
        type: 'object',
        properties: {
          journal_id: { type: 'string', description: 'Posted journal ID (UUID)' },
          reversal_date: { type: 'string', description: 'Reversal date (YYYY-MM-DD)' },
          reversal_description: { type: 'string', description: 'Optional reversal memo' },
        },
        required: ['journal_id', 'reversal_date'],
      },
    } as any)

    tools.push({
      name: 'post_bill',
      description:
        'Post a draft vendor bill (requires can_post permission). Creates Dr Expense / Cr 2000 AP and sets the bill to Open.',
      inputSchema: {
        type: 'object',
        properties: {
          bill_id: { type: 'string', description: 'Bill ID (UUID)' },
        },
        required: ['bill_id'],
      },
    } as any)

    tools.push({
      name: 'pay_bill',
      description:
        'Record that a vendor bill was paid outside Open Ledger (requires can_post permission). Does not send money. Use after paying in Airwallex, Ramp, or a bank. Creates Dr 2000 AP / Cr Cash.',
      inputSchema: {
        type: 'object',
        properties: {
          bill_id: { type: 'string', description: 'Open bill ID (UUID)' },
          payment_date: { type: 'string', description: 'Payment date (YYYY-MM-DD)' },
          amount_cents: { type: 'number', description: 'Payment amount in cents' },
          cash_account_id: { type: 'string', description: 'Cash account ID (typically 1010)' },
          notes: { type: 'string', description: 'e.g. Airwallex payout id' },
        },
        required: ['bill_id', 'payment_date', 'amount_cents', 'cash_account_id'],
      },
    } as any)
  }

  // send_invoice_reminder requires write permission (sends email + PDF, no GL posting)
  tools.push({
    name: 'send_invoice_reminder',
    description:
      'Send an invoice reminder with PDF attachment via email (requires write permission). This sends an email to the customer and logs a reminder event in the audit trail. Does NOT create any journal entries or affect GL. Only works for posted invoices with open balance. Quote and Draft invoices cannot be reminded. Accepts to_email, email, to, or recipient_email.',
    inputSchema: {
      type: 'object',
      properties: {
        invoice_id: {
          type: 'string',
          description: 'Invoice ID (UUID)',
        },
        to_email: {
          type: 'string',
          description: 'Recipient email address (optional, defaults to customer email). Accepts to_email, email, to, or recipient_email.',
        },
      },
      required: ['invoice_id'],
    },
  } as any)

  tools.push({
    name: 'get_ar_aging',
    description: 'Get Accounts Receivable aging report (requires read permission)',
    inputSchema: {
      type: 'object',
      properties: {
        as_of_date: {
          type: 'string',
          description: 'As-of date (YYYY-MM-DD), defaults to today',
        },
      },
    },
  } as any)

  tools.push({
    name: 'list_fixed_assets',
    description: 'List the fixed-asset register',
    inputSchema: {
      type: 'object',
      properties: {
        status: { type: 'string', description: 'in_use, held_for_sale, disposed, or impaired' },
        class: { type: 'string', description: 'equipment, furniture, leasehold_improvements, or intangible' },
      },
    },
  } as any)

  tools.push({
    name: 'get_fixed_asset',
    description: 'Get one fixed asset and its depreciation runs',
    inputSchema: {
      type: 'object',
      properties: {
        asset_id: { type: 'string', description: 'Fixed asset ID (UUID)' },
      },
      required: ['asset_id'],
    },
  } as any)

  tools.push({
    name: 'get_ppe_rollforward',
    description: 'IAS 16 PPE rollforward by class for a date range',
    inputSchema: {
      type: 'object',
      properties: {
        start_date: { type: 'string', description: 'Period start (YYYY-MM-DD)' },
        end_date: { type: 'string', description: 'Period end (YYYY-MM-DD)' },
      },
      required: ['start_date', 'end_date'],
    },
  } as any)

  if (auth.canPost) {
    tools.push({
      name: 'register_fixed_asset',
      description:
        'Register a fixed asset. Posts Dr PPE / Cr cash or AP unless existing_journal_id is set for an asset already on the books. Refuses cost below the organization capitalization threshold.',
      inputSchema: {
        type: 'object',
        properties: {
          description: { type: 'string' },
          class: { type: 'string', description: 'equipment, furniture, leasehold_improvements, or intangible' },
          cost_cents: { type: 'number' },
          useful_life_months: { type: 'number' },
          acquisition_date: { type: 'string' },
          in_service_date: { type: 'string' },
          residual_cents: { type: 'number' },
          credit_account_id: { type: 'string', description: 'Cash or AP account when posting the buy' },
          post_acquisition: { type: 'boolean' },
          existing_journal_id: { type: 'string', description: 'Posted journal if the asset is already on the GL' },
          brought_forward_accum_dep_cents: { type: 'number' },
          brought_forward_as_of: { type: 'string' },
          brought_forward_journal_id: { type: 'string' },
          vendor_id: { type: 'string' },
          source_bill_id: { type: 'string' },
          serial_number: { type: 'string' },
          location: { type: 'string' },
          notes: { type: 'string' },
          pledged: { type: 'boolean' },
          idle: { type: 'boolean' },
        },
        required: ['description', 'class', 'cost_cents', 'useful_life_months', 'acquisition_date', 'in_service_date'],
      },
    } as any)

    tools.push({
      name: 'run_depreciation',
      description: 'Post straight-line depreciation for a calendar month. One journal per class. Skips assets already charged that month.',
      inputSchema: {
        type: 'object',
        properties: {
          period_start: { type: 'string', description: 'Any date in the month (YYYY-MM-DD)' },
        },
        required: ['period_start'],
      },
    } as any)

    tools.push({
      name: 'dispose_fixed_asset',
      description: 'Dispose a register asset. Takes remaining month depreciation, clears gross and accum, and records gain or loss on 6110.',
      inputSchema: {
        type: 'object',
        properties: {
          asset_id: { type: 'string' },
          disposal_date: { type: 'string' },
          proceeds_cents: { type: 'number' },
          cash_account_id: { type: 'string', description: 'Required when proceeds_cents > 0' },
        },
        required: ['asset_id', 'disposal_date'],
      },
    } as any)
  }

  return {
    jsonrpc: '2.0',
    result: { tools },
  }
}

const WRITE_TOOLS = new Set([
  'draft_journal',
  'delete_journal',
  'upload_journal_attachment',
  'delete_journal_attachment',
  'create_customer',
  'draft_invoice',
  'draft_bill',
  'create_account',
  'delete_account',
])
const POST_TOOLS = new Set([
  'post_journal',
  'reverse_journal',
  'post_invoice',
  'record_receipt',
  'issue_credit_note',
  'write_off_invoice',
  'post_bill',
  'pay_bill',
  'register_fixed_asset',
  'run_depreciation',
  'dispose_fixed_asset',
])

async function handleToolsCall(auth: any, mcpRequest: MCPRequest): Promise<MCPResponse> {
  const { name, arguments: args } = mcpRequest.params

  try {
    if (POST_TOOLS.has(name) && !auth.canPost) {
      throw new Error('Permission denied: can_post permission required')
    }
    if (WRITE_TOOLS.has(name) && !auth.canWrite) {
      throw new Error('Permission denied: read_write permission required')
    }
    if (!POST_TOOLS.has(name) && !WRITE_TOOLS.has(name) && !auth.canRead) {
      throw new Error('Permission denied: read permission required')
    }

    let result: any

    switch (name) {
      case 'get_organization':
        result = await getOrganization(auth.organizationId)
        break

      case 'list_accounts':
        result = await listAccounts(auth.organizationId, args)
        break

      case 'list_journals':
        result = await listJournals(auth.organizationId, args)
        break

      case 'get_journal':
        if (!args?.journal_id) throw new Error('journal_id required')
        result = await getJournal(auth.organizationId, args.journal_id)
        break

      case 'list_journal_attachments': {
        if (!args?.journal_id) throw new Error('journal_id required')
        const supabase = createServerClient(
          process.env.NEXT_PUBLIC_SUPABASE_URL!,
          process.env.SUPABASE_SERVICE_ROLE_KEY!,
          {
            cookies: {
              getAll() { return [] },
              setAll() { },
            },
          }
        )
        const attachments = await listJournalAttachments(supabase, args.journal_id)
        result = {
          journal_id: args.journal_id,
          attachments: attachments.map((att: any) => ({
            id: att.id,
            file_name: att.file_name,
            file_size: att.file_size,
            content_type: att.content_type,
            created_at: att.created_at,
          })),
        }
        break
      }

      case 'get_journal_attachment_url': {
        if (!args?.journal_id) throw new Error('journal_id required')
        if (!args?.attachment_id) throw new Error('attachment_id required')
        const supabase = createServerClient(
          process.env.NEXT_PUBLIC_SUPABASE_URL!,
          process.env.SUPABASE_SERVICE_ROLE_KEY!,
          {
            cookies: {
              getAll() { return [] },
              setAll() { },
            },
          }
        )
        
        const { data: attachment, error: attachmentError } = await supabase
          .from('attachments')
          .select('id, file_name, storage_path')
          .eq('id', args.attachment_id)
          .eq('entity_type', 'journal')
          .eq('entity_id', args.journal_id)
          .eq('organization_id', auth.organizationId)
          .maybeSingle()

        if (attachmentError) throw new Error(attachmentError.message)
        if (!attachment) throw new Error('Attachment not found')

        const signedUrl = await createAttachmentSignedUrl(supabase, attachment.storage_path)
        result = {
          attachment_id: args.attachment_id,
          file_name: attachment.file_name,
          url: signedUrl,
          expires_in: 300,
        }
        break
      }

      // ACCOUNTING INVARIANT: upload_journal_attachment NEVER creates, posts, reverses, or modifies journals.
      // It only writes to storage.objects and attachments table via uploadJournalAttachment.
      case 'upload_journal_attachment': {
        if (!auth.canWrite) {
          throw new Error('Permission denied: read_write permission required')
        }
        if (!args?.journal_id) throw new Error('journal_id required')
        if (!args?.file_name) throw new Error('file_name required')
        if (!args?.file_data) throw new Error('file_data required')
        if (!args?.content_type) throw new Error('content_type required')

        const allowedTypes = new Set(['application/pdf', 'image/png', 'image/jpeg', 'image/webp'])
        if (!allowedTypes.has(args.content_type)) {
          throw new Error('content_type must be application/pdf, image/png, image/jpeg, or image/webp')
        }

        const supabase = createServerClient(
          process.env.NEXT_PUBLIC_SUPABASE_URL!,
          process.env.SUPABASE_SERVICE_ROLE_KEY!,
          {
            cookies: {
              getAll() { return [] },
              setAll() { },
            },
          }
        )

        // Verify journal exists and belongs to organization
        const { data: journal, error: journalError } = await supabase
          .from('journals')
          .select('id')
          .eq('id', args.journal_id)
          .eq('organization_id', auth.organizationId)
          .maybeSingle()

        if (journalError) throw new Error(journalError.message)
        if (!journal) throw new Error('Journal not found')

        // Decode base64 file data
        let fileBuffer: Buffer
        try {
          fileBuffer = Buffer.from(args.file_data, 'base64')
        } catch (e) {
          throw new Error('file_data must be valid base64')
        }

        if (fileBuffer.length === 0) {
          throw new Error('File is empty')
        }

        if (fileBuffer.length > 10 * 1024 * 1024) {
          throw new Error('File size exceeds 10 MB limit')
        }

        // Convert buffer to File-like object using Uint8Array
        const uint8Array = new Uint8Array(fileBuffer)
        const blob = new Blob([uint8Array], { type: args.content_type })
        const file = new File([blob], args.file_name, { type: args.content_type })

        const uploadResult = await uploadJournalAttachment({
          supabase,
          organizationId: auth.organizationId,
          journalId: args.journal_id,
          file,
          userId: auth.userId,
        })

        if (!uploadResult.ok) {
          throw new Error(uploadResult.error)
        }

        result = {
          success: true,
          attachment: {
            id: uploadResult.attachment.id,
            file_name: uploadResult.attachment.file_name,
            file_size: uploadResult.attachment.file_size,
            content_type: uploadResult.attachment.content_type,
            created_at: uploadResult.attachment.created_at,
          },
        }
        break
      }

      case 'delete_journal_attachment': {
        if (!auth.canWrite) {
          throw new Error('Permission denied: read_write permission required')
        }
        if (!args?.journal_id) throw new Error('journal_id required')
        if (!args?.attachment_id) throw new Error('attachment_id required')

        const supabase = createServerClient(
          process.env.NEXT_PUBLIC_SUPABASE_URL!,
          process.env.SUPABASE_SERVICE_ROLE_KEY!,
          {
            cookies: {
              getAll() { return [] },
              setAll() { },
            },
          }
        )

        const { data: attachment, error: attachmentError } = await supabase
          .from('attachments')
          .select('id, file_name, file_size, content_type, storage_path, created_at')
          .eq('id', args.attachment_id)
          .eq('entity_type', 'journal')
          .eq('entity_id', args.journal_id)
          .eq('organization_id', auth.organizationId)
          .maybeSingle()

        if (attachmentError) throw new Error(attachmentError.message)
        if (!attachment) throw new Error('Attachment not found')

        await deleteJournalAttachment({
          supabase,
          attachment,
        })

        result = {
          success: true,
          attachment_id: args.attachment_id,
        }
        break
      }

      case 'draft_journal':
        if (!auth.canWrite) {
          throw new Error('Permission denied: read_write permission required')
        }
        result = await draftJournal(
          auth.organizationId,
          {
            entry_date: args.entry_date,
            description: args.description,
            lines: args.lines,
          },
          auth.keyId
        )
        break

      case 'delete_journal':
        if (!auth.canWrite) {
          throw new Error('Permission denied: read_write permission required')
        }
        if (!args?.journal_id) throw new Error('journal_id required')
        result = await deleteJournal(auth.organizationId, args.journal_id, auth.userId)
        break

      case 'post_journal':
        if (!auth.canPost) {
          throw new Error('Permission denied: can_post permission required')
        }
        if (!args?.journal_id) throw new Error('journal_id required')
        result = await postJournal(auth.organizationId, args.journal_id, auth.userId)
        break

      case 'reverse_journal':
        if (!args?.journal_id) throw new Error('journal_id required')
        if (!args?.reversal_date) throw new Error('reversal_date required')
        result = await reverseJournal(
          auth.organizationId,
          args.journal_id,
          args.reversal_date,
          args.reversal_description,
          auth.userId
        )
        break

      case 'create_account':
        result = await createAccount(auth.organizationId, {
          code: args?.code,
          name: args?.name,
          type: args?.type,
          category: args?.category,
          is_cash: args?.is_cash,
          parent_id: args?.parent_id,
        })
        break

      case 'delete_account':
        if (!args?.account_id) throw new Error('account_id required')
        result = await deleteAccount(auth.organizationId, args.account_id)
        break

      case 'list_contacts':
        result = await listContacts(auth.organizationId, args)
        break

      case 'list_customers':
        result = await listContacts(auth.organizationId, { type: 'Customer', is_active: true })
        break

      case 'create_customer':
        if (!auth.canWrite) {
          throw new Error('Permission denied: read_write permission required')
        }
        result = await createContact(auth.organizationId, {
          type: 'Customer',
          name: args?.name,
          email: args?.email,
          phone: args?.phone,
          address: args?.address,
          notes: args?.notes,
        })
        break

      case 'list_bills':
        result = await listBills(auth.organizationId, args)
        break

      case 'draft_bill':
        result = await draftBill(
          auth.organizationId,
          {
            vendor_id: args?.vendor_id,
            number: args?.number,
            bill_date: args?.bill_date,
            due_date: args?.due_date,
            lines: args?.lines,
            notes: args?.notes,
          },
          auth.keyId
        )
        break

      case 'post_bill':
        if (!args?.bill_id) throw new Error('bill_id required')
        result = await postBill(auth.organizationId, args.bill_id, auth.userId)
        break

      case 'pay_bill':
        result = await payBill(
          auth.organizationId,
          {
            bill_id: args?.bill_id,
            payment_date: args?.payment_date,
            amount_cents: args?.amount_cents,
            cash_account_id: args?.cash_account_id,
            notes: args?.notes,
          },
          auth.userId
        )
        break

      case 'list_invoices':
        result = await listInvoices(auth.organizationId, args)
        break

      case 'get_invoice':
        if (!args?.invoice_id) throw new Error('invoice_id required')
        result = await getInvoice(auth.organizationId, args.invoice_id)
        break

      case 'draft_invoice':
        if (!auth.canWrite) {
          throw new Error('Permission denied: read_write permission required')
        }
        // Validate status if provided
        if (args?.status && args.status !== 'Draft' && args.status !== 'Quote') {
          throw new Error('status must be Draft or Quote')
        }
        result = await draftInvoice(
          auth.organizationId,
          {
            customer_id: args?.customer_id,
            number: args?.number,
            invoice_date: args?.invoice_date,
            due_date: args?.due_date,
            status: args?.status || 'Draft',
            lines: args?.lines,
            notes: args?.notes,
          },
          auth.keyId
        )
        break

      case 'post_invoice':
        if (!auth.canPost) {
          throw new Error('Permission denied: can_post permission required')
        }
        if (!args?.invoice_id) throw new Error('invoice_id required')
        result = await postInvoice(auth.organizationId, args.invoice_id, auth.userId)
        break

      case 'record_receipt':
        if (!auth.canPost) {
          throw new Error('Permission denied: can_post permission required')
        }
        result = await recordReceipt(auth.organizationId, {
          invoice_id: args?.invoice_id,
          receipt_date: args?.receipt_date,
          amount_cents: args?.amount_cents,
          cash_account_id: args?.cash_account_id,
          notes: args?.notes,
        }, auth.userId)
        break

      case 'issue_credit_note':
        if (!auth.canPost) {
          throw new Error('Permission denied: can_post permission required')
        }
        result = await issueCreditNote(auth.organizationId, {
          invoice_id: args?.invoice_id,
          credit_date: args?.credit_date,
          amount_cents: args?.amount_cents,
          reason: args?.reason,
        }, auth.userId)
        break

      case 'write_off_invoice':
        if (!auth.canPost) {
          throw new Error('Permission denied: can_post permission required')
        }
        result = await writeOffInvoice(auth.organizationId, {
          invoice_id: args?.invoice_id,
          write_off_date: args?.write_off_date,
          amount_cents: args?.amount_cents,
          reason: args?.reason,
        }, auth.userId)
        break

      case 'send_invoice_reminder':
        if (!args?.invoice_id) throw new Error('invoice_id required')
        const reminderEmail = args?.to_email || args?.email || args?.to || args?.recipient_email
        result = await sendInvoiceReminder(auth.organizationId, args.invoice_id, auth.userId, reminderEmail)
        break

      case 'get_ar_aging':
        const arAsOfDate = args?.as_of_date || new Date().toISOString().split('T')[0]
        result = await getARAging(auth.organizationId, arAsOfDate)
        break

      case 'get_profit_and_loss':
        if (!args?.start_date || !args?.end_date) {
          throw new Error('start_date and end_date required')
        }
        result = await getProfitAndLoss(auth.organizationId, args.start_date, args.end_date)
        break

      case 'get_balance_sheet':
        const asOfDate = args?.as_of_date || new Date().toISOString().split('T')[0]
        result = await getBalanceSheet(auth.organizationId, asOfDate)
        break

      case 'get_trial_balance':
        const trialAsOfDate = args?.as_of_date || new Date().toISOString().split('T')[0]
        result = await getTrialBalance(auth.organizationId, trialAsOfDate)
        break

      case 'get_cash_movement':
        if (!args?.start_date || !args?.end_date) {
          throw new Error('start_date and end_date required')
        }
        result = await getCashMovement(auth.organizationId, args.start_date, args.end_date)
        break

      case 'get_ap_aging':
        const agingAsOfDate = args?.as_of_date || new Date().toISOString().split('T')[0]
        result = await getAPAging(auth.organizationId, agingAsOfDate)
        break

      case 'get_account_ledger':
        if (!args?.account_id) throw new Error('account_id required')
        result = await getAccountLedger(
          auth.organizationId,
          args.account_id,
          args.start_date,
          args.end_date
        )
        break

      case 'list_fixed_assets':
        result = await listFixedAssets(auth.organizationId, args)
        break

      case 'get_fixed_asset':
        if (!args?.asset_id) throw new Error('asset_id required')
        result = await getFixedAsset(auth.organizationId, args.asset_id)
        break

      case 'get_ppe_rollforward':
        if (!args?.start_date || !args?.end_date) {
          throw new Error('start_date and end_date required')
        }
        result = await getPpeRollforward(auth.organizationId, args.start_date, args.end_date)
        break

      case 'register_fixed_asset':
        result = await registerFixedAsset(auth.organizationId, args, auth.userId)
        break

      case 'run_depreciation':
        if (!args?.period_start) throw new Error('period_start required')
        result = await runDepreciation(auth.organizationId, args.period_start, auth.userId)
        break

      case 'dispose_fixed_asset':
        if (!args?.asset_id) throw new Error('asset_id required')
        if (!args?.disposal_date) throw new Error('disposal_date required')
        result = await disposeFixedAsset(auth.organizationId, args, auth.userId)
        break

      default:
        throw new Error(`Unknown tool: ${name}`)
    }

    return {
      jsonrpc: '2.0',
      id: mcpRequest.id,
      result: {
        content: [
          {
            type: 'text',
            text: JSON.stringify(result, null, 2),
          },
        ],
      },
    }
  } catch (error: any) {
    return {
      jsonrpc: '2.0',
      id: mcpRequest.id,
      error: {
        code: -32000,
        message: error.message,
      },
    }
  }
}
