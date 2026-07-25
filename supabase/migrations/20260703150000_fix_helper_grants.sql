-- HOTFIX for 20260703140000.
--
-- That migration revoked EXECUTE on is_production_member /
-- is_production_organizer to stop them being used as a membership oracle.
-- That was wrong: RLS policy expressions are evaluated with the QUERYING
-- user's privileges, and nearly every policy calls these helpers — so
-- revoking EXECUTE made legitimate members fail with
-- "permission denied for function is_production_member" when reading their
-- own productions, script lines, recordings and storage objects.
--
-- Restore the grants. The oracle concern (an authenticated user probing
-- whether some other user belongs to some production) is a minor
-- information leak and is NOT worth breaking all member access for; the
-- functions leak only a boolean and require knowing both uuids.
grant execute on function public.is_production_member(uuid, uuid) to authenticated, anon;
grant execute on function public.is_production_organizer(uuid, uuid) to authenticated, anon;
