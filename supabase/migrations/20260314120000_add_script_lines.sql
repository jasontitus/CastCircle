-- ============================================================
-- Script lines table (cloud-synced script data)
-- ============================================================

create table public.script_lines (
  id uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions(id) on delete cascade,
  order_index integer not null,
  act text not null default '',
  scene text not null default '',
  line_number integer not null default 0,
  character text not null default '',
  line_text text not null default '',
  line_type text not null default 'dialogue' check (line_type in ('dialogue', 'stageDirection', 'header', 'song')),
  stage_direction text not null default '',
  updated_at timestamptz default now() not null,
  unique (production_id, order_index)
);

alter table public.script_lines enable row level security;

-- Organizer can do anything with script lines
create policy "Organizer can manage script lines"
  on public.script_lines for all
  using (
    exists (
      select 1 from public.productions
      where productions.id = script_lines.production_id
        and productions.organizer_id = auth.uid()
    )
  );

-- Cast members can read script lines
create policy "Cast members can read script lines"
  on public.script_lines for select
  using (
    exists (
      select 1 from public.cast_members
      where cast_members.production_id = script_lines.production_id
        and cast_members.user_id = auth.uid()
    )
  );

-- Index for fast fetches
create index idx_script_lines_production on public.script_lines (production_id, order_index);

-- Enable realtime so the app can subscribe to script changes
alter publication supabase_realtime add table public.script_lines;
