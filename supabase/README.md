# Supabase

Open Ledger database schema, RPCs, and seed data for Supabase.

## Structure

```
supabase/
  migrations/          # SQL migration files (schema, RPCs, views)
  seeds/              # Seed data files
  functions/          # Edge Functions (future)
  config.toml         # Supabase configuration
  verify.sh           # Verification script
```

## Migrations

1. `20260826000001_init_schema.sql` - Core schema (tables, types, indexes, constraints)
2. `20260826000002_rpc_functions.sql` - RPC functions (post_journal, reverse_journal, lock_period, void_bill)
3. `20260826000003_report_views.sql` - Report views and functions (TB, BS, P&L, cash movement, AP aging, ledger)
4. `20260826000004_rls_helpers_and_policies.sql` - RLS helpers (current_org_id, current_role) and policies for all tables
5. `20260826000005_rpc_with_roles.sql` - Updated RPCs with role enforcement and first-user setup trigger
6. `20260826000006_coa_guards.sql` - CoA guard triggers (system accounts, type changes, is_cash rules)
7. `20260826000007_phase7_api.sql` - API keys table and key-based auth support
8. `20260826000008_fix_postgres_compatibility.sql` - **Critical fixes for real Postgres compatibility**

### Migration 08: Postgres Compatibility Fixes

This migration is **idempotent** and safe to apply on any Postgres database, whether local or cloud. It fixes three SQL compatibility issues that prevent the schema from working on real Postgres (both Supabase Cloud and managed Postgres):

**Fix 1: Reserved Keyword `current_role`**
- Postgres has a built-in `current_role` keyword
- Solution: Quote the function name as `"current_role"()` everywhere
- Recreates the helper function and updates all callers (has_role, unlock_period RPC)

**Fix 2: RLS Policies with NEW in USING Clause**
- RLS policies cannot reference NEW (the updated row) in the USING clause
- Solution: Split policies into separate USING (old row check) and WITH CHECK (new row validation)
- Affects: `memberships` UPDATE policy (last owner guard), `journals` UPDATE policy (draft-only guard)

**Fix 3: Type Mismatch in audit_events**
- `audit_events.actor_id` is `uuid`, but was compared to `auth.uid()::text`
- Solution: Compare as uuid: `actor_id = auth.uid()` (no text cast)
- Fixes: bookkeeper audit event policy

**When to Apply:**
- Always include this migration when setting up a new database
- Safe to re-run on databases that already have earlier migrations
- Essential for Supabase Cloud or any managed Postgres instance

**Testing:**
After applying migration 08, test with `supabase db reset` (local) or `supabase db push` (cloud). All migrations should apply cleanly without errors.

## Auth & RLS (Phase 4)

### Authentication Flow

**First User Signup:**
1. User signs up with email + password via `/auth/sign-up`
2. Supabase Auth creates the user in `auth.users`
3. `handle_new_user()` trigger fires automatically:
   - Creates a new organization (named after user email or provided company name)
   - Adds user as the **owner** (first membership)
4. User is redirected to sign in and can access the app

**Subsequent Users:**
- Invited by owner/admin through Settings > Users
- Receive invitation email (future: actual email sending)
- Sign up with invitation link
- Automatically added to the organization with invited role

### Roles & Permissions

**Role Hierarchy:**
- `owner` - Full access. Transfer ownership, unlock periods, issue post-enabled API keys
- `admin` - Manage users and keys, lock periods. Cannot unlock periods or remove last owner
- `bookkeeper` - Draft/post/reverse journals (open periods), bills, contacts. Cannot manage users or lock periods
- `read_only` - View and export only. No mutations

**RLS Enforcement:**
- All business tables have RLS enabled (default deny)
- `current_org_id()` and `current_role()` helpers provide multi-tenant isolation
- Cross-org data access is blocked by RLS policies
- Role-based permissions enforced at both RLS policy and RPC level

**Key Guards:**
- read_only cannot post journals
- bookkeeper cannot lock periods or manage users
- bookkeeper cannot update posted journals (only Draft status)
- Posted journals can only be modified via `reverse_journal()` RPC
- System accounts cannot be archived or have type changed
- Accounts with posted lines cannot change type
- Cannot remove the last owner

### Settings Pages

**Settings > Users** (`/settings/users`):
- Invite new users (owner/admin)
- Change user roles (owner/admin)
- Remove users (owner/admin, cannot remove last owner)
- Bookkeeper and read_only: view-only

**Settings > API Keys** (`/settings/api-keys`):
- Create API keys (owner/admin)
- Revoke API keys (owner/admin)
- Keys shown once after creation
- Default: `can_post = false` (read-only)
- Owner can issue `can_post = true` keys

**Settings > Periods** (`/settings/periods`):
- View all accounting periods (all roles)
- Lock periods (admin+)
- Unlock periods (owner only)
- Bookkeeper: view-only

### Security Notes

- **NEVER commit `SUPABASE_SERVICE_ROLE_KEY`** - server-side only, not in client or public repos
- Anon key (`NEXT_PUBLIC_SUPABASE_ANON_KEY`) is public and safe to commit
- RLS policies enforce all access control
- API keys are hashed before storage (plaintext shown once)
- Storage policies enforce org-scoped paths: `org/{organization_id}/**`

### Testing RLS

Run RLS verification tests after seeding:

```bash
# Run RLS tests (requires acme_seed.sql + rls_test_seed.sql)
psql "$DB_URL" < supabase/tests/rls_verification.sql
```

**Four Proofs:**
1. read_only cannot `post_journal()`
2. bookkeeper cannot `lock_period()` or manage users
3. Second org cannot select first org's journals (cross-org isolation)
4. Posted journal cannot be updated except via `reverse_journal()`

See `supabase/tests/rls_verification.sql` for complete test suite.

## Seed Data

Open Ledger supports two seed data options:

1. **Empty Organization (Default)**: No seed data, clean slate for your own books
2. **Acme Corp (Optional)**: Public demo organization with sample transactions

### Empty Organization (Recommended for Production Use)

By default, `supabase db reset` will create an **empty database** with no seed data. The first user who signs up will automatically:
- Create a new organization (named after their email)
- Become the **owner** (first membership)
- Start with an empty chart of accounts, no journals, no contacts

This is the recommended path for production use and newcomers setting up their own books.

### Acme Corp Seed (Optional Demo Data)

The public Acme Corp seed (`seeds/acme_seed.sql`) provides a complete demo organization with:
- Full chart of accounts (US-style, locked)
- Accounting periods (July 2026 locked, August 2026 open)
- Sample journals (posted and reversed pairs)
- Bills, contacts, and cash accounts
- Parent funding via Dr 1010 / Cr 3100 APIC (proper equity capitalization)
- All non-draft journals appear on reports (Posted + Reversed pairs net to zero)

**To load the Acme seed:**

1. Edit `supabase/config.toml` and update the `[db.seed]` section:

```toml
[db.seed]
enabled = true
sql_paths = ["./seeds/acme_seed.sql"]
```

2. Reset the database:

```bash
supabase db reset
```

**Important:** The Acme seed is generic demo data only. Internal seed data with company-specific information (EIN, bank accounts, officers, live project references, service-role keys, or internal hostnames) must **never** be committed to this public repository. For internal use, create a separate seed file outside the git tree or use environment-specific configuration.

### Seed File Guidelines

- `seeds/acme_seed.sql` - Public Acme Corp seed (generic, no company secrets)
- Internal seeds - Environment/config-specific, **must not be committed**

This is a single MIT-licensed repository. Internal vs public seed data is controlled via environment/config, not by forking.

## Local Development

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) or [Podman](https://podman.io/)
- [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started)

### Setup (Empty Organization)

The default setup creates an **empty organization** with no seed data. This is recommended for first-run local development:

```bash
# Start local Supabase stack (Postgres, PostgREST, Auth, etc.)
supabase start

# This will:
# - Apply all migrations in order (including migration 08 compatibility fixes)
# - Start services on localhost
# - Output connection details (API URL, anon key, service role key)
```

Copy the connection details to your `.env.local`:

```bash
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=<your-local-anon-key>
```

**First Run:**
- Visit `http://localhost:3000/login` in your Next.js app
- Sign up with an email and password
- The first user becomes the **owner** of a new empty organization
- Home page shows "No books yet" with prompts to add a cash account and create an opening journal

### Setup (Acme Corp Seed)

To load the public Acme Corp demo data instead:

1. Edit `supabase/config.toml` and update the `[db.seed]` section:

```toml
[db.seed]
enabled = true
sql_paths = ["./seeds/acme_seed.sql"]
```

2. Reset the database:

```bash
supabase db reset
```

This will:
- Drop and recreate the database
- Apply all migrations (including migration 08)
- Load the Acme Corp seed data

### Reset Database

To reset and re-apply migrations (with or without seed data):

```bash
# Reset with current seed config (empty or Acme)
supabase db reset

# This runs:
# 1. Drops and recreates the database
# 2. Applies all migrations
# 3. Runs seed files (if enabled in config.toml)
```

### Verification

After `supabase db reset`, run the verification script to ensure accounting integrity:

```bash
./supabase/verify.sh
```

This script verifies:
1. **Trial Balance** is balanced (total debits = total credits)
2. **Reversal Pair** (j0005 + j0006) nets to zero on all accounts
3. **Balance Sheet** balances (Assets = Liabilities + Equity)

### Manual Queries

```bash
# Get database connection string
supabase status

# Connect with psql
psql "postgres://postgres:postgres@localhost:54322/postgres"
```

Example queries:

```sql
-- Trial Balance
SELECT * FROM get_trial_balance('00000000-0000-0000-0000-000000000001', '2026-08-31');

-- Balance Sheet
SELECT * FROM get_balance_sheet('00000000-0000-0000-0000-000000000001', '2026-08-31');

-- Profit & Loss
SELECT * FROM get_profit_and_loss('00000000-0000-0000-0000-000000000001', '2026-08-01', '2026-08-31');

-- Post a journal
SELECT post_journal('j0009');  -- Post the draft journal

-- Reverse a journal
SELECT reverse_journal('j0001', '2026-08-31', 'Correcting entry');
```

## Schema Design

### Money

All monetary values are stored as **bigint cents** (USD). Never use float or numeric for money.

Example: $1,234.56 is stored as `123456` cents.

### Dates & Times

- **Books dates**: `date` type (e.g., `entry_date`, `bill_date`)
- **Audit timestamps**: `timestamptz` type (e.g., `created_at`, `posted_at`)
- **Timezone assumption**: `America/New_York`

### Journal Status

- `Draft` - Not yet posted, can be edited, never appears on reports
- `Posted` - Finalized, immutable, appears on all reports
- `Reversed` - Original journal that was reversed, still appears on reports (reversal pair nets to zero)

### Reports

All reports include **non-draft journals**: `Posted` entries AND `Reversed` originals. Drafts never appear.

### System Accounts

Certain accounts are marked `is_system = true`:
- `2000 Accounts payable` (AP)
- `3000 Common stock`
- `3100 Additional paid-in capital` (APIC)
- `3200 Retained earnings` (system-calculated)
- `3900 Opening balance equity`

System accounts cannot be archived or have their type changed.

### Accounting Guards

RPCs enforce:
- **post_journal**: Rejects unbalanced entries, < 2 lines, header accounts, locked periods
- **reverse_journal**: Creates reversing entry, marks original as Reversed, posts through same validations
- **lock_period**: Prevents posting/reversing in locked periods
- **void_bill**: Reverses recognition journal and marks bill void

## Storage

Attachments are stored in a private Supabase storage bucket with paths:

```
org/{organization_id}/journals/{journal_id}/{filename}
org/{organization_id}/bills/{bill_id}/{filename}
```

RLS policies (Phase 4) will enforce access control.

## Phase 3 Complete

- ✅ Schema (organizations, accounts, journals, bills, contacts, etc.)
- ✅ RPCs (post_journal, reverse_journal, lock_period, void_bill)
- ✅ Report views (TB, BS, P&L, cash movement, AP aging, ledger)
- ✅ Public Acme seed with balanced books
- ✅ Verification script (TB balance, reversal pair, BS balance)

Phase 4 (Auth/RLS UI) and Phase 5 (Live CRUD) are not yet implemented.
