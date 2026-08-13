-- ============================================================
-- Scene metadata table (cloud-synced)
--
-- Scene renames/descriptions from the scene editor previously lived only
-- in local Drift: pushScriptToCloud sent lines, never scenes, and every
-- pull regenerated scenes from per-line act|scene tags — silently
-- discarding the organizer's custom sceneName/description and changing
-- scene ids for anything keyed on them. This table mirrors the local
-- Scenes schema; pull rebuilds from these rows and falls back to
-- tag-derived scenes when a production has none (older pushes).
-- ============================================================

create table public.script_scenes (
  id uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions(id) on delete cascade,
  sort_order integer not null default 0,
  scene_name text not null default '',
  act text not null default '',
  location text not null default '',
  description text not null default '',
  start_line_index integer not null default 0,
  end_line_index integer not null default 0,
  characters text not null default '',
  updated_at timestamptz default now() not null,
  unique (production_id, sort_order)
);

alter table public.script_scenes enable row level security;

-- Mirrors script_lines policies: organizer manages, cast reads.
create policy "Organizer can manage script scenes"
  on public.script_scenes for all
  using (
    exists (
      select 1 from public.productions
      where productions.id = script_scenes.production_id
        and productions.organizer_id = auth.uid()
    )
  );

create policy "Cast members can read script scenes"
  on public.script_scenes for select
  using (public.is_production_member(production_id, auth.uid()));

create index idx_script_scenes_production
  on public.script_scenes (production_id, sort_order);
