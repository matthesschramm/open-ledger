-- Per-company invoice email identity
-- Add columns for controlling invoice email sender identity per organization

-- Add invoice sender email fields to organizations
alter table organizations add column if not exists invoice_from_email text;
alter table organizations add column if not exists invoice_reply_to_email text;

comment on column organizations.invoice_from_email is 'Override From email for invoice sends (if null, uses platform default)';
comment on column organizations.invoice_reply_to_email is 'Reply-To email for invoice sends (typically org contact/billing email)';
