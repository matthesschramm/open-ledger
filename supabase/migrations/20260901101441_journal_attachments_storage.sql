-- Private attachments bucket for journal evidence (invoices, receipts, scans).
-- Path convention: org/{organization_id}/journals/{journal_id}/{uuid}-{file}

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'attachments',
  'attachments',
  false,
  10485760,
  array[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif'
  ]
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Members can read org attachments" on storage.objects;
drop policy if exists "Bookkeepers can upload org attachments" on storage.objects;
drop policy if exists "Bookkeepers can delete org attachments" on storage.objects;

create policy "Members can read org attachments"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'attachments'
  and (storage.foldername(name))[1] = 'org'
  and (storage.foldername(name))[2] = public.current_org_id()::text
);

create policy "Bookkeepers can upload org attachments"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'attachments'
  and public.has_role('bookkeeper')
  and (storage.foldername(name))[1] = 'org'
  and (storage.foldername(name))[2] = public.current_org_id()::text
);

create policy "Bookkeepers can delete org attachments"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'attachments'
  and public.has_role('bookkeeper')
  and (storage.foldername(name))[1] = 'org'
  and (storage.foldername(name))[2] = public.current_org_id()::text
);
