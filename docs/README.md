# Open Ledger Documentation

## Architecture

Open Ledger is built as a monolithic Next.js application with the following key components:

### Technology Stack

- **Framework**: Next.js 16 (App Router)
- **Language**: TypeScript
- **Database**: Supabase (PostgreSQL)
- **UI**: Tailwind CSS + shadcn/ui
- **Package Manager**: Bun

### Directory Structure

```
app/
  (auth)/         # Authentication routes (login, forgot password)
  (app)/          # Main application routes
    /             # Dashboard
    /accounts     # Chart of accounts management
    /journals     # Journal entries
    /contacts     # Customer and vendor management
    /bills        # Bill tracking
    /cash         # Cash management
    /reports      # Financial reports
    /settings     # System settings
  api/            # API endpoints

components/
  ui/             # shadcn/ui components
  app/            # Application-specific components

lib/
  supabase/       # Supabase client utilities
  auth/           # Authentication utilities
  actions/        # Server actions
  validators/     # Input validation
  utils/          # Shared utilities

docs/             # Documentation
supabase/         # Database migrations and schemas
types/            # TypeScript type definitions
```

## Development

### Getting Started

1. Install dependencies:
   ```bash
   bun install
   ```

2. Set up environment variables:
   ```bash
   cp .env.example .env.local
   ```

3. Run the development server:
   ```bash
   bun dev
   ```

### Phase 1 (Current)

Phase 1 focuses on the scaffold and app shell:
- ✅ Project setup with Next.js, TypeScript, Tailwind, shadcn/ui
- ✅ Supabase client configuration
- ✅ Authentication shell (login, forgot password)
- ✅ App navigation and layout
- ✅ Placeholder pages for all MVP routes
- ❌ Real database schema (out of scope)
- ❌ Journal engine (out of scope)
- ❌ MCP tools (out of scope)
- ❌ Integrations (out of scope)

## API Documentation

See [API.md](./API.md) for REST API documentation and [MCP.md](./MCP.md) for Model Context Protocol documentation.

## Features

Open Ledger includes:
- ✅ Chart of accounts management
- ✅ Journal entry engine with posting controls
- ✅ Double-entry accounting with automatic balance validation
- ✅ Period close controls and audit trail
- ✅ Accounts Payable (vendor bills)
- ✅ Accounts Receivable (customer invoices)
- ✅ Fixed asset register with depreciation
- ✅ Financial reports (P&L, Balance Sheet, Trial Balance, etc.)
- ✅ Multi-organization support
- ✅ REST API and MCP server for AI agents
- ✅ Journal supporting documents (PDF/image attachments)

## License

MIT License - See LICENSE file for details
