-- Phase 7: REST API and MCP Server
-- Add API key permissions, idempotency keys, and API audit logging

-- ============================================================================
-- API KEYS: Add permission columns
-- ============================================================================

-- Add permission columns to api_keys
alter table api_keys add column if not exists can_read boolean not null default true;
alter table api_keys add column if not exists can_write boolean not null default false;
alter table api_keys add column if not exists can_post boolean not null default false;

comment on column api_keys.can_read is 'Can read data (list, get operations)';
comment on column api_keys.can_write is 'Can create/update drafts (read_write role equivalent)';
comment on column api_keys.can_post is 'Can post/reverse journals (can_post permission)';

-- Index for active keys lookup
create index if not exists api_keys_active_idx on api_keys(organization_id, is_active) where is_active = true;

-- ============================================================================
-- IDEMPOTENCY KEYS
-- ============================================================================

create table if not exists idempotency_keys (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  idempotency_key text not null,
  request_method text not null,
  request_path text not null,
  response_status int not null,
  response_body jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  unique(organization_id, idempotency_key)
);

create index idempotency_keys_organization_id_idx on idempotency_keys(organization_id);
create index idempotency_keys_expires_at_idx on idempotency_keys(expires_at);

comment on table idempotency_keys is 'Stores idempotent request results for 24 hours to prevent duplicate operations';

-- ============================================================================
-- API AUDIT EVENTS
-- ============================================================================

create table if not exists api_audit_events (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  api_key_id uuid not null references api_keys(id) on delete cascade,
  method text not null,
  path text not null,
  status_code int not null,
  request_id text,
  idempotency_key text,
  created_at timestamptz not null default now()
);

create index api_audit_events_organization_id_idx on api_audit_events(organization_id);
create index api_audit_events_api_key_id_idx on api_audit_events(api_key_id);
create index api_audit_events_created_at_idx on api_audit_events(organization_id, created_at desc);

comment on table api_audit_events is 'Audit log for all API key usage (REST and MCP)';

-- ============================================================================
-- CLEANUP FUNCTION FOR EXPIRED IDEMPOTENCY KEYS
-- ============================================================================

create or replace function cleanup_expired_idempotency_keys()
returns int
language plpgsql
security definer
as $$
declare
  v_deleted int;
begin
  delete from idempotency_keys
  where expires_at < now();
  
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function cleanup_expired_idempotency_keys is 'Deletes expired idempotency keys (run periodically via cron)';

-- ============================================================================
-- UPDATE LAST_USED_AT FUNCTION
-- ============================================================================

create or replace function update_api_key_last_used(p_api_key_id uuid)
returns void
language sql
security definer
as $$
  update api_keys
  set last_used_at = now()
  where id = p_api_key_id;
$$;

comment on function update_api_key_last_used is 'Updates last_used_at timestamp for an API key';

-- ============================================================================
-- RLS POLICIES FOR NEW TABLES
-- ============================================================================

alter table idempotency_keys enable row level security;
alter table api_audit_events enable row level security;

-- Idempotency keys are managed by the API server only (no direct user access)
-- No policies needed - accessed via security definer functions only

-- API audit events: Admin+ can view
create policy "Admin+ can view api audit events"
  on api_audit_events for select
  using (organization_id = current_org_id() and has_role('admin'));
