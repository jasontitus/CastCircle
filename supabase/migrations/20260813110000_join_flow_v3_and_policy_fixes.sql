-- ============================================================
-- Join flow v3 + policy fixes (2026-08-13 security review)
--
-- The v2 join RPCs are SECURITY DEFINER and gated the entire join flow on
-- "knows the production UUID": join_production never verified the join
-- code, claim_cast_invitation claimed any user_id-IS-NULL row by id, and
-- fetch_cast_for_join enumerated the roster (including the claimable ids)
-- for any authenticated caller. Together: invitation/role takeover by any
-- authenticated user who learned a production UUID.
--
-- v3 requires presenting the production's join code for every pre-
-- membership operation, rate-limits code lookups, and fixes the policy
-- gaps the same review found (self-granted organizer role, debug_reports
-- forgery, recordings row repointing, brute-forceable legacy codes,
-- duplicate index).
--
-- CLIENT COMPATIBILITY: clients older than this migration call the v2
-- signatures, which now RAISE — joining requires updating the app. Line
-- and recording sync for existing members are unaffected.
-- ============================================================

-- ── 1. Rate-limit join-code lookups ─────────────────────────
-- The lookup RPC is the only unauthenticated-ish surface (it needs only a
-- signed-in account, which anyone can create). 6-char codes over a 31-char
-- alphabet are ~887M possibilities; unthrottled online guessing was the
-- worry, so: max 20 lookups per user per 5 minutes.

create table if not exists public.join_code_attempts (
  user_id uuid not null,
  attempted_at timestamptz not null default now()
);
create index if not exists idx_join_code_attempts_user_time
  on public.join_code_attempts (user_id, attempted_at);
alter table public.join_code_attempts enable row level security;
-- No policies: only SECURITY DEFINER functions touch this table.

create or replace function public.check_join_rate_limit()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  recent integer;
begin
  if auth.uid() is null then
    raise exception 'Sign in to look up a join code';
  end if;
  -- Opportunistic cleanup keeps the table tiny.
  delete from join_code_attempts
    where user_id = auth.uid() and attempted_at < now() - interval '1 hour';
  select count(*) into recent from join_code_attempts
    where user_id = auth.uid() and attempted_at > now() - interval '5 minutes';
  if recent >= 20 then
    raise exception 'Too many join-code attempts — try again in a few minutes';
  end if;
  insert into join_code_attempts (user_id) values (auth.uid());
end;
$$;

create or replace function public.lookup_production_by_join_code(lookup_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  result json;
begin
  perform public.check_join_rate_limit();
  select row_to_json(p) into result
  from productions p
  where p.join_code = upper(lookup_code)
  limit 1;
  return result;
end;
$$;

-- The app requires sign-in before the join screen; anon had no legitimate
-- use and made online guessing account-free.
revoke execute on function public.lookup_production_by_join_code(text) from anon;

-- ── 2. fetch_cast_for_join requires the code (or membership) ─
drop function if exists public.fetch_cast_for_join(text);
create or replace function public.fetch_cast_for_join(prod_id text, code text)
returns json
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  result json;
begin
  if not exists (
    select 1 from productions p
    where p.id = prod_id::uuid and p.join_code = upper(code)
  ) and not public.is_production_member(prod_id::uuid, auth.uid()) then
    raise exception 'Invalid join code for this production';
  end if;
  select coalesce(json_agg(json_build_object(
    'id', cm.id,
    'production_id', cm.production_id,
    'character_name', cm.character_name,
    'display_name', cm.display_name,
    'role', cm.role,
    'user_id', cm.user_id)), '[]'::json) into result
  from cast_members cm
  where cm.production_id = prod_id::uuid;
  return result;
end;
$$;
grant execute on function public.fetch_cast_for_join(text, text) to authenticated;

-- ── 3. join_production requires the code; role stays forced ─
drop function if exists public.join_production(text, text, text, text);
create or replace function public.join_production(
  prod_id text,
  code text,
  char_name text default '',
  display_name text default ''
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  result json;
begin
  if not exists (
    select 1 from productions p
    where p.id = prod_id::uuid and p.join_code = upper(code)
  ) then
    raise exception 'Invalid join code for this production';
  end if;
  insert into cast_members (production_id, user_id, character_name, display_name, role, joined_at)
  values (prod_id::uuid, auth.uid(), char_name, display_name, 'actor', now())
  returning row_to_json(cast_members.*) into result;
  return result;
end;
$$;
grant execute on function public.join_production(text, text, text, text) to authenticated;

-- ── 4. claim_cast_invitation requires the code ──────────────
drop function if exists public.claim_cast_invitation(text);
create or replace function public.claim_cast_invitation(member_id text, code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update cast_members cm
  set user_id = auth.uid(),
      joined_at = now()
  where cm.id = member_id::uuid
    and cm.user_id is null
    and exists (
      select 1 from productions p
      where p.id = cm.production_id and p.join_code = upper(code)
    );
end;
$$;
grant execute on function public.claim_cast_invitation(text, text) to authenticated;

-- ── 5. Self-insert can no longer mint organizer ─────────────
-- The RPC path forces role='actor' but the direct-table INSERT policy only
-- checked ownership, so a caller could insert role='organizer' for
-- themselves. (The DB grants organizer no server-side power, but client
-- logic trusts the role.)
drop policy if exists "Users insert own membership" on public.cast_members;
create policy "Users insert own membership"
  on public.cast_members for insert
  to authenticated
  with check (auth.uid() = user_id and role in ('actor', 'understudy'));

-- ── 6. debug_reports: no forging rows as another user ───────
drop policy if exists "Authenticated users can insert debug reports" on public.debug_reports;
create policy "Users insert own debug reports"
  on public.debug_reports for insert
  to authenticated
  with check (user_id = auth.uid());

-- ── 7. recordings UPDATE: row can't be repointed ────────────
-- No WITH CHECK meant the new row was unconstrained: a user could reassign
-- their recording's user_id, move it to another production, or keep
-- updating rows in productions they'd left.
drop policy if exists "Users can update own recordings" on public.recordings;
create policy "Users can update own recordings"
  on public.recordings for update
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and public.is_production_member(production_id, auth.uid())
  );

-- ── 8. Re-roll brute-forceable legacy join codes ────────────
-- The 20260315 backfill used md5-hex fragments: 6 chars over [0-9A-F]
-- (~16.7M codes) vs generate_join_code()'s ~887M. Re-roll any code that
-- still matches the legacy alphabet. NOTE: invalidates printed/shared
-- invites for those legacy productions — organizers must re-share.
update public.productions
set join_code = public.generate_join_code()
where join_code ~ '^[0-9A-F]{6}$';

-- ── 9. Duplicate index ──────────────────────────────────────
-- unique (production_id, order_index) already maintains an identical
-- btree; the explicit index doubled write amplification on the app's
-- biggest bulk-write path.
drop index if exists public.idx_script_lines_production;
