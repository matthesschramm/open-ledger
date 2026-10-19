-- Create Manual Journal RPC
-- Atomic journal creation to prevent duplicate submissions

create or replace function create_manual_journal(
  p_organization_id uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb,
  p_should_post boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journal_id uuid;
  v_journal_number text;
  v_max_number int;
  v_year int;
  v_line jsonb;
  v_line_count int;
  v_duplicate_id uuid;
  v_duplicate_status text;
  v_created_at timestamptz;
  v_current_org_id uuid;
  v_stripped_lines jsonb;
begin
  -- Auth checks: user must be authenticated and belong to org with owner/bookkeeper role
  if auth.uid() is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authenticated'
    );
  end if;

  select current_org_id() into v_current_org_id;
  
  if v_current_org_id != p_organization_id then
    return jsonb_build_object(
      'success', false,
      'error', 'Not authorized for this organization'
    );
  end if;

  if not (has_role('owner') or has_role('bookkeeper')) then
    return jsonb_build_object(
      'success', false,
      'error', 'Insufficient permissions'
    );
  end if;

  -- Strip memo from lines for fingerprint comparison
  select jsonb_agg(
    jsonb_build_object(
      'account_id', line->>'account_id',
      'debit_cents', (line->>'debit_cents')::bigint,
      'credit_cents', (line->>'credit_cents')::bigint
    ) order by line->>'account_id', (line->>'debit_cents')::bigint, (line->>'credit_cents')::bigint
  ) into v_stripped_lines
  from jsonb_array_elements(p_lines) as line;

  -- Check for recent duplicate (same entry_date + description + line fingerprint in last 2 minutes)
  with line_fingerprints as (
    select
      j.id,
      j.status,
      j.created_at,
      jsonb_agg(
        jsonb_build_object(
          'account_id', jl.account_id,
          'debit_cents', jl.debit_cents,
          'credit_cents', jl.credit_cents
        ) order by jl.account_id, jl.debit_cents, jl.credit_cents
      ) as fingerprint
    from journals j
    join journal_lines jl on jl.journal_id = j.id
    where j.organization_id = p_organization_id
      and j.entry_date = p_entry_date
      and j.description = p_description
      and j.created_at > now() - interval '2 minutes'
    group by j.id, j.status, j.created_at
  )
  select lf.id, lf.status into v_duplicate_id, v_duplicate_status
  from line_fingerprints lf
  where lf.fingerprint = v_stripped_lines
  order by lf.created_at desc
  limit 1;

  -- If duplicate found, return existing journal
  if v_duplicate_id is not null then
    -- If user wanted to post and it's still Draft, post it now
    if p_should_post and v_duplicate_status = 'Draft' then
      perform post_journal(v_duplicate_id);
    end if;
    
    return jsonb_build_object(
      'success', true,
      'journal_id', v_duplicate_id,
      'is_duplicate', true
    );
  end if;

  -- Acquire advisory lock for this organization to ensure atomic number generation
  perform pg_advisory_xact_lock(('x' || substr(md5(p_organization_id::text), 1, 16))::bit(64)::bigint);

  -- Generate journal number atomically
  v_year := extract(year from p_entry_date);
  
  select coalesce(max(
    case 
      when number ~ '^JE-[0-9]{4}-[0-9]{4}$' then
        substring(number from 'JE-[0-9]{4}-([0-9]{4})')::int
      else 0
    end
  ), 0) into v_max_number
  from journals
  where organization_id = p_organization_id
    and number like 'JE-' || v_year::text || '-%';
  
  v_journal_number := 'JE-' || v_year::text || '-' || lpad((v_max_number + 1)::text, 4, '0');

  -- Create journal
  insert into journals (
    organization_id,
    number,
    entry_date,
    description,
    status,
    source,
    created_by
  ) values (
    p_organization_id,
    v_journal_number,
    p_entry_date,
    p_description,
    'Draft',
    'manual',
    auth.uid()
  )
  returning id into v_journal_id;

  -- Create lines
  v_line_count := 0;
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    insert into journal_lines (
      organization_id,
      journal_id,
      account_id,
      debit_cents,
      credit_cents,
      memo
    ) values (
      p_organization_id,
      v_journal_id,
      (v_line->>'account_id')::uuid,
      (v_line->>'debit_cents')::bigint,
      (v_line->>'credit_cents')::bigint,
      v_line->>'memo'
    );
    v_line_count := v_line_count + 1;
  end loop;

  -- Validate minimum lines
  if v_line_count < 2 then
    raise exception 'Journal must have at least 2 lines';
  end if;

  -- Post if requested
  if p_should_post then
    declare
      v_post_result jsonb;
    begin
      v_post_result := post_journal(v_journal_id);
      if not (v_post_result->>'success')::boolean then
        raise exception 'Failed to post: %', v_post_result->>'error';
      end if;
    end;
  end if;

  return jsonb_build_object(
    'success', true,
    'journal_id', v_journal_id,
    'is_duplicate', false
  );
end;
$$;

-- Restrict access
revoke all on function create_manual_journal(uuid, date, text, jsonb, boolean) from public;
grant execute on function create_manual_journal(uuid, date, text, jsonb, boolean) to authenticated;
