-- The lockdown migration dropped two of the THREE permissive SELECT policies
-- on productions. This is the third — from 20260315_cast_join_code.sql — and
-- because Postgres OR-combines permissive policies, it alone kept the whole
-- table (including every join_code) readable by any authenticated user, which
-- in turn kept the self-join chain alive: enumerate production → get uuid →
-- join without the code → read the script and download the cast's audio.
--
-- Join-by-code is unaffected: lookup_production_by_join_code is SECURITY
-- DEFINER and bypasses RLS, and it is what shipped clients call first.
drop policy if exists "Anyone can lookup by join code" on public.productions;
