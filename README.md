# Open Ledger

Open-source double-entry accounting for small companies. You and your bookkeeper use the web app, and AI agents use the REST API and MCP server. Both work on the same books.

Open Ledger is early-stage software. Read [Project status and limitations](#project-status-and-limitations) before you rely on it for real books.

## What it does

**Home**
- Cash position, a profit and loss summary, bills that are overdue or due soon, and quick links to the next task.

**Journals**
- Manual double-entry journals. Save as a draft, then post.
- Delete a draft you no longer need. Posted journals can't be edited or deleted.
- Reverse a posted journal to correct it. The original and the reversal both stay on the books.
- Attach supporting documents (PDFs and images) to a journal.

**Chart of accounts**
- Each new company starts with a standard chart of accounts you can extend.
- Each account has its own ledger with a running balance.
- System accounts, such as accounts payable and retained earnings, can't be archived, retyped or deleted.

**Bills (accounts payable)**
- Enter vendor bills, post them, and record payments.
- Voiding a paid bill reverses the expense and moves the amount already paid to a supplier credit. You can apply that credit to another bill or record a refund.

**Invoices (accounts receivable)**
- Quotes and invoices for customer contacts. Quotes never post.
- Email an invoice to the customer with a PDF attached, send payment reminders, and download the PDF.
- Record receipts, including partial payments, plus credit notes and write-offs.
- Voiding an invoice that has receipts works like voiding a bill. The revenue is reversed and the amount already received becomes a customer credit you can apply or refund.

**Cash**
- A register for each cash account.

**Contacts**
- Customers, vendors, parent companies and other contacts. Only customers can be invoiced.

**Fixed assets**
- A fixed asset register. You can capitalize purchases, run monthly straight-line depreciation and record disposals.
- Purchases below the company's capitalization threshold (default $1,000, set per company) are expensed.

**Reports**
- Trial balance, profit and loss, balance sheet, cash movement, AR aging, AP aging, account ledger with running balance, and fixed asset (PPE) rollforward.
- Every report can be exported to CSV.

**Controls**
- Accounting periods by fiscal month, each one Open, Soft-closed or Locked. When a month is soft-closed, only owners can post to it. Nobody can post to a locked month.
- An audit trail of who did what, under Settings.
- Roles: owner, bookkeeper and read-only.
- Team invites by email.
- A time zone for each company.

**More than one company**
- One login can belong to several companies. Use the company switcher to move between them. Each company's data is kept separate.

**For agents and integrations**
- A REST API at `/api/v1` and an MCP server at `/api/mcp`, both using API keys.
- Public documentation at `/docs` on your deployment. The same text is at `/docs.md` and `/llms.txt`.

## The accounting model

- **Double-entry.** Every journal has at least two lines and its debits must equal its credits. If it doesn't balance, it won't post.
- **Integer cents.** Amounts are stored as whole cents, never floating-point numbers.
- **Drafts stay off the reports.** Only posted journals (and reversed ones, with their reversal) affect balances.
- **Posted journals are immutable.** To fix a posted journal, reverse it and post a corrected one. Reports keep both the original and its reversal, so the history is visible and they net to zero.
- **Locked months stay locked.** Once a month is locked, nothing can post into it, including reversals and voids. You need to pick a date in an open month.
- **Posting dates don't move.** Changing a company's time zone doesn't change the date of any journal. It only changes how timestamps are shown and which date counts as "today" for new entries.
- **Subledgers post through the ledger.** Bills, invoices, receipts, credits, write-offs and depreciation all create ordinary journals. Reports are built from those journals.

## Stack

- [Bun](https://bun.sh) for package management and scripts
- [Next.js](https://nextjs.org) App Router, with TypeScript
- [Tailwind CSS](https://tailwindcss.com) and [shadcn/ui](https://ui.shadcn.com)
- [Supabase](https://supabase.com) for Postgres, auth, storage and row-level security. Posting rules are enforced in the database.
- [Resend](https://resend.com) for invoice and reminder emails (optional)
- Built to run on [Vercel](https://vercel.com)

## Getting started locally

### Prerequisites

- Bun 1.4 or later
- Node.js 20 or later (used by Next.js)
- The [Supabase CLI](https://supabase.com/docs/guides/cli)
- Docker Desktop or Podman, to run Supabase locally (not needed if you use a hosted Supabase project)

### 1. Install

```bash
git clone https://github.com/matthesschramm/open-ledger.git
cd open-ledger
bun install
```

### 2. Start Supabase

**Option A: local Supabase**

```bash
supabase start
```

This command applies every migration in `supabase/migrations` and starts with an empty database. To load a fictional demo company called Acme Corp, set `enabled = true` under `[db.seed]` in `supabase/config.toml` before you start (the seed is `supabase/seeds/acme_seed.sql`). To rebuild the database from scratch, run:

```bash
supabase db reset
```

When `supabase start` finishes, it prints the local API URL, anon key and service role key. You'll need them in the next step.

**Option B: a hosted Supabase project**

Create a project at [supabase.com](https://supabase.com). Then link the project and push the migrations:

```bash
supabase link --project-ref your-project-ref
supabase db push --include-all
```

`scripts/apply-migrations.sh` runs the same two commands for you. It reads `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_DB_PASSWORD` from the environment.

### 3. Configure environment variables

```bash
cp .env.example .env.local
```

| Variable | Required | Example | What it's for |
| --- | --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Yes | `https://your-project.supabase.co` (or `http://127.0.0.1:54321` locally) | Your Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Yes | `your-anon-key` | Public anon key, used by the browser and for signed-in requests |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes, for the API, MCP, attachments and invoice email | `your-service-role-key` | Server-side key for API-key requests. Never expose it to the browser or commit it |
| `NEXT_PUBLIC_APP_URL` | Recommended in production | `https://ledger.example.com` | Public URL of your deployment, used in invite and password emails and as a fallback in `/docs` |
| `RESEND_API_KEY` | Only for invoice email | `re_your_key` | Sends invoices and reminders through Resend |
| `RESEND_PLATFORM_FROM` | Only for invoice email | `invoices@mail.example.com` | Default From address for invoice emails. A company can set its own address in Settings |
| `RESEND_FROM_EMAIL` | No | `invoices@mail.example.com` | Older name for `RESEND_PLATFORM_FROM`, kept as a fallback |
| `SUPABASE_DB_PASSWORD` | Only for `scripts/apply-migrations.sh` | `your-database-password` | Database password used to link the Supabase CLI to a hosted project |

Keep `.env.local` out of version control. It's already in `.gitignore`.

### 4. Run the app

```bash
bun dev
```

Open http://localhost:3000 and sign up. The first user becomes the owner of a new company with a default chart of accounts. If you loaded the demo seed, you can also look through the Acme Corp books.

### Tests

```bash
bun test                 # unit tests
./supabase/verify.sh     # with the demo seed loaded, checks that the trial balance and balance sheet balance
```

## Using the API and MCP

Each deployment publishes its own reference at `/docs`, with no login required. Start there.

The short version:

1. An owner creates an API key under **Settings → API Keys**. The key is shown only once.
2. Each key has permission bits. **read** lets it list and get records. **write** (`read_write`) lets it create drafts, contacts, accounts, bills and invoices. **post** (`can_post`) lets it post and reverse journals, post bills and invoices, record payments, receipts, credits and write-offs, and run depreciation. New keys are read-only.
3. Send the key as `Authorization: Bearer <key>`.
4. Agents connect to the MCP server at `https://your-deployment/api/mcp`, which uses JSON-RPC over HTTP. Scripts call the REST API at `https://your-deployment/api/v1`.

```json
{
  "mcpServers": {
    "open-ledger": {
      "url": "https://your-deployment/api/mcp",
      "headers": { "Authorization": "Bearer YOUR_API_KEY" }
    }
  }
}
```

The API follows the same rules as the web app. Amounts are in integer cents, and a key with post permission still can't post into a locked month. Refunds and credit applications accept an `Idempotency-Key` header, which must be a UUID (anything else gets a 400). Send one so a retried request isn't applied twice. Locking periods, managing users and exporting CSV are only available in the web app.

## Deploying

The supported setup is Vercel for the app and a hosted Supabase project for the database.

1. Create a Supabase project and push the migrations, as in Option B above.
2. In Supabase, open **Authentication → URL Configuration**. Set the Site URL to your app's URL and add `https://your-domain/set-password` and `https://your-domain/auth/callback` to the allowed redirect URLs.
3. Import the repository into Vercel. The framework preset is Next.js, and Vercel picks up Bun from `bun.lock`.
4. Add the environment variables from the table above in Vercel. Set `NEXT_PUBLIC_APP_URL` to your production URL.
5. To send invoice emails, verify a sending domain in Resend and set `RESEND_PLATFORM_FROM` to an address on that domain. Without these settings, the app still works but the Send invoice and Send reminder actions won't run.
6. Supabase sends invite and password emails. For production, configure custom SMTP in Supabase so these emails come from your own domain.

## Project status and limitations

Open Ledger is early-stage. The core ledger, AP, AR, fixed assets and reports work, but the project is young and the schema may still change.

What it doesn't do:

- **No bank feeds or bank reconciliation.** You record cash movements yourself, or an agent records them through the API.
- **No tax preparation, e-filing or payments.** Recording a bill payment never moves money. It records a payment you already made somewhere else.
- **No consolidation across companies.** Each company keeps its own books, and there are no group or consolidated reports.
- **One currency per company.** There are no foreign-currency transactions or revaluation.
- **US defaults.** New companies default to USD, a US-style chart of accounts and US date formats.
- **Depreciation re-runs have a known gap.** If you need to correct depreciation for a month that has already been run, check the results carefully.

Open Ledger is bookkeeping software. It isn't tax, legal or accounting advice. Have a qualified accountant review your books.

## Contributing and security

- Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
- Please report security problems privately, as described in [SECURITY.md](SECURITY.md), and not in public issues.
- Never include real API keys, service role keys or company data in issues, pull requests or seed files. Use placeholders such as `you@example.com`.

## License

[MIT](LICENSE)
