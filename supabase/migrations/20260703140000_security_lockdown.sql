-- ============================================================
-- SECURITY LOCKDOWN
-- ============================================================
-- Verified holes (reproduced against the live project with nothing but the
-- publishable anon key that ships inside the app binary):
--   1. Recordings bucket was PUBLIC — any URL downloadable by anyone on the
--      internet, no auth at all (161KB of a castmate's voice retrieved).
--   2. debug_reports readable by ANON — user emails + full app logs.
--   3. Any authenticated user could list every production INCLUDING join codes.
--   4. Any authenticated user could read every cast_members row (display
--      names + contact_info = phone/email of cast, incl. minors).
--   5. Any authenticated user could self-join ANY production and then read
--      its whole script and download every castmate recording.
--   6. Any authenticated user could UPDATE any cast_members row (steal a
--      claimed role / reassign someone else's membership).
--   7. Any authenticated user could INSERT a cast row for ANOTHER user.
--
-- Compatibility: shipped builds (<=107) do RPC-first for lookup/join/claim
-- (lookup_production_by_join_code, fetch_cast_for_join, join_production,
-- claim_cast_invitation are all SECURITY DEFINER and bypass RLS), and they
-- download audio through the AUTHENTICATED storage API — so none of the
-- changes below break them. The direct-table fallbacks stop working; that is
-- the point, and the RPC path in front of them succeeds.

-- ── 1. Recordings bucket: public → private ──────────────
-- Clients call storage.from('recordings').download(path) (authenticated API),
-- so private is transparent to them, but the public /object/public/ URL that
-- exposed every recording to the open internet stops serving.
update storage.buckets set public = false where id = 'recordings';

-- Scope object access to the production's cast instead of "any logged-in user".
-- Upload path layout is <productionId>/<characterName>/<lineId>.m4a, so the
-- first folder segment is the production id.
-- Helper: the production id encoded in a recordings object path, or NULL when
-- the path isn't in the expected <productionId>/<character>/<line>.m4a shape.
-- Wrapped so a malformed path returns NULL instead of raising inside a policy.
create or replace function public.recording_object_production(objname text)
returns uuid language plpgsql immutable as $$
declare seg text;
begin
  seg := (storage.foldername(objname))[1];
  return seg::uuid;
exception when others then
  return null;
end;
$$;

drop policy if exists "Authenticated users can upload recordings" on storage.objects;
drop policy if exists "Authenticated users can read recordings" on storage.objects;
drop policy if exists "Users can update own recordings" on storage.objects;
drop policy if exists "Cast members can upload recordings" on storage.objects;
drop policy if exists "Cast members can read recordings" on storage.objects;
drop policy if exists "Members read recording objects" on storage.objects;
drop policy if exists "Members write recording objects" on storage.objects;
drop policy if exists "Members update recording objects" on storage.objects;

create policy "Members read recording objects"
  on storage.objects for select
  using (
    bucket_id = 'recordings'
    and public.is_production_member(
      public.recording_object_production(name), auth.uid())
  );

create policy "Members write recording objects"
  on storage.objects for insert
  with check (
    bucket_id = 'recordings'
    and public.is_production_member(
      public.recording_object_production(name), auth.uid())
  );

create policy "Members update recording objects"
  on storage.objects for update
  using (
    bucket_id = 'recordings'
    and public.is_production_member(
      public.recording_object_production(name), auth.uid())
  );

-- ── 2. debug_reports: was world-readable (incl. anon) ───
drop policy if exists "Anyone can read debug reports" on public.debug_reports;
drop policy if exists "Users read own debug reports" on public.debug_reports;
create policy "Users read own debug reports"
  on public.debug_reports for select
  to authenticated
  using (auth.uid() = user_id);
-- (Developer pulls reports with the service-role key, which bypasses RLS.)

-- ── 3. productions: no more global enumeration ──────────
-- Join-by-code still works: lookup_production_by_join_code is SECURITY
-- DEFINER, so a joiner who knows the code gets the row; a stranger who does
-- not know a code can no longer list productions or harvest join codes.
drop policy if exists "auth_read_productions" on public.productions;
drop policy if exists "Authenticated users can read productions" on public.productions;

-- ── 4. cast_members: scope reads to the production's cast ─
drop policy if exists "auth_read_cast" on public.cast_members;
drop policy if exists "Authenticated users can read cast members" on public.cast_members;
drop policy if exists "Members read production cast" on public.cast_members;
create policy "Members read production cast"
  on public.cast_members for select
  to authenticated
  using (public.is_production_member(production_id, auth.uid()));
-- ("Users read own memberships" + "Organizers read production cast" from
--  20260314140000 remain and cover the other two read paths.)

-- ── 5/7. cast_members INSERT: only ever for yourself ────
drop policy if exists "auth_insert_cast" on public.cast_members;
drop policy if exists "Authenticated users can join productions" on public.cast_members;
drop policy if exists "Users insert own membership" on public.cast_members;
create policy "Users insert own membership"
  on public.cast_members for insert
  to authenticated
  with check (auth.uid() = user_id);
-- Self-join still requires the production UUID, which (after 3) is only
-- obtainable by presenting a valid join code to the lookup RPC.

-- ── 6. cast_members UPDATE: no more role stealing ───────
drop policy if exists "auth_update_cast" on public.cast_members;
drop policy if exists "Users can claim their invitation" on public.cast_members;
create policy "Users can claim their invitation"
  on public.cast_members for update
  to authenticated
  using (auth.uid() = user_id or user_id is null)
  with check (auth.uid() = user_id);

-- ── 8. profiles: don't expose every user's profile ──────
drop policy if exists "Users can read any profile" on public.profiles;
drop policy if exists "Users read own profile" on public.profiles;
create policy "Users read own profile"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

-- ── 9. join_production RPC: caller could pick their own role ─
-- SECURITY DEFINER bypasses RLS, so the policy fixes above do NOT cover it.
-- Shipped clients always pass role 'actor' (join_production_screen.dart), so
-- forcing it here is transparent to them. (Requiring the join code itself
-- needs a new signature + client >=108; tracked separately.)
create or replace function public.join_production(
  prod_id text,
  char_name text default '',
  display_name text default '',
  member_role text default 'actor'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  result json;
begin
  -- Never let a self-joiner mint an elevated role.
  member_role := 'actor';
  insert into cast_members (production_id, user_id, character_name, display_name, role, joined_at)
  values (prod_id::uuid, auth.uid(), char_name, display_name, member_role, now())
  returning row_to_json(cast_members.*) into result;
  return result;
end;
$$;

-- ── 10. fetch_cast_for_join leaked contact_info to any caller ─
-- The join screen only uses id/character_name/display_name/role/user_id.
create or replace function public.fetch_cast_for_join(prod_id text)
returns json
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'id', cm.id,
    'production_id', cm.production_id,
    'character_name', cm.character_name,
    'display_name', cm.display_name,
    'role', cm.role,
    'user_id', cm.user_id)), '[]'::json)
  from cast_members cm
  where cm.production_id = prod_id::uuid;
$$;

-- ── 11. recordings INSERT required only "row is mine" ───────
-- Add the missing membership check so nobody can plant rows in a production
-- they don't belong to.
drop policy if exists "Users can insert own recordings" on public.recordings;
drop policy if exists "Members insert own recordings" on public.recordings;
create policy "Members insert own recordings"
  on public.recordings for insert
  to authenticated
  with check (
    auth.uid() = user_id
    and public.is_production_member(production_id, auth.uid())
  );

-- ── 12. Defense in depth on SECURITY DEFINER helpers ────────
-- Pin search_path, and stop them being callable as a membership oracle.
create or replace function public.is_production_member(p_production_id uuid, p_user_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.cast_members
    where production_id = p_production_id and user_id = p_user_id
  );
$$;

create or replace function public.is_production_organizer(p_production_id uuid, p_user_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.productions
    where id = p_production_id and organizer_id = p_user_id
  );
$$;

revoke execute on function public.is_production_member(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.is_production_organizer(uuid, uuid) from public, anon, authenticated;
