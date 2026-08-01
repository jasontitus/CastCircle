-- Restore the index behind is_production_member's lookup.
--
-- 20260315_cast_join_code.sql dropped cast_members_production_id_user_id_key
-- (to make user_id nullable) — which was also the ONLY index covering the
-- (production_id, user_id) predicate that the SECURITY-DEFINER RLS helper
-- is_production_member() probes. That helper is the USING clause on
-- productions, cast_members, recordings, script_lines and storage.objects,
-- so without an index every RLS row check seq-scans the whole cast_members
-- table — cloud read latency grows with total table size.
create index if not exists idx_cast_members_production_user
  on public.cast_members (production_id, user_id);
