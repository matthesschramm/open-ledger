-- Let every org member look up emails for other members in the same org.
-- Previously get_user_email was not granted to authenticated, so Users showed "Unknown".

create or replace function get_user_email(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select u.email::text
  from auth.users u
  where u.id = p_user_id
    and (
      auth.uid() = p_user_id
      or exists (
        select 1
        from public.memberships caller
        join public.memberships target
          on target.organization_id = caller.organization_id
        where caller.user_id = auth.uid()
          and target.user_id = p_user_id
      )
    );
$$;

comment on function get_user_email is
  'Returns the email for a user_id when the caller is that user or shares an organization with them.';

revoke all on function get_user_email(uuid) from public, anon;
grant execute on function get_user_email(uuid) to authenticated, service_role;
