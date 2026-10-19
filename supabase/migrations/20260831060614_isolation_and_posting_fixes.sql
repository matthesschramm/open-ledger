-- Isolation, posting, invitation, and document-lock fixes.
-- Drops fictional invoice overloads; restores reverse_journal guards;
-- binds SECURITY DEFINER reports to the caller's org; consumes invitations.

-- ============================================================================
-- Impersonation: service_role only
-- ============================================================================

create or replace function assume_request_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then
    return;
  end if;

  if auth.uid() is not null then
    if auth.uid() is distinct from p_user_id then
      raise exception 'Cannot impersonate another user';
    end if;
    return;
  end if;

  if coalesce(auth.role(), '') is distinct from 'service_role' then
    raise exception 'Cannot impersonate';
  end if;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', p_user_id::text, 'role', 'authenticated')::text,
    true
  );
end;
$$;

revoke all on function assume_request_user(uuid) from public;
revoke all on function assume_request_user(uuid) from authenticated;
grant execute on function assume_request_user(uuid) to service_role;

create or replace function assert_caller_org(p_organization_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.role() = 'authenticated'
     and current_org_id() is distinct from p_organization_id then
    raise exception 'Permission denied';
  end if;
end;
$$;

revoke all on function assert_caller_org(uuid) from public;
grant execute on function assert_caller_org(uuid) to authenticated, service_role;

-- ============================================================================
-- Drop fictional invoice overloads (wrong schema)
-- ============================================================================

drop function if exists post_invoice(uuid, uuid);
drop function if exists record_receipt(uuid, date, bigint, uuid, text, uuid);
drop function if exists issue_credit_note(uuid, date, bigint, text, uuid);
drop function if exists write_off_invoice(uuid, date, bigint, text, uuid);
drop function if exists send_invoice_reminder(uuid, uuid);

-- Real-schema wrappers. No default on p_user_id so PostgREST
-- can still pick the one-arg UI functions without ambiguity.

create or replace function post_invoice(p_invoice_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assume_request_user(p_user_id);
  return post_invoice(p_invoice_id);
end;
$$;

create or replace function record_receipt(
  p_invoice_id uuid,
  p_receipt_date date,
  p_amount_cents bigint,
  p_cash_account_id uuid,
  p_notes text,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assume_request_user(p_user_id);
  return record_receipt(
    p_invoice_id,
    p_receipt_date,
    p_amount_cents,
    p_cash_account_id,
    p_notes
  );
end;
$$;

create or replace function issue_credit_note(
  p_invoice_id uuid,
  p_credit_date date,
  p_amount_cents bigint,
  p_reason text,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assume_request_user(p_user_id);
  return issue_credit_note(
    p_invoice_id,
    p_credit_date,
    p_amount_cents,
    p_reason
  );
end;
$$;

create or replace function write_off_invoice(
  p_invoice_id uuid,
  p_write_off_date date,
  p_amount_cents bigint,
  p_reason text,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assume_request_user(p_user_id);
  return write_off_invoice(
    p_invoice_id,
    p_write_off_date,
    p_amount_cents,
    p_reason
  );
end;
$$;

create or replace function send_invoice_reminder(p_invoice_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assume_request_user(p_user_id);
  return send_invoice_reminder(p_invoice_id);
end;
$$;

grant execute on function post_invoice(uuid, uuid) to authenticated, service_role;
grant execute on function record_receipt(uuid, date, bigint, uuid, text, uuid) to authenticated, service_role;
grant execute on function issue_credit_note(uuid, date, bigint, text, uuid) to authenticated, service_role;
grant execute on function write_off_invoice(uuid, date, bigint, text, uuid) to authenticated, service_role;
grant execute on function send_invoice_reminder(uuid, uuid) to authenticated, service_role;

-- ============================================================================
-- post_journal: optional p_user_id, lock lines, reject foreign accounts
-- ============================================================================

drop function if exists post_journal(uuid);

create function post_journal(
  p_journal_id uuid,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_journal journals;
  v_total_debit_cents bigint;
  v_total_credit_cents bigint;
  v_line_count int;
  v_has_header_accounts boolean;
  v_foreign_account boolean;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_can_post boolean;
  v_period_info jsonb;
  v_rows_updated integer;
begin
  perform assume_request_user(p_user_id);

  v_current_user_id := auth.uid();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select * into v_journal
  from journals
  where id = p_journal_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal not found'
    );
  end if;

  v_organization_id := v_journal.organization_id;

  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  v_current_role := "current_role"();

  if v_journal.status = 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal already posted'
    );
  end if;

  if v_journal.status = 'Reversed' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a reversed journal'
    );
  end if;

  perform 1
  from journal_lines
  where journal_id = p_journal_id
  for update;

  select count(*) into v_line_count
  from journal_lines
  where journal_id = p_journal_id;

  if v_line_count < 2 then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal must have at least 2 lines'
    );
  end if;

  select
    coalesce(sum(debit_cents), 0),
    coalesce(sum(credit_cents), 0)
  into v_total_debit_cents, v_total_credit_cents
  from journal_lines
  where journal_id = p_journal_id;

  if v_total_debit_cents != v_total_credit_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal must balance: debits must equal credits'
    );
  end if;

  select exists(
    select 1
    from journal_lines jl
    join accounts a on a.id = jl.account_id
    where jl.journal_id = p_journal_id
      and a.is_header = true
  ) into v_has_header_accounts;

  if v_has_header_accounts then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post to header accounts'
    );
  end if;

  select exists(
    select 1
    from journal_lines jl
    join accounts a on a.id = jl.account_id
    where jl.journal_id = p_journal_id
      and a.organization_id is distinct from v_organization_id
  ) into v_foreign_account;

  if v_foreign_account then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal lines must use accounts from the same organization'
    );
  end if;

  v_can_post := can_post_to_period(
    v_organization_id,
    v_journal.entry_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, v_journal.entry_date);

    if v_period_info is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Cannot post to this date'
      );
    end if;

    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot post journal with entry date %s: %s is %s. %s',
        to_char(v_journal.entry_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status',
        case
          when v_period_info->>'status' = 'Soft-closed' then 'Only the owner can post to a soft-closed month.'
          when v_period_info->>'status' = 'Locked' then 'No one can post to a locked month. Reopen the period in Settings → Periods first.'
          else ''
        end
      ),
      'period_name', v_period_info->>'period_name',
      'period_status', v_period_info->>'status'
    );
  end if;

  update journals
  set
    status = 'Posted',
    posted_at = now(),
    posted_by = v_current_user_id
  where id = p_journal_id
    and status = 'Draft';

  get diagnostics v_rows_updated = row_count;

  if v_rows_updated != 1 then
    return jsonb_build_object(
      'success', false,
      'error', 'Failed to post journal'
    );
  end if;

  perform log_audit_event(
    'journal',
    p_journal_id,
    'journal_posted',
    jsonb_build_object(
      'journal_number', v_journal.number,
      'entry_date', v_journal.entry_date,
      'description', v_journal.description,
      'source', v_journal.source
    )
  );

  return jsonb_build_object(
    'success', true,
    'journal_id', p_journal_id
  );
end;
$$;

grant execute on function post_journal(uuid, uuid) to authenticated, service_role;

-- ============================================================================
-- reverse_journal: restore auth/role/org guards
-- ============================================================================

drop function if exists reverse_journal(uuid, date, text);

create function reverse_journal(
  p_journal_id uuid,
  p_reversal_date date,
  p_reversal_description text default null,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_journal journals;
  v_reversal_journal_id uuid;
  v_reversal_number text;
  v_reversal_description text;
  v_line record;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_can_post boolean;
  v_period_info jsonb;
  v_rows_updated integer;
begin
  perform assume_request_user(p_user_id);

  v_current_user_id := auth.uid();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select * into v_journal
  from journals
  where id = p_journal_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal not found'
    );
  end if;

  v_organization_id := v_journal.organization_id;

  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  v_current_role := "current_role"();

  if v_journal.reversed_by_journal_id is not null then
    return jsonb_build_object(
      'success', false,
      'error', 'Journal already reversed'
    );
  end if;

  if v_journal.status != 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only reverse posted journals'
    );
  end if;

  v_can_post := can_post_to_period(
    v_organization_id,
    p_reversal_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_reversal_date);

    if v_period_info is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Cannot post reversal to this date'
      );
    end if;

    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot reverse with date %s: %s is %s. %s',
        to_char(p_reversal_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status',
        case
          when v_period_info->>'status' = 'Soft-closed' then 'Only the owner can post to a soft-closed month.'
          when v_period_info->>'status' = 'Locked' then 'No one can post to a locked month. Reopen the period in Settings → Periods first.'
          else ''
        end
      ),
      'period_name', v_period_info->>'period_name',
      'period_status', v_period_info->>'status'
    );
  end if;

  v_reversal_number := 'REV-' || v_journal.number;
  v_reversal_description := coalesce(p_reversal_description, 'REVERSAL: ' || v_journal.description);

  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    posted_at,
    posted_by,
    created_by,
    reverses_journal_id
  ) values (
    v_organization_id,
    v_reversal_number,
    p_reversal_date,
    v_reversal_description,
    'Posted',
    'reversal',
    now(),
    v_current_user_id,
    v_current_user_id,
    p_journal_id
  )
  returning id into v_reversal_journal_id;

  for v_line in
    select * from journal_lines
    where journal_id = p_journal_id
  loop
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_organization_id,
      v_reversal_journal_id,
      v_line.account_id,
      v_line.credit_cents,
      v_line.debit_cents,
      v_line.memo
    );
  end loop;

  update journals
  set
    status = 'Reversed',
    reversed_by_journal_id = v_reversal_journal_id
  where id = p_journal_id
    and status = 'Posted';

  get diagnostics v_rows_updated = row_count;

  if v_rows_updated != 1 then
    raise exception 'Failed to mark original journal as reversed';
  end if;

  perform log_audit_event(
    'journal',
    v_reversal_journal_id,
    'journal_posted',
    jsonb_build_object(
      'journal_number', v_reversal_number,
      'entry_date', p_reversal_date,
      'description', v_reversal_description,
      'source', 'reversal',
      'reverses_journal_id', p_journal_id,
      'reverses_journal_number', v_journal.number
    )
  );

  return jsonb_build_object(
    'success', true,
    'original_journal_id', p_journal_id,
    'reversal_journal_id', v_reversal_journal_id
  );
end;
$$;

grant execute on function reverse_journal(uuid, date, text, uuid) to authenticated, service_role;

-- ============================================================================
-- Reports: bind p_organization_id to the authenticated caller
-- ============================================================================

create or replace function get_trial_balance(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  account_id uuid,
  account_code text,
  account_name text,
  account_type account_type,
  debit_cents bigint,
  credit_cents bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform assert_caller_org(p_organization_id);

  return query
  with account_balances as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      a.is_header,
      coalesce(sum(jl.debit_cents), 0)::bigint as total_debit,
      coalesce(sum(jl.credit_cents), 0)::bigint as total_credit
    from public.accounts a
    left join public.journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join public.journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      and (j.id is null or (j.status in ('Posted', 'Reversed') and j.entry_date <= p_as_of_date))
    group by a.id, a.code, a.name, a.type, a.is_header
  )
  select
    ab.account_id,
    ab.account_code,
    ab.account_name,
    ab.account_type,
    case
      when (ab.total_debit - ab.total_credit) > 0 then (ab.total_debit - ab.total_credit)::bigint
      else 0::bigint
    end as debit_cents,
    case
      when (ab.total_debit - ab.total_credit) < 0 then (-(ab.total_debit - ab.total_credit))::bigint
      else 0::bigint
    end as credit_cents
  from account_balances ab
  where ab.total_debit != 0 or ab.total_credit != 0
  order by ab.account_code;
end;
$$;

create or replace function get_balance_sheet(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  section text,
  account_id uuid,
  account_code text,
  account_name text,
  account_type account_type,
  balance_cents bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform assert_caller_org(p_organization_id);

  return query
  with account_balances as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      a.is_header,
      (coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0))::bigint as signed_balance
    from public.accounts a
    left join public.journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join public.journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      and (j.id is null or (j.status in ('Posted', 'Reversed') and j.entry_date <= p_as_of_date))
    group by a.id, a.code, a.name, a.type, a.is_header
  ),
  revenue_expense_total as (
    select (-coalesce(sum(signed_balance), 0))::bigint as net_income
    from account_balances
    where account_type in ('Revenue', 'Expense')
  )
  select
    case
      when ab.account_type = 'Asset' then 'Assets'
      when ab.account_type = 'Liability' then 'Liabilities'
      when ab.account_type = 'Equity' then 'Equity'
    end as section,
    ab.account_id,
    ab.account_code,
    ab.account_name,
    ab.account_type,
    case
      when ab.account_type in ('Liability', 'Equity') then (-ab.signed_balance)::bigint
      else ab.signed_balance::bigint
    end as balance_cents
  from account_balances ab
  where ab.account_type in ('Asset', 'Liability', 'Equity')
    and ab.signed_balance != 0

  union all

  select
    'Equity' as section,
    null as account_id,
    'NI' as account_code,
    'Net Income (Current Period)' as account_name,
    'Equity'::account_type as account_type,
    net_income as balance_cents
  from revenue_expense_total
  where net_income != 0

  order by
    case section
      when 'Assets' then 1
      when 'Liabilities' then 2
      when 'Equity' then 3
    end,
    account_code;
end;
$$;

create or replace function get_profit_and_loss(
  p_organization_id uuid,
  p_start_date date,
  p_end_date date
)
returns table (
  section text,
  account_id uuid,
  account_code text,
  account_name text,
  account_type account_type,
  amount_cents bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform assert_caller_org(p_organization_id);

  return query
  with account_activity as (
    select
      a.id as account_id,
      a.code as account_code,
      a.name as account_name,
      a.type as account_type,
      (coalesce(sum(jl.debit_cents), 0) - coalesce(sum(jl.credit_cents), 0))::bigint as signed_amount
    from public.accounts a
    left join public.journal_lines jl on jl.account_id = a.id and jl.organization_id = p_organization_id
    left join public.journals j on j.id = jl.journal_id
    where a.organization_id = p_organization_id
      and a.is_active = true
      and a.type in ('Revenue', 'Expense')
      and (j.id is null or (
        j.status in ('Posted', 'Reversed')
        and j.entry_date between p_start_date and p_end_date
      ))
    group by a.id, a.code, a.name, a.type
  )
  select
    case
      when aa.account_type = 'Revenue' then 'Revenue'
      when aa.account_type = 'Expense' then 'Expenses'
    end as section,
    aa.account_id,
    aa.account_code,
    aa.account_name,
    aa.account_type,
    case
      when aa.account_type = 'Revenue' then (-aa.signed_amount)::bigint
      else aa.signed_amount::bigint
    end as amount_cents
  from account_activity aa
  where aa.signed_amount != 0
  order by
    case section
      when 'Revenue' then 1
      when 'Expenses' then 2
    end,
    account_code;
end;
$$;

drop function if exists get_ar_aging(uuid, date);

create function get_ar_aging(
  p_organization_id uuid,
  p_as_of_date date default current_date
)
returns table (
  invoice_id uuid,
  invoice_number text,
  customer_name text,
  invoice_date date,
  due_date date,
  amount_due_cents bigint,
  days_overdue int
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  perform assert_caller_org(p_organization_id);

  return query
  with invoice_receipts_as_of as (
    select
      ir.invoice_id,
      coalesce(sum(ir.amount_cents), 0) as received_as_of_cents
    from invoice_receipts ir
    where ir.organization_id = p_organization_id
      and ir.receipt_date <= p_as_of_date
    group by ir.invoice_id
  )
  select
    i.id as invoice_id,
    i.number as invoice_number,
    c.name as customer_name,
    i.invoice_date,
    i.due_date,
    (i.total_cents - coalesce(ira.received_as_of_cents, 0)) as amount_due_cents,
    case
      when i.due_date < p_as_of_date then (p_as_of_date - i.due_date)::int
      else 0
    end as days_overdue
  from invoices i
  join contacts c on c.id = i.customer_id
  left join invoice_receipts_as_of ira on ira.invoice_id = i.id
  where i.organization_id = p_organization_id
    and i.status in ('Posted', 'Paid')
    and i.invoice_date <= p_as_of_date
    and (i.total_cents - coalesce(ira.received_as_of_cents, 0)) > 0
  order by i.due_date nulls last, i.invoice_date;
end;
$$;

grant execute on function get_ar_aging(uuid, date) to authenticated, service_role;

create or replace function get_cash_movement(
  p_organization_id uuid,
  p_start_date date,
  p_end_date date
)
returns table (
  counter_account_id uuid,
  counter_account_code text,
  counter_account_name text,
  counter_account_type account_type,
  net_change_cents bigint
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
#variable_conflict use_column
begin
  perform assert_caller_org(p_organization_id);

  return query
  with cash_accounts as (
    select id
    from public.accounts
    where organization_id = p_organization_id
      and is_cash = true
      and is_active = true
  ),
  cash_lines as (
    select
      jl.journal_id,
      jl.account_id,
      jl.debit_cents,
      jl.credit_cents
    from public.journal_lines jl
    join public.journals j on j.id = jl.journal_id
    where jl.organization_id = p_organization_id
      and j.status in ('Posted', 'Reversed')
      and j.entry_date between p_start_date and p_end_date
      and (
        jl.account_id in (select id from cash_accounts)
        or jl.journal_id in (
          select journal_id
          from public.journal_lines
          where account_id in (select id from cash_accounts)
        )
      )
  )
  select
    a.id as counter_account_id,
    a.code as counter_account_code,
    a.name as counter_account_name,
    a.type as counter_account_type,
    (sum(
      case
        when cl.account_id not in (select id from cash_accounts) and cl.debit_cents > 0
          then -cl.debit_cents
        when cl.account_id not in (select id from cash_accounts) and cl.credit_cents > 0
          then cl.credit_cents
        else 0
      end
    ))::bigint as net_change_cents
  from cash_lines cl
  join public.accounts a on a.id = cl.account_id
  where cl.account_id not in (select id from cash_accounts)
  group by a.id, a.code, a.name, a.type
  having sum(
    case
      when cl.account_id not in (select id from cash_accounts) and cl.debit_cents > 0
        then -cl.debit_cents
      when cl.account_id not in (select id from cash_accounts) and cl.credit_cents > 0
        then cl.credit_cents
      else 0
    end
  ) != 0
  order by a.code;
end;
$$;

grant execute on function get_cash_movement(uuid, date, date) to authenticated, service_role;

-- ============================================================================
-- Invitations: consume on signup; add AR / bad-debt accounts
-- ============================================================================

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_org_name text;
  v_invite invitations;
begin
  if exists(select 1 from public.memberships where user_id = new.id) then
    return new;
  end if;

  select *
  into v_invite
  from public.invitations
  where lower(email) = lower(new.email)
    and status = 'pending'
    and expires_at > now()
  order by created_at desc
  limit 1;

  if found then
    insert into public.memberships (organization_id, user_id, role)
    values (v_invite.organization_id, new.id, v_invite.role);

    update public.invitations
    set status = 'accepted'
    where id = v_invite.id;

    return new;
  end if;

  v_org_name := coalesce(
    new.raw_user_meta_data->>'company_name',
    split_part(new.email, '@', 1) || '''s Organization'
  );

  insert into public.organizations (name, currency_code, timezone)
  values (v_org_name, 'USD', 'America/New_York')
  returning id into v_org_id;

  insert into public.memberships (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  insert into public.accounts (organization_id, code, name, type, category, is_header, is_cash, is_system, is_active) values
  (v_org_id, '1000', 'Cash', 'Asset', 'Cash', true, false, false, true),
  (v_org_id, '1010', 'Operating cash', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1020', 'Savings / reserves', 'Asset', 'Cash', false, true, false, true),
  (v_org_id, '1100', 'Accounts receivable', 'Asset', 'AR', false, false, true, true),
  (v_org_id, '1200', 'Prepaid expenses', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '1400', 'Due from parent', 'Asset', 'AR', false, false, false, true),
  (v_org_id, '1500', 'Computer and equipment', 'Asset', 'Other', false, false, false, true),
  (v_org_id, '2000', 'Accounts payable', 'Liability', 'AP', false, false, true, true),
  (v_org_id, '2100', 'Accrued expenses', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '2200', 'Due to parent', 'Liability', 'AP', false, false, false, true),
  (v_org_id, '2300', 'Credit cards', 'Liability', 'Other', false, false, false, true),
  (v_org_id, '3000', 'Common stock', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3100', 'Additional paid-in capital', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3200', 'Retained earnings', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '3900', 'Opening balance equity', 'Equity', 'Equity', false, false, true, true),
  (v_org_id, '4000', 'Revenue', 'Revenue', 'Revenue', true, false, false, true),
  (v_org_id, '4010', 'Product / service revenue', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '4100', 'Other income', 'Revenue', 'Revenue', false, false, false, true),
  (v_org_id, '5000', 'Operating expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '5010', 'Contractors and professional', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5020', 'Legal and formation', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5030', 'Software and subscriptions', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5040', 'Banking and payments', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5050', 'Travel', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5060', 'Insurance', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5070', 'Payroll and benefits', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5080', 'Office and admin', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5090', 'Tax expense', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '5110', 'Bad debt', 'Expense', 'Expense', false, false, false, true),
  (v_org_id, '6000', 'Other expenses', 'Expense', 'Expense', true, false, false, true),
  (v_org_id, '6100', 'FX and rounding', 'Expense', 'Expense', false, false, false, true);

  return new;
end;
$$;

comment on function handle_new_user is 'Joins a pending invitation when present; otherwise creates an org, owner membership, and US CoA';

-- ============================================================================
-- Posted documents: lock source fields
-- ============================================================================

drop policy if exists "Bookkeepers can update invoices" on invoices;
create policy "Bookkeepers can update draft invoices"
  on invoices for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and status in ('Draft', 'Quote')
  );

drop policy if exists "Bookkeepers can update invoice lines" on invoice_lines;
drop policy if exists "Bookkeepers can delete invoice lines" on invoice_lines;

create policy "Bookkeepers can update draft invoice lines"
  on invoice_lines for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and exists (
      select 1 from invoices i
      where i.id = invoice_id
        and i.status in ('Draft', 'Quote')
    )
  );

create policy "Bookkeepers can delete draft invoice lines"
  on invoice_lines for delete
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and exists (
      select 1 from invoices i
      where i.id = invoice_id
        and i.status in ('Draft', 'Quote')
    )
  );

drop policy if exists "Bookkeeper+ can update bill lines" on bill_lines;
drop policy if exists "Bookkeeper+ can delete bill lines" on bill_lines;

create policy "Bookkeeper+ can update draft bill lines"
  on bill_lines for update
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and exists (select 1 from bills b where b.id = bill_id and b.status = 'Draft')
  );

create policy "Bookkeeper+ can delete draft bill lines"
  on bill_lines for delete
  using (
    organization_id = current_org_id()
    and has_role('bookkeeper')
    and exists (select 1 from bills b where b.id = bill_id and b.status = 'Draft')
  );

create or replace function enforce_posted_invoice_source_lock()
returns trigger
language plpgsql
as $$
begin
  if old.status in ('Draft', 'Quote') then
    return new;
  end if;

  if new.number is distinct from old.number
     or new.customer_id is distinct from old.customer_id
     or new.invoice_date is distinct from old.invoice_date
     or new.due_date is distinct from old.due_date
     or new.total_cents is distinct from old.total_cents
     or new.notes is distinct from old.notes
     or new.organization_id is distinct from old.organization_id
     or new.created_by is distinct from old.created_by then
    raise exception 'Posted invoices cannot change source fields';
  end if;

  return new;
end;
$$;

drop trigger if exists invoices_source_lock on invoices;
create trigger invoices_source_lock
  before update on invoices
  for each row
  execute function enforce_posted_invoice_source_lock();

create or replace function enforce_posted_bill_source_lock()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'Draft' then
    return new;
  end if;

  if new.number is distinct from old.number
     or new.vendor_id is distinct from old.vendor_id
     or new.bill_date is distinct from old.bill_date
     or new.due_date is distinct from old.due_date
     or new.total_cents is distinct from old.total_cents
     or new.notes is distinct from old.notes
     or new.organization_id is distinct from old.organization_id
     or new.created_by is distinct from old.created_by then
    raise exception 'Posted bills cannot change source fields';
  end if;

  return new;
end;
$$;

drop trigger if exists bills_source_lock on bills;
create trigger bills_source_lock
  before update on bills
  for each row
  execute function enforce_posted_bill_source_lock();

-- ============================================================================
-- Composite FKs so lines cannot point at another org's account/contact
-- ============================================================================

alter table accounts
  add constraint accounts_id_organization_id_key unique (id, organization_id);

alter table contacts
  add constraint contacts_id_organization_id_key unique (id, organization_id);

alter table journal_lines drop constraint if exists journal_lines_account_id_fkey;
alter table journal_lines
  add constraint journal_lines_account_org_fkey
  foreign key (account_id, organization_id) references accounts (id, organization_id);

alter table bill_lines drop constraint if exists bill_lines_account_id_fkey;
alter table bill_lines
  add constraint bill_lines_account_org_fkey
  foreign key (account_id, organization_id) references accounts (id, organization_id);

alter table bills drop constraint if exists bills_vendor_id_fkey;
alter table bills
  add constraint bills_vendor_org_fkey
  foreign key (vendor_id, organization_id) references contacts (id, organization_id);

alter table invoice_lines drop constraint if exists invoice_lines_account_id_fkey;
alter table invoice_lines
  add constraint invoice_lines_account_org_fkey
  foreign key (account_id, organization_id) references accounts (id, organization_id);

alter table invoices drop constraint if exists invoices_customer_id_fkey;
alter table invoices
  add constraint invoices_customer_org_fkey
  foreign key (customer_id, organization_id) references contacts (id, organization_id);

-- Rollback invoice journals on post failure

create or replace function post_invoice(p_invoice_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_total_cents bigint;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_line record;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
  
  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Get invoice with lock
  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  -- Check membership and role (must be bookkeeper+)
  if not has_role('bookkeeper') or current_org_id() != v_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  v_current_role := "current_role"();

  -- Check if already posted
  if v_invoice.status = 'Posted' then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice already posted'
    );
  end if;

  -- Check if paid
  if v_invoice.status = 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a paid invoice'
    );
  end if;

  -- Check if void
  if v_invoice.status = 'Void' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a void invoice'
    );
  end if;

  -- Refuse to post Quote status
  if v_invoice.status = 'Quote' then
    return jsonb_build_object(
      'success', false,
      'error', 'Cannot post a quote. Save the invoice as Draft instead.'
    );
  end if;

  -- Check period status
  v_can_post := can_post_to_period(
    v_organization_id,
    v_invoice.invoice_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, v_invoice.invoice_date);
    
    if v_period_info is null then
      return jsonb_build_object(
        'success', false,
        'error', 'Cannot post to this date'
      );
    end if;

    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot post invoice with date %s: %s is %s. %s',
        to_char(v_invoice.invoice_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status',
        case
          when v_period_info->>'status' = 'Soft-closed' then 'Only the owner can post to a soft-closed month.'
          when v_period_info->>'status' = 'Locked' then 'No one can post to a locked month. Reopen the period in Settings → Periods first.'
          else ''
        end
      ),
      'period_name', v_period_info->>'period_name',
      'period_status', v_period_info->>'status'
    );
  end if;

  -- Validate customer contact type
  declare
    v_contact_type contact_type;
  begin
    select type into v_contact_type
    from contacts
    where id = v_invoice.customer_id;

    if v_contact_type != 'Customer' then
      return jsonb_build_object(
        'success', false,
        'error', format('Cannot invoice contact type %s. Only Customer contacts can be invoiced.', v_contact_type)
      );
    end if;
  end;

  -- Get or create AR account (1100)
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100'
    and is_active = true;

  if v_ar_account_id is null then
    -- Create AR account if missing
    insert into accounts (
      organization_id,
      code,
      name,
      type,
      category,
      is_system,
      is_active
    ) values (
      v_organization_id,
      '1100',
      'Accounts Receivable',
      'Asset',
      'AR',
      true,
      true
    )
    returning id into v_ar_account_id;
  end if;

  -- Calculate total from lines
  select coalesce(sum(amount_cents), 0) into v_total_cents
  from invoice_lines
  where invoice_id = p_invoice_id;

  if v_total_cents = 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice must have at least one line with non-zero amount'
    );
  end if;

  -- Update invoice total if needed
  if v_invoice.total_cents != v_total_cents then
    update invoices
    set total_cents = v_total_cents,
        updated_at = now()
    where id = p_invoice_id;
  end if;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from v_invoice.invoice_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create recognition journal (Draft first)
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    v_invoice.invoice_date,
    format('Invoice %s', v_invoice.number),
    'Draft',
    'manual',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr 1100 Accounts Receivable
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    v_total_cents,
    0,
    format('Invoice %s', v_invoice.number)
  );

  -- Cr revenue accounts (one line per invoice line)
  for v_line in
    select * from invoice_lines
    where invoice_id = p_invoice_id
    order by line_number
  loop
    -- Validate account is revenue type
    declare
      v_account_type account_type;
    begin
      select type into v_account_type
      from accounts
      where id = v_line.account_id;

      if v_account_type != 'Revenue' then
        raise exception 'Account % is not a revenue account', v_line.account_id;
      end if;
    end;

    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      v_organization_id,
      v_journal_id,
      v_line.account_id,
      0,
      v_line.amount_cents,
      v_line.description
    );
  end loop;

  -- Post the journal via existing post_journal RPC
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Update invoice
  update invoices
  set status = 'Posted',
      recognition_journal_id = v_journal_id,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'invoice_posted',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'invoice_date', v_invoice.invoice_date,
      'total_cents', v_total_cents,
      'journal_id', v_journal_id,
      'journal_number', v_journal_number
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function post_invoice(uuid) to authenticated;

comment on function post_invoice(uuid) is 'Posts an invoice, creating Dr AR / Cr Revenue journal. Validates period locks and revenue account types.';

-- ============================================================================
-- RECORD RECEIPT (PAYMENT)
-- ============================================================================

create or replace function record_receipt(
  p_invoice_id uuid,
  p_receipt_date date,
  p_amount_cents bigint,
  p_cash_account_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_new_received_cents bigint;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
  v_current_role := "current_role"();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Check role
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  -- Get invoice with lock
  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  -- Check if invoice is posted
  if v_invoice.status != 'Posted' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only record receipts for Posted or Paid invoices'
    );
  end if;

  -- Check amount
  if p_amount_cents <= 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Receipt amount must be greater than zero'
    );
  end if;

  v_new_received_cents := v_invoice.received_cents + p_amount_cents;

  if v_new_received_cents > v_invoice.total_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Receipt amount exceeds invoice balance'
    );
  end if;

  -- Check period
  v_can_post := can_post_to_period(
    v_organization_id,
    p_receipt_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_receipt_date);
    
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot record receipt with date %s: %s is %s.',
        to_char(p_receipt_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status'
      )
    );
  end if;

  -- Get AR account (1100)
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100';

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'AR account (1100) not found'
    );
  end if;

  -- Validate cash account
  declare
    v_is_cash boolean;
  begin
    select is_cash into v_is_cash
    from accounts
    where id = p_cash_account_id
      and organization_id = v_organization_id;

    if not v_is_cash then
      return jsonb_build_object(
        'success', false,
        'error', 'Selected account is not a cash account'
      );
    end if;
  end;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from p_receipt_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create receipt journal (Draft first)
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    p_receipt_date,
    format('Receipt for invoice %s', v_invoice.number),
    'Draft',
    'manual',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Cash
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    p_cash_account_id,
    p_amount_cents,
    0,
    format('Receipt for %s', v_invoice.number)
  );

  -- Cr AR (1100)
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    0,
    p_amount_cents,
    format('Receipt for %s', v_invoice.number)
  );

  -- Post the journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Record receipt
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    notes,
    created_by
  ) values (
    v_organization_id,
    p_invoice_id,
    v_journal_id,
    p_receipt_date,
    p_amount_cents,
    'payment',
    p_notes,
    v_current_user_id
  );

  -- Update invoice
  update invoices
  set received_cents = v_new_received_cents,
      status = case
        when v_new_received_cents >= total_cents then 'Paid'::invoice_status
        else 'Posted'::invoice_status
      end,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'receipt_recorded',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'receipt_date', p_receipt_date,
      'amount_cents', p_amount_cents,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function record_receipt(uuid, date, bigint, uuid, text) to authenticated;

comment on function record_receipt(uuid, date, bigint, uuid, text) is 'Records a cash receipt against an invoice: Dr Cash / Cr AR';

-- ============================================================================
-- ISSUE CREDIT NOTE
-- ============================================================================

create or replace function issue_credit_note(
  p_invoice_id uuid,
  p_credit_date date,
  p_amount_cents bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_revenue_account_id uuid;
  v_new_received_cents bigint;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
  v_current_role := "current_role"();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Check role
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  -- Get invoice with lock
  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  -- Check if invoice is posted
  if v_invoice.status != 'Posted' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only issue credit notes for Posted or Paid invoices'
    );
  end if;

  -- Check amount
  if p_amount_cents <= 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Credit note amount must be greater than zero'
    );
  end if;

  v_new_received_cents := v_invoice.received_cents + p_amount_cents;

  if v_new_received_cents > v_invoice.total_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Credit note amount exceeds invoice balance'
    );
  end if;

  -- Check period
  v_can_post := can_post_to_period(
    v_organization_id,
    p_credit_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_credit_date);
    
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot issue credit note with date %s: %s is %s.',
        to_char(p_credit_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status'
      )
    );
  end if;

  -- Get AR account (1100) for credit note
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100';

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'AR account (1100) not found'
    );
  end if;

  -- Get first revenue account from original invoice lines
  select il.account_id into v_revenue_account_id
  from invoice_lines il
  join accounts a on a.id = il.account_id
  where il.invoice_id = p_invoice_id
    and a.type = 'Revenue'
  order by il.line_number
  limit 1;

  if v_revenue_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'No revenue account found on invoice'
    );
  end if;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from p_credit_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create credit note journal (Draft first)
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    p_credit_date,
    format('Credit note for invoice %s: %s', v_invoice.number, p_reason),
    'Draft',
    'manual',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Revenue
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_revenue_account_id,
    p_amount_cents,
    0,
    format('Credit note for %s', v_invoice.number)
  );

  -- Cr AR (1100)
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    0,
    p_amount_cents,
    format('Credit note for %s', v_invoice.number)
  );

  -- Post the journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Record credit note as receipt
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    notes,
    created_by
  ) values (
    v_organization_id,
    p_invoice_id,
    v_journal_id,
    p_credit_date,
    p_amount_cents,
    'credit_note',
    p_reason,
    v_current_user_id
  );

  -- Update invoice
  update invoices
  set received_cents = v_new_received_cents,
      status = case
        when v_new_received_cents >= total_cents then 'Paid'::invoice_status
        else 'Posted'::invoice_status
      end,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'credit_note_issued',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'credit_date', p_credit_date,
      'amount_cents', p_amount_cents,
      'reason', p_reason,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function issue_credit_note(uuid, date, bigint, text) to authenticated;

comment on function issue_credit_note(uuid, date, bigint, text) is 'Issues a credit note against an invoice: Dr Revenue / Cr AR';

-- ============================================================================
-- WRITE OFF INVOICE
-- ============================================================================

create or replace function write_off_invoice(
  p_invoice_id uuid,
  p_write_off_date date,
  p_amount_cents bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoices;
  v_organization_id uuid;
  v_current_user_id uuid;
  v_current_role membership_role;
  v_journal_id uuid;
  v_journal_number text;
  v_ar_account_id uuid;
  v_bad_debt_account_id uuid;
  v_new_received_cents bigint;
  v_can_post boolean;
  v_period_info jsonb;
begin
  -- Get current user
  v_current_user_id := auth.uid();
  v_current_role := "current_role"();

  if v_current_user_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  -- Check role
  if not has_role('bookkeeper') then
    return jsonb_build_object(
      'success', false,
      'error', 'Permission denied: bookkeeper role or higher required'
    );
  end if;

  -- Get invoice with lock
  select * into v_invoice
  from invoices
  where id = p_invoice_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'Invoice not found'
    );
  end if;

  v_organization_id := v_invoice.organization_id;

  -- Check if invoice is posted
  if v_invoice.status != 'Posted' and v_invoice.status != 'Paid' then
    return jsonb_build_object(
      'success', false,
      'error', 'Can only write off Posted or Paid invoices'
    );
  end if;

  -- Check amount
  if p_amount_cents <= 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Write-off amount must be greater than zero'
    );
  end if;

  v_new_received_cents := v_invoice.received_cents + p_amount_cents;

  if v_new_received_cents > v_invoice.total_cents then
    return jsonb_build_object(
      'success', false,
      'error', 'Write-off amount exceeds invoice balance'
    );
  end if;

  -- Check period
  v_can_post := can_post_to_period(
    v_organization_id,
    p_write_off_date,
    v_current_role
  );

  if not v_can_post then
    v_period_info := get_period_status_info(v_organization_id, p_write_off_date);
    
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Cannot write off with date %s: %s is %s.',
        to_char(p_write_off_date, 'Mon DD, YYYY'),
        v_period_info->>'period_name',
        v_period_info->>'status'
      )
    );
  end if;

  -- Get AR account (1100)
  select id into v_ar_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '1100';

  if v_ar_account_id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'AR account (1100) not found'
    );
  end if;

  -- Get or create Bad Debt expense account (5110)
  select id into v_bad_debt_account_id
  from accounts
  where organization_id = v_organization_id
    and code = '5110'
    and is_active = true;

  if v_bad_debt_account_id is null then
    -- Create Bad Debt expense account
    insert into accounts (
      organization_id,
      code,
      name,
      type,
      category,
      is_active
    ) values (
      v_organization_id,
      '5110',
      'Bad Debt Expense',
      'Expense',
      'Expense',
      true
    )
    returning id into v_bad_debt_account_id;
  end if;

  -- Generate journal number
  declare
    v_journal_count int;
  begin
    select count(*) into v_journal_count
    from journals
    where organization_id = v_organization_id;
    
    v_journal_number := format('JE-%s-%s', 
      extract(year from p_write_off_date),
      lpad((v_journal_count + 1)::text, 4, '0')
    );
  end;

  -- Create write-off journal (Draft first)
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    v_organization_id,
    v_journal_number,
    p_write_off_date,
    format('Write-off invoice %s: %s', v_invoice.number, p_reason),
    'Draft',
    'manual',
    v_current_user_id
  )
  returning id into v_journal_id;

  -- Dr Bad Debt Expense
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_bad_debt_account_id,
    p_amount_cents,
    0,
    format('Write-off %s', v_invoice.number)
  );

  -- Cr AR (1100)
  insert into journal_lines (
    organization_id,
    journal_id,
    account_id,
    debit_cents,
    credit_cents,
    memo
  ) values (
    v_organization_id,
    v_journal_id,
    v_ar_account_id,
    0,
    p_amount_cents,
    format('Write-off %s', v_invoice.number)
  );

  -- Post the journal
  declare
    v_post_result jsonb;
  begin
    v_post_result := post_journal(v_journal_id);
    
    if not (v_post_result->>'success')::boolean then
      raise exception '%', v_post_result->>'error';
    end if;
  end;

  -- Record write-off as receipt
  insert into invoice_receipts (
    organization_id,
    invoice_id,
    receipt_journal_id,
    receipt_date,
    amount_cents,
    receipt_type,
    notes,
    created_by
  ) values (
    v_organization_id,
    p_invoice_id,
    v_journal_id,
    p_write_off_date,
    p_amount_cents,
    'write_off',
    p_reason,
    v_current_user_id
  );

  -- Update invoice
  update invoices
  set received_cents = v_new_received_cents,
      status = case
        when v_new_received_cents >= total_cents then 'Paid'::invoice_status
        else 'Posted'::invoice_status
      end,
      updated_at = now()
  where id = p_invoice_id;

  -- Log audit event
  perform log_audit_event(
    'invoice',
    p_invoice_id,
    'invoice_written_off',
    jsonb_build_object(
      'invoice_number', v_invoice.number,
      'write_off_date', p_write_off_date,
      'amount_cents', p_amount_cents,
      'reason', p_reason,
      'journal_id', v_journal_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'journal_id', v_journal_id
  );
end;
$$;

grant execute on function write_off_invoice(uuid, date, bigint, text) to authenticated;

comment on function write_off_invoice(uuid, date, bigint, text) is 'Writes off an uncollectible invoice: Dr Bad Debt Expense / Cr AR';

