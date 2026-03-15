-- Fix circular RLS dependency between productions and cast_members.
-- The problem: productions SELECT checks cast_members, cast_members SELECT checks productions.
-- Solution: use a security definer function that bypasses RLS to check membership.

-- Helper function that checks if a user belongs to a production.
-- SECURITY DEFINER runs as the function owner (postgres), bypassing RLS.
create or replace function public.is_production_member(p_production_id uuid, p_user_id uuid)
returns boolean as $$
  select exists (
    select 1 from public.cast_members
    where production_id = p_production_id
      and user_id = p_user_id
  );
$$ language sql security definer stable;

-- Helper: check if user is organizer
create or replace function public.is_production_organizer(p_production_id uuid, p_user_id uuid)
returns boolean as $$
  select exists (
    select 1 from public.productions
    where id = p_production_id
      and organizer_id = p_user_id
  );
$$ language sql security definer stable;

-- ── Fix productions policies ─────────────────────────

-- Drop ALL existing production policies to start clean
drop policy if exists "Organizer can do anything" on public.productions;
drop policy if exists "Cast members can read their productions" on public.productions;

-- Organizer full access
create policy "Organizer full access"
  on public.productions for all
  using (auth.uid() = organizer_id);

-- Cast members can read productions they belong to (uses security definer function)
create policy "Members can read productions"
  on public.productions for select
  using (public.is_production_member(id, auth.uid()));

-- ── Fix cast_members policies ────────────────────────

drop policy if exists "Users can read own cast membership" on public.cast_members;
drop policy if exists "Organizers can read all cast for their productions" on public.cast_members;
drop policy if exists "Organizer can manage cast" on public.cast_members;

-- Users can always see their own memberships
create policy "Users read own memberships"
  on public.cast_members for select
  using (auth.uid() = user_id);

-- Organizers can see all cast in their productions (uses security definer function)
create policy "Organizers read production cast"
  on public.cast_members for select
  using (public.is_production_organizer(production_id, auth.uid()));

-- Organizers can manage cast (insert/update/delete)
create policy "Organizers manage cast"
  on public.cast_members for all
  using (public.is_production_organizer(production_id, auth.uid()));

-- ── Fix recordings policies ──────────────────────────

drop policy if exists "Cast members can read production recordings" on public.recordings;

create policy "Members can read production recordings"
  on public.recordings for select
  using (public.is_production_member(production_id, auth.uid()));

-- ── Fix script_lines policies ────────────────────────

drop policy if exists "Organizer can manage script lines" on public.script_lines;
drop policy if exists "Cast members can read script lines" on public.script_lines;

create policy "Organizer manages script lines"
  on public.script_lines for all
  using (public.is_production_organizer(production_id, auth.uid()));

create policy "Members read script lines"
  on public.script_lines for select
  using (public.is_production_member(production_id, auth.uid()));
