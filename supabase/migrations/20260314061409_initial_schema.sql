-- ============================================================
-- LineGuide initial schema
-- ============================================================

-- Profiles (extends auth.users)
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  created_at timestamptz default now() not null
);

alter table public.profiles enable row level security;

create policy "Users can read any profile"
  on public.profiles for select
  using (true);

create policy "Users can update own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, new.raw_user_meta_data ->> 'display_name');
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- Productions
-- ============================================================

create table public.productions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  organizer_id uuid not null references auth.users(id),
  status text not null default 'draft' check (status in ('draft', 'active', 'archived')),
  created_at timestamptz default now() not null
);

alter table public.productions enable row level security;

create policy "Organizer can do anything"
  on public.productions for all
  using (auth.uid() = organizer_id);

-- ============================================================
-- Cast members
-- ============================================================

create table public.cast_members (
  id uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  role text not null default 'actor' check (role in ('organizer', 'actor', 'understudy')),
  character_name text,
  created_at timestamptz default now() not null,
  unique (production_id, user_id)
);

alter table public.cast_members enable row level security;

create policy "Cast members can read their own production cast"
  on public.cast_members for select
  using (
    exists (
      select 1 from public.cast_members cm
      where cm.production_id = cast_members.production_id
        and cm.user_id = auth.uid()
    )
  );

create policy "Organizer can manage cast"
  on public.cast_members for all
  using (
    exists (
      select 1 from public.productions
      where productions.id = cast_members.production_id
        and productions.organizer_id = auth.uid()
    )
  );

-- Deferred policy: needs cast_members table to exist
create policy "Cast members can read their productions"
  on public.productions for select
  using (
    exists (
      select 1 from public.cast_members
      where cast_members.production_id = productions.id
        and cast_members.user_id = auth.uid()
    )
  );

-- ============================================================
-- Recordings
-- ============================================================

create table public.recordings (
  id uuid primary key default gen_random_uuid(),
  production_id uuid not null references public.productions(id) on delete cascade,
  line_id text not null,
  user_id uuid not null references auth.users(id),
  audio_url text not null,
  duration_ms integer not null default 0,
  recorded_at timestamptz default now() not null,
  unique (production_id, line_id, user_id)
);

alter table public.recordings enable row level security;

create policy "Cast members can read production recordings"
  on public.recordings for select
  using (
    exists (
      select 1 from public.cast_members
      where cast_members.production_id = recordings.production_id
        and cast_members.user_id = auth.uid()
    )
  );

create policy "Users can insert own recordings"
  on public.recordings for insert
  with check (auth.uid() = user_id);

create policy "Users can update own recordings"
  on public.recordings for update
  using (auth.uid() = user_id);

-- ============================================================
-- Realtime (enable for recordings table)
-- ============================================================

alter publication supabase_realtime add table public.recordings;

-- ============================================================
-- Storage bucket for audio recordings
-- ============================================================

insert into storage.buckets (id, name, public)
values ('recordings', 'recordings', true)
on conflict (id) do nothing;

create policy "Cast members can upload recordings"
  on storage.objects for insert
  with check (
    bucket_id = 'recordings'
    and auth.role() = 'authenticated'
  );

create policy "Cast members can read recordings"
  on storage.objects for select
  using (
    bucket_id = 'recordings'
    and auth.role() = 'authenticated'
  );

create policy "Users can update own recordings"
  on storage.objects for update
  using (
    bucket_id = 'recordings'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
