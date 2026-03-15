-- Fix infinite recursion in cast_members RLS policy.
-- The old policy queried cast_members from within a cast_members policy.

-- Drop the recursive policy
drop policy if exists "Cast members can read their own production cast" on public.cast_members;

-- Replace with a simple policy: users can read cast rows where they are the user,
-- or where they belong to the same production (checked via productions table).
create policy "Users can read own cast membership"
  on public.cast_members for select
  using (auth.uid() = user_id);

create policy "Organizers can read all cast for their productions"
  on public.cast_members for select
  using (
    exists (
      select 1 from public.productions
      where productions.id = cast_members.production_id
        and productions.organizer_id = auth.uid()
    )
  );

-- Also fix the productions SELECT policy — it queries cast_members which queries back
drop policy if exists "Cast members can read their productions" on public.productions;

create policy "Cast members can read their productions"
  on public.productions for select
  using (
    auth.uid() = organizer_id
    or exists (
      select 1 from public.cast_members
      where cast_members.production_id = productions.id
        and cast_members.user_id = auth.uid()
    )
  );

-- Drop the duplicate "Organizer can do anything" ALL policy since the new SELECT
-- policy above already covers organizer reads, and the ALL policy stays for write ops
-- (actually keep it — ALL covers insert/update/delete too)
