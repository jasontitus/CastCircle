-- 1. Members may LEAVE a production (delete their own membership row).
--    Until now only organizers could delete cast rows — a joiner could never
--    remove themselves, so "deleted" productions boomeranged back onto their
--    devices via the cloud restore (their membership still existed).
drop policy if exists "Members can leave" on public.cast_members;
create policy "Members can leave"
  on public.cast_members for delete
  using (auth.uid() = user_id);

-- 2. One-time cleanup: repo audit tooling (tool/orphan_sweep.dart etc.)
--    signed up throwaway accounts with @example.com emails and self-joined
--    productions to satisfy RLS for read-only audits. Their self-cleanup
--    deletes were silently blocked by the missing policy above, leaving a
--    junk understudy row on ~97 productions. Remove the rows and the
--    accounts. No real user has an @example.com address.
delete from public.cast_members
 where user_id in (select id from auth.users where email like '%@example.com');
delete from auth.users where email like '%@example.com';
