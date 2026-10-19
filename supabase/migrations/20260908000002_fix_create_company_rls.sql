-- Fix create_company RLS issue
-- Allow users to create owner memberships for themselves in new companies

-- Add policy to allow users to create owner membership for themselves
-- This enables the create_company() RPC to insert the initial owner membership
create policy "Users can create owner membership for self"
  on memberships for insert
  with check (
    user_id = auth.uid() 
    and role = 'owner'
  );

comment on policy "Users can create owner membership for self" on memberships is 
  'Allows users to create owner memberships for themselves when creating new companies';
