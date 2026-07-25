-- recordings had policies for select/insert/update but NONE for delete, so
-- "delete this take" could only ever remove the local copy — every castmate
-- kept hearing a take the actor had deleted, forever. Let a user delete their
-- own recordings, and let the organizer clean up their production.
drop policy if exists "Users delete own recordings" on public.recordings;
create policy "Users delete own recordings"
  on public.recordings for delete
  to authenticated
  using (
    auth.uid() = user_id
    or public.is_production_organizer(production_id, auth.uid())
  );
