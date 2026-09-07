-- Close the remaining join/storage authorization gaps and make script
-- replacement a single validated transaction. This is a forward-only migration;
-- historical migrations remain unchanged.

begin;

-- Direct pre-membership writes must never bypass the code-validating RPCs.
drop policy if exists "Users can self-join" on public.cast_members;
drop policy if exists "Users insert own membership" on public.cast_members;
drop policy if exists "Users can claim invitation" on public.cast_members;
drop policy if exists "Users can claim their invitation" on public.cast_members;
drop policy if exists "Organizers manage cast" on public.cast_members;
create policy "Organizers update production cast"
  on public.cast_members for update
  to authenticated
  using (public.is_production_organizer(production_id, auth.uid()))
  with check (public.is_production_organizer(production_id, auth.uid()));
create policy "Organizers delete production cast"
  on public.cast_members for delete
  to authenticated
  using (public.is_production_organizer(production_id, auth.uid()));


-- Signed-in members may edit their own presentation fields. Identity,
-- production, and role changes are enforced by the trigger below.
create policy "Users update own membership details"
  on public.cast_members for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create or replace function public.guard_cast_member_identity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.id is distinct from old.id
     or new.production_id is distinct from old.production_id then
    raise exception 'Cast membership identity and production are immutable';
  end if;

  if (new.user_id is distinct from old.user_id
      or new.role is distinct from old.role)
     and current_user not in ('postgres', 'service_role', 'supabase_admin') then
    raise exception 'Membership ownership and role changes require an authorized RPC';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_cast_member_identity on public.cast_members;
create trigger guard_cast_member_identity
before update on public.cast_members
for each row execute function public.guard_cast_member_identity();

-- Preserve a full copy of every pre-existing duplicate before deterministic
-- consolidation. The archive is deliberately inaccessible to app roles.
create table if not exists public.cast_members_duplicate_archive
  (like public.cast_members including defaults including generated);
alter table public.cast_members_duplicate_archive
  add column if not exists canonical_id uuid,
  add column if not exists archived_at timestamptz not null default now();
alter table public.cast_members_duplicate_archive enable row level security;
revoke all on table public.cast_members_duplicate_archive from anon, authenticated;

-- This lock makes consolidation plus index creation race-free. Deploy during a
-- measured maintenance window: Supabase migrations run transactionally, so a
-- concurrent index cannot safely cover the dedupe/index boundary.
lock table public.cast_members in share row exclusive mode;

with duplicate_groups as (
  select production_id, user_id,
         (array_agg(id order by created_at, id))[1] as canonical_id
  from public.cast_members
  where user_id is not null
  group by production_id, user_id
  having count(*) > 1
)
insert into public.cast_members_duplicate_archive
select cm.*, dg.canonical_id, now()
from public.cast_members cm
join duplicate_groups dg
  on dg.production_id = cm.production_id and dg.user_id = cm.user_id;

-- Field-by-field merge rule: keep the oldest stable id/created timestamp,
-- preserve the strongest role, prefer the newest nonblank human-entered value,
-- and retain the earliest invitation/join timestamps. Every original value is
-- still available in cast_members_duplicate_archive.
with duplicate_groups as (
  select production_id, user_id,
         (array_agg(id order by created_at, id))[1] as canonical_id,
         min(created_at) as created_at,
         min(invited_at) as invited_at,
         min(joined_at) as joined_at,
         (array_agg(role order by
            case role when 'organizer' then 0 when 'understudy' then 1 else 2 end,
            created_at desc, id))[1] as role,
         (array_agg(nullif(btrim(character_name), '') order by
            (nullif(btrim(character_name), '') is null), created_at desc, id))[1]
            as character_name,
         (array_agg(nullif(btrim(display_name), '') order by
            (nullif(btrim(display_name), '') is null), created_at desc, id))[1]
            as display_name,
         (array_agg(nullif(btrim(contact_info), '') order by
            (nullif(btrim(contact_info), '') is null), created_at desc, id))[1]
            as contact_info
  from public.cast_members
  where user_id is not null
  group by production_id, user_id
  having count(*) > 1
)
update public.cast_members cm
set role = dg.role,
    character_name = dg.character_name,
    display_name = coalesce(dg.display_name, ''),
    contact_info = dg.contact_info,
    invited_at = dg.invited_at,
    joined_at = dg.joined_at,
    created_at = dg.created_at
from duplicate_groups dg
where cm.id = dg.canonical_id;

with duplicate_groups as (
  select production_id, user_id,
         (array_agg(id order by created_at, id))[1] as canonical_id
  from public.cast_members
  where user_id is not null
  group by production_id, user_id
  having count(*) > 1
)
delete from public.cast_members cm
using duplicate_groups dg
where cm.production_id = dg.production_id
  and cm.user_id = dg.user_id
  and cm.id <> dg.canonical_id;

create unique index if not exists idx_cast_members_unique_production_user
  on public.cast_members (production_id, user_id)
  where user_id is not null;
create index if not exists idx_cast_members_user_production
  on public.cast_members (user_id, production_id);

-- The UNIQUE constraint on (production_id, sort_order) already owns an
-- identical btree.
drop index if exists public.idx_script_scenes_production;

-- New recording writes must reference a line in the same production. Existing
-- rows remain untouched for a later audited FK validation, while all new
-- INSERT/UPDATE operations fail closed. Script writes become RPC-only so a
-- direct delete cannot bypass replace_script's recorded-line restriction.
create or replace function public.enforce_recording_line_reference()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  line_uuid uuid;
begin
  begin
    line_uuid := new.line_id::uuid;
  exception when invalid_text_representation then
    raise exception 'Recording line_id must be a UUID';
  end;
  if not exists (
    select 1 from public.script_lines sl
    where sl.production_id = new.production_id and sl.id = line_uuid
  ) then
    raise exception 'Recording must reference a script line in its production';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_recording_line_reference on public.recordings;
create trigger enforce_recording_line_reference
before insert or update of production_id, line_id on public.recordings
for each row execute function public.enforce_recording_line_reference();

drop policy if exists "Organizer manages script lines" on public.script_lines;
drop policy if exists "Organizer can manage script lines" on public.script_lines;
drop policy if exists "Organizer can manage script scenes" on public.script_scenes;

-- A new take always uses a fresh key, so there is no legitimate object UPDATE
-- path. The owner/organizer/queued DELETE policy is installed below.
drop policy if exists "Members update recording objects" on storage.objects;

drop policy if exists "Members read recording objects" on storage.objects;
create policy "Members read recording objects"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'recordings'
    and (
      public.is_production_member(
        public.recording_object_production(name), auth.uid())
      or public.is_production_organizer(
        public.recording_object_production(name), auth.uid())
    )
  );

drop policy if exists "Members can read production recordings" on public.recordings;
create policy "Members can read production recordings"
  on public.recordings for select
  to authenticated
  using (
    public.is_production_member(production_id, auth.uid())
    or public.is_production_organizer(production_id, auth.uid())
  );

-- Metadata mutation is RPC-only so reference adoption, cleanup claiming, and
-- row deletion share the queue's serialization rules.
drop policy if exists "Users can insert own recordings" on public.recordings;
drop policy if exists "Users can update own recordings" on public.recordings;
drop policy if exists "Users delete own recordings" on public.recordings;

-- Metadata switches and their old-object cleanup intent commit together. The
-- client removes queued storage objects and acknowledges each row only after a
-- successful Storage API response, so network/process failure remains retryable.
alter table public.recordings add column if not exists object_name text;

create table if not exists public.recording_object_cleanup (
  id uuid primary key default gen_random_uuid(),
  production_id uuid not null,
  line_id text,
  requested_by uuid not null references auth.users(id) on delete cascade,
  object_name text not null,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (requested_by, object_name)
);
alter table public.recording_object_cleanup enable row level security;
revoke all on table public.recording_object_cleanup from anon, authenticated;


-- A queued cleanup row remains an authorization capability after its
-- production is deleted, when organizer lookup can no longer succeed.
create or replace function public.is_recording_cleanup_request(
  p_object_name text,
  p_user_id uuid
)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.recording_object_cleanup cleanup
    where p_user_id = auth.uid()
      and cleanup.requested_by = p_user_id
      and cleanup.object_name = p_object_name
      and cleanup.claimed_at is not null
  );
$$;

drop policy if exists "Owners delete recording objects" on storage.objects;
create policy "Owners delete recording objects"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'recordings'
    and (
      owner_id::text = auth.uid()::text
      or public.is_production_organizer(
        public.recording_object_production(name), auth.uid())
      or public.is_recording_cleanup_request(name, auth.uid())
    )
  );


create or replace function public.claim_recording_cleanup(
  p_production_id uuid,
  p_requested_by uuid
)
returns json
language sql
security definer
set search_path = public
as $$
  with claimed as (
    update public.recording_object_cleanup cleanup
    set claimed_at = now()
    where cleanup.production_id = p_production_id
      and cleanup.requested_by = p_requested_by
      and auth.uid() = p_requested_by
      and not exists (
        select 1 from public.recordings current_recording
        where current_recording.object_name = cleanup.object_name
      )
    returning cleanup.id, cleanup.object_name, cleanup.created_at
  )
  select coalesce(json_agg(json_build_object(
    'id', claimed.id,
    'object_name', claimed.object_name
  ) order by claimed.created_at, claimed.id), '[]'::json)
  from claimed;
$$;

create or replace function public.save_recording_metadata(
  p_production_id uuid,
  p_line_id text,
  p_user_id uuid,
  p_previous_audio_url text,
  p_previous_object_name text,
  p_audio_url text,
  p_object_name text,
  p_duration_ms integer,
  p_recorded_at timestamptz
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_url text;
  previous_object_name text;
  new_object_name text := p_object_name;
  queued_claimed_at timestamptz;
begin
  if auth.uid() is null or auth.uid() <> p_user_id
     or not public.is_production_member(p_production_id, auth.uid()) then
    raise exception 'Users may save only their own production recordings';
  end if;

  if new_object_name is null
     or public.recording_object_production(new_object_name) <> p_production_id
     or not exists (
       select 1 from storage.objects object
       where object.bucket_id = 'recordings'
         and object.name = new_object_name
         and object.owner_id::text = p_user_id::text
     ) then
    raise exception 'Recording URL must identify the caller-owned uploaded object';
  end if;

  -- Cancel a pending deletion when a stale device legitimately re-adopts this
  -- object. If cleanup has already been claimed, fail rather than racing an
  -- in-flight Storage DELETE.
  select cleanup.claimed_at into queued_claimed_at
  from public.recording_object_cleanup cleanup
  where cleanup.requested_by = p_user_id
    and cleanup.object_name = new_object_name
  for update;
  if found then
    if queued_claimed_at is not null then
      raise exception 'Recording object cleanup is already in progress';
    end if;
    delete from public.recording_object_cleanup cleanup
    where cleanup.requested_by = p_user_id
      and cleanup.object_name = new_object_name;
  end if;

  select r.audio_url, r.object_name
  into previous_url, previous_object_name
  from public.recordings r
  where r.production_id = p_production_id
    and r.line_id = p_line_id
    and r.user_id = p_user_id
  for update;
  if previous_object_name is null
     and previous_url is not null
     and previous_url = p_previous_audio_url then
    previous_object_name := p_previous_object_name;
  end if;

  insert into public.recordings
    (production_id, line_id, user_id, audio_url, object_name, duration_ms,
     recorded_at)
  values
    (p_production_id, p_line_id, p_user_id, p_audio_url, new_object_name,
     p_duration_ms, p_recorded_at)
  on conflict (production_id, line_id, user_id) do update set
    audio_url = excluded.audio_url,
    object_name = excluded.object_name,
    duration_ms = excluded.duration_ms,
    recorded_at = excluded.recorded_at;

  if previous_url is not null
     and previous_url <> p_audio_url
     and previous_object_name is not null
     and public.recording_object_production(previous_object_name) =
         p_production_id
     and exists (
       select 1 from storage.objects object
       where object.bucket_id = 'recordings'
         and object.name = previous_object_name
         and object.owner_id::text = p_user_id::text
     ) then
    insert into public.recording_object_cleanup
      (production_id, line_id, requested_by, object_name)
    values
      (p_production_id, p_line_id, p_user_id, previous_object_name)
    on conflict (requested_by, object_name) do update set
      production_id = excluded.production_id,
      line_id = excluded.line_id,
      claimed_at = null;
  end if;

  return json_build_object('saved', true);
end;
$$;

create or replace function public.delete_recording_metadata(
  p_production_id uuid,
  p_line_id text,
  p_user_id uuid,
  p_audio_url text,
  p_object_name text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_url text;
  deleted_object_name text;
  recovering boolean;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'Users may delete only their own recordings';
  end if;

  delete from public.recordings r
  where r.production_id = p_production_id
    and r.line_id = p_line_id
    and r.user_id = p_user_id
    and p_audio_url is not null
    and r.audio_url = p_audio_url
  returning r.audio_url, coalesce(
    r.object_name,
    case when r.audio_url = p_audio_url then p_object_name end
  )
  into deleted_url, deleted_object_name;

  if deleted_object_name is not null
     and public.recording_object_production(deleted_object_name) =
         p_production_id
     and exists (
       select 1 from storage.objects object
       where object.bucket_id = 'recordings'
         and object.name = deleted_object_name
         and object.owner_id::text = p_user_id::text
     ) then
    insert into public.recording_object_cleanup
      (production_id, line_id, requested_by, object_name)
    values
      (p_production_id, p_line_id, p_user_id, deleted_object_name)
    on conflict (requested_by, object_name) do update set
      production_id = excluded.production_id,
      line_id = excluded.line_id,
      claimed_at = null;
  end if;

  select exists (
    select 1 from public.recording_object_cleanup pending
    where pending.production_id = p_production_id
      and pending.line_id = p_line_id
      and pending.requested_by = p_user_id
  ) into recovering;

  return json_build_object('deleted', deleted_url is not null or recovering);
end;
$$;

-- Queue a fresh object that lost the race to a replacement take before it
-- could become metadata. The owner check prevents this RPC from turning the
-- cleanup outbox into a delete capability for another user's object.
create or replace function public.queue_recording_cleanup(
  p_production_id uuid,
  p_line_id text,
  p_user_id uuid,
  p_object_name text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  queued boolean;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'Users may queue only their own recording cleanup';
  end if;
  if public.recording_object_production(p_object_name) is distinct from
      p_production_id then
    raise exception 'Recording object belongs to another production';
  end if;
  if exists (
    select 1 from public.recordings current_recording
    where current_recording.object_name = p_object_name
  ) then
    raise exception 'Referenced recording objects cannot be discarded';
  end if;

  insert into public.recording_object_cleanup
    (production_id, line_id, requested_by, object_name)
  select p_production_id, p_line_id, p_user_id, p_object_name
  from storage.objects object
  where object.bucket_id = 'recordings'
    and object.name = p_object_name
    and object.owner_id::text = p_user_id::text
  on conflict (requested_by, object_name) do update set
    production_id = excluded.production_id,
    line_id = excluded.line_id,
    claimed_at = null;

  select exists (
    select 1 from public.recording_object_cleanup cleanup
    where cleanup.requested_by = p_user_id
      and cleanup.object_name = p_object_name
  ) or not exists (
    select 1 from storage.objects object
    where object.bucket_id = 'recordings'
      and object.name = p_object_name
  ) into queued;
  return queued;
end;
$$;

create or replace function public.complete_recording_cleanup(p_cleanup_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  removed_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in to complete recording cleanup';
  end if;
  delete from public.recording_object_cleanup cleanup
  where cleanup.id = p_cleanup_id
    and cleanup.claimed_at is not null
    and (
      cleanup.requested_by = auth.uid()
      or public.is_production_organizer(cleanup.production_id, auth.uid())
    )
  returning cleanup.id into removed_id;
  return removed_id is not null;
end;
$$;

-- Production deletion is RPC-only so every referenced recording object is
-- durably queued before relational cascades remove its metadata.
drop policy if exists "Organizer full access" on public.productions;
drop policy if exists "Organizer can do anything" on public.productions;
create policy "Organizers insert productions"
  on public.productions for insert
  to authenticated
  with check (organizer_id = auth.uid());
create policy "Organizers update productions"
  on public.productions for update
  to authenticated
  using (organizer_id = auth.uid())
  with check (organizer_id = auth.uid());
create policy "Organizers read productions"
  on public.productions for select
  to authenticated
  using (organizer_id = auth.uid());

create or replace function public.delete_production(p_production_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  owner_id uuid;
  recovering boolean;
begin
  if caller is null then
    raise exception 'Sign in to delete a production';
  end if;
  select p.organizer_id into owner_id
  from public.productions p
  where p.id = p_production_id
  for update;

  if owner_id is not null and owner_id <> caller then
    raise exception 'Only the production organizer may delete it';
  end if;
  if owner_id = caller then
    -- Wait for earlier uploads and block new storage writes until membership
    -- and production rows are gone, so every committed object is scanned.
    lock table storage.objects in share row exclusive mode;
    insert into public.recording_object_cleanup
      (production_id, line_id, requested_by, object_name)
    select
      p_production_id,
      (
        select min(r.line_id)
        from public.recordings r
        where r.production_id = p_production_id
          and r.object_name = object.name
      ),
      caller,
      object.name
    from storage.objects object
    where object.bucket_id = 'recordings'
      and public.recording_object_production(object.name) = p_production_id
    on conflict (requested_by, object_name) do update set
      production_id = excluded.production_id,
      line_id = excluded.line_id,
      claimed_at = null;

    delete from public.productions p where p.id = p_production_id;
  end if;

  select exists (
    select 1 from public.recording_object_cleanup cleanup
    where cleanup.production_id = p_production_id
      and cleanup.requested_by = caller
  ) into recovering;
  return json_build_object('deleted', owner_id = caller or recovering);
end;
$$;

-- Explicit, future-proof join lookup contract. These are exactly the fields
-- currently needed to construct the joined production locally.
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
  select json_build_object(
    'id', p.id,
    'title', p.title,
    'organizer_id', p.organizer_id,
    'join_code', p.join_code,
    'created_at', p.created_at,
    'locale', p.locale,
    'voice_preset', p.voice_preset
  ) into result
  from public.productions p
  where p.join_code = upper(lookup_code)
  limit 1;
  return result;
end;
$$;

-- Code-only pre-members receive a minimal claimable-slot contract. Existing
-- members and the organizer receive the full explicit sync contract.
create or replace function public.fetch_cast_for_join(prod_id text, code text)
returns json
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  result json;
  production_uuid uuid := prod_id::uuid;
  has_member_access boolean;
begin
  if auth.uid() is null then
    raise exception 'Sign in to fetch a production roster';
  end if;
  has_member_access :=
    public.is_production_member(production_uuid, auth.uid())
    or public.is_production_organizer(production_uuid, auth.uid());
  if not has_member_access and not exists (
    select 1 from public.productions p
    where p.id = production_uuid and p.join_code = upper(code)
  ) then
    raise exception 'Invalid join code for this production';
  end if;

  if has_member_access then
    select coalesce(json_agg(json_build_object(
      'id', cm.id,
      'production_id', cm.production_id,
      'character_name', cm.character_name,
      'display_name', cm.display_name,
      'role', cm.role,
      'user_id', cm.user_id,
      'contact_info', cm.contact_info,
      'invited_at', cm.invited_at,
      'joined_at', cm.joined_at,
      'is_claimed', cm.user_id is not null
    ) order by cm.created_at, cm.id), '[]'::json)
    into result
    from public.cast_members cm
    where cm.production_id = production_uuid;
  else
    select coalesce(json_agg(json_build_object(
      'id', cm.id,
      'character_name', cm.character_name,
      'role', cm.role,
      'is_claimed', cm.user_id is not null
    ) order by cm.created_at, cm.id), '[]'::json)
    into result
    from public.cast_members cm
    where cm.production_id = production_uuid;
  end if;
  return result;
end;
$$;

-- Idempotent against the exact partial uniqueness predicate.
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
  caller uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  member_id uuid;
begin
  if caller is null then
    raise exception 'Sign in to join a production';
  end if;
  if not exists (
    select 1 from public.productions p
    where p.id = production_uuid and p.join_code = upper(code)
  ) then
    raise exception 'Invalid join code for this production';
  end if;

  insert into public.cast_members
    (production_id, user_id, character_name, display_name, role, joined_at)
  values (production_uuid, caller, char_name, display_name, 'actor', now())
  on conflict (production_id, user_id) where user_id is not null do nothing
  returning id into member_id;

  if member_id is null then
    select cm.id into member_id
    from public.cast_members cm
    where cm.production_id = production_uuid and cm.user_id = caller;
  end if;
  return json_build_object('id', member_id);
end;
$$;

drop function if exists public.claim_cast_invitation(text, text);
create or replace function public.claim_cast_invitation(member_id text, code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  invitation_id uuid := member_id::uuid;
  production_uuid uuid;
  claimed_user uuid;
begin
  if caller is null then
    raise exception 'Sign in to claim an invitation';
  end if;

  select cm.production_id, cm.user_id
  into production_uuid, claimed_user
  from public.cast_members cm
  where cm.id = invitation_id;

  if production_uuid is null then
    return 'already_claimed';
  end if;
  if not exists (
    select 1 from public.productions p
    where p.id = production_uuid and p.join_code = upper(code)
  ) then
    return 'invalid_code';
  end if;
  if claimed_user is not null then
    return 'already_claimed';
  end if;

  update public.cast_members cm
  set user_id = caller, joined_at = now()
  where cm.id = invitation_id and cm.user_id is null;
  if found then
    return 'claimed';
  end if;
  return 'already_claimed';
end;
$$;

-- Invitation creation is retry-safe when the client supplies its durable local
-- id. A conflicting reuse of that id fails rather than adopting another row.
create or replace function public.create_cast_invitation(
  p_id uuid,
  p_production_id uuid,
  p_character_name text,
  p_display_name text,
  p_contact_info text,
  p_role text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  invitation_id uuid := coalesce(p_id, gen_random_uuid());
  invitation_row public.cast_members%rowtype;
begin
  if auth.uid() is null
     or not public.is_production_organizer(p_production_id, auth.uid()) then
    raise exception 'Only the production organizer may create invitations';
  end if;

  insert into public.cast_members
    (id, production_id, character_name, display_name, contact_info, role,
     invited_at)
  values
    (invitation_id, p_production_id, p_character_name, p_display_name,
     p_contact_info, p_role, now())
  on conflict (id) do nothing;

  select cm.* into invitation_row
  from public.cast_members cm
  where cm.id = invitation_id;
  if invitation_row.production_id is distinct from p_production_id
     or invitation_row.user_id is not null
     or invitation_row.character_name is distinct from p_character_name
     or invitation_row.display_name is distinct from p_display_name
     or invitation_row.contact_info is distinct from p_contact_info
     or invitation_row.role is distinct from p_role then
    raise exception 'Invitation id is already in use with different values';
  end if;
  return row_to_json(invitation_row);
end;
$$;

-- Production creation and its organizer membership commit together. Supplying
-- the same id/join code is an idempotent retry; a conflicting id fails closed.
create or replace function public.create_production(
  p_id uuid,
  p_title text,
  p_join_code text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  production_uuid uuid := coalesce(p_id, gen_random_uuid());
  production_row public.productions%rowtype;
begin
  if caller is null then
    raise exception 'Sign in to create a production';
  end if;
  if nullif(btrim(p_title), '') is null or nullif(btrim(p_join_code), '') is null then
    raise exception 'Production title and join code are required';
  end if;

  insert into public.productions
    (id, title, organizer_id, status, join_code)
  values
    (production_uuid, p_title, caller, 'draft', upper(p_join_code))
  on conflict (id) do nothing;

  select p.* into production_row
  from public.productions p
  where p.id = production_uuid;
  if production_row.organizer_id is distinct from caller
     or production_row.title is distinct from p_title
     or production_row.join_code is distinct from upper(p_join_code) then
    raise exception 'Production id is already in use with different values';
  end if;

  insert into public.cast_members
    (production_id, user_id, role, joined_at)
  values
    (production_uuid, caller, 'organizer', now())
  on conflict (production_id, user_id) where user_id is not null
  do update set role = 'organizer';

  return json_build_object(
    'id', production_row.id,
    'title', production_row.title,
    'organizer_id', production_row.organizer_id,
    'status', production_row.status,
    'join_code', production_row.join_code,
    'created_at', production_row.created_at,
    'locale', production_row.locale
  );
end;
$$;

-- Atomically replace lines and scenes. Payloads are completely validated before
-- any row changes. Removed lines with recordings are RESTRICTed in application
-- semantics; therefore this migration intentionally does not add DAT-008's
-- composite line FK yet.
alter table public.productions
  add column if not exists script_revision uuid,
  add column if not exists script_line_count integer not null default 0,
  add column if not exists script_scene_count integer not null default 0;

create or replace function public.replace_script(
  p_production_id uuid,
  p_lines jsonb,
  p_scenes jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  revision uuid := gen_random_uuid();
  line_count integer;
  scene_count integer;
begin
  if auth.uid() is null
     or not public.is_production_organizer(p_production_id, auth.uid()) then
    raise exception 'Only the production organizer may replace its script';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_typeof(p_scenes) <> 'array' then
    raise exception 'Script lines and scenes must be JSON arrays';
  end if;

  line_count := jsonb_array_length(p_lines);
  scene_count := jsonb_array_length(p_scenes);

  for item in select value from jsonb_array_elements(p_lines) loop
    if jsonb_typeof(item) <> 'object'
       or not (item ?& array['id', 'production_id', 'order_index', 'line_number'])
       or (item->>'production_id')::uuid <> p_production_id
       or (item->>'order_index')::integer < 0
       or (item->>'line_number')::integer < 0
       or coalesce(item->>'line_type', 'dialogue') not in
          ('dialogue', 'stageDirection', 'header', 'song')
       or (item ? 'multi_characters'
           and item->'multi_characters' <> 'null'::jsonb
           and jsonb_typeof(item->'multi_characters') <> 'array') then
      raise exception 'Invalid script line payload';
    end if;
    perform (item->>'id')::uuid;
  end loop;

  for item in select value from jsonb_array_elements(p_scenes) loop
    if jsonb_typeof(item) <> 'object'
       or not (item ?& array['id', 'production_id', 'sort_order',
                              'start_line_index', 'end_line_index'])
       or (item->>'production_id')::uuid <> p_production_id
       or (item->>'sort_order')::integer < 0
       or (item->>'start_line_index')::integer < 0
       or (item->>'end_line_index')::integer < (item->>'start_line_index')::integer then
      raise exception 'Invalid script scene payload';
    end if;
    perform (item->>'id')::uuid;
  end loop;

  if exists (
    select 1 from (
      select (value->>'id')::uuid id, count(*)
      from jsonb_array_elements(p_lines) group by 1 having count(*) > 1
      union all
      select null::uuid, count(*)
      from jsonb_array_elements(p_lines) group by (value->>'order_index')::integer
      having count(*) > 1
    ) duplicates
  ) or exists (
    select 1 from (
      select (value->>'id')::uuid id, count(*)
      from jsonb_array_elements(p_scenes) group by 1 having count(*) > 1
      union all
      select null::uuid, count(*)
      from jsonb_array_elements(p_scenes) group by (value->>'sort_order')::integer
      having count(*) > 1
    ) duplicates
  ) then
    raise exception 'Script payload contains duplicate ids or ordering values';
  end if;

  -- Serialize against recording uploads and other replacements between the
  -- reference check and adoption of the new revision.
  lock table public.script_lines in share row exclusive mode;
  lock table public.script_scenes in share row exclusive mode;
  lock table public.recordings in share row exclusive mode;

  if exists (
    select 1 from public.script_lines sl
    join jsonb_array_elements(p_lines) payload
      on (payload->>'id')::uuid = sl.id
    where sl.production_id <> p_production_id
  ) or exists (
    select 1 from public.script_scenes ss
    join jsonb_array_elements(p_scenes) payload
      on (payload->>'id')::uuid = ss.id
    where ss.production_id <> p_production_id
  ) then
    raise exception 'Script payload contains ids owned by another production';
  end if;

  if exists (
    select 1
    from public.script_lines sl
    join public.recordings r
      on r.production_id = sl.production_id
     and lower(r.line_id) = sl.id::text
    where sl.production_id = p_production_id
      and not exists (
        select 1 from jsonb_array_elements(p_lines) payload
        where (payload->>'id')::uuid = sl.id
      )
  ) then
    raise exception 'Recorded script lines cannot be removed';
  end if;

  -- Move current ordering values out of the nonnegative payload range so
  -- arbitrary reorderings cannot transiently violate the unique constraints.
  update public.script_lines sl
  set order_index = displaced.value
  from (
    select id, -row_number() over (order by id)::integer as value
    from public.script_lines where production_id = p_production_id
  ) displaced
  where sl.id = displaced.id;

  insert into public.script_lines
    (id, production_id, order_index, act, scene, line_number, character,
     line_text, line_type, stage_direction, multi_characters, updated_at)
  select
    (value->>'id')::uuid,
    p_production_id,
    (value->>'order_index')::integer,
    coalesce(value->>'act', ''),
    coalesce(value->>'scene', ''),
    (value->>'line_number')::integer,
    coalesce(value->>'character', ''),
    coalesce(value->>'line_text', ''),
    coalesce(value->>'line_type', 'dialogue'),
    coalesce(value->>'stage_direction', ''),
    value->'multi_characters',
    now()
  from jsonb_array_elements(p_lines)
  on conflict (id) do update set
    order_index = excluded.order_index,
    act = excluded.act,
    scene = excluded.scene,
    line_number = excluded.line_number,
    character = excluded.character,
    line_text = excluded.line_text,
    line_type = excluded.line_type,
    stage_direction = excluded.stage_direction,
    multi_characters = excluded.multi_characters,
    updated_at = excluded.updated_at;

  delete from public.script_lines sl
  where sl.production_id = p_production_id
    and not exists (
      select 1 from jsonb_array_elements(p_lines) payload
      where (payload->>'id')::uuid = sl.id
    );

  update public.script_scenes ss
  set sort_order = displaced.value
  from (
    select id, -row_number() over (order by id)::integer as value
    from public.script_scenes where production_id = p_production_id
  ) displaced
  where ss.id = displaced.id;

  insert into public.script_scenes
    (id, production_id, sort_order, scene_name, act, location, description,
     start_line_index, end_line_index, characters, updated_at)
  select
    (value->>'id')::uuid,
    p_production_id,
    (value->>'sort_order')::integer,
    coalesce(value->>'scene_name', ''),
    coalesce(value->>'act', ''),
    coalesce(value->>'location', ''),
    coalesce(value->>'description', ''),
    (value->>'start_line_index')::integer,
    (value->>'end_line_index')::integer,
    coalesce(value->>'characters', ''),
    now()
  from jsonb_array_elements(p_scenes)
  on conflict (id) do update set
    sort_order = excluded.sort_order,
    scene_name = excluded.scene_name,
    act = excluded.act,
    location = excluded.location,
    description = excluded.description,
    start_line_index = excluded.start_line_index,
    end_line_index = excluded.end_line_index,
    characters = excluded.characters,
    updated_at = excluded.updated_at;

  delete from public.script_scenes ss
  where ss.production_id = p_production_id
    and not exists (
      select 1 from jsonb_array_elements(p_scenes) payload
      where (payload->>'id')::uuid = ss.id
    );

  update public.productions
  set script_revision = revision,
      script_line_count = line_count,
      script_scene_count = scene_count
  where id = p_production_id;

  return jsonb_build_object(
    'revision', revision,
    'line_count', line_count,
    'scene_count', scene_count
  );
end;
$$;

-- New functions are executable by PUBLIC by default. Remove that default from
-- every current or legacy overload, then grant only the intended app role.
do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'check_join_rate_limit',
        'lookup_production_by_join_code',
        'fetch_cast_for_join',
        'join_production',
        'claim_cast_invitation',
        'replace_script',
        'create_production',
        'create_cast_invitation',
        'save_recording_metadata',
        'delete_recording_metadata',
        'queue_recording_cleanup',
        'complete_recording_cleanup',
        'claim_recording_cleanup',
        'is_recording_cleanup_request',
        'delete_production'
      )
  loop
    execute format('revoke all on function %s from public, anon', fn);
  end loop;
end;
$$;

grant execute on function public.lookup_production_by_join_code(text) to authenticated;
grant execute on function public.fetch_cast_for_join(text, text) to authenticated;
grant execute on function public.join_production(text, text, text, text) to authenticated;
grant execute on function public.claim_cast_invitation(text, text) to authenticated;
grant execute on function public.replace_script(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.create_production(uuid, text, text) to authenticated;
grant execute on function public.create_cast_invitation(
  uuid, uuid, text, text, text, text
) to authenticated;
grant execute on function public.save_recording_metadata(
  uuid, text, uuid, text, text, text, text, integer, timestamptz
) to authenticated;
grant execute on function public.delete_recording_metadata(
  uuid, text, uuid, text, text
) to authenticated;
grant execute on function public.queue_recording_cleanup(
  uuid, text, uuid, text
) to authenticated;
grant execute on function public.complete_recording_cleanup(uuid) to authenticated;
grant execute on function public.claim_recording_cleanup(uuid, uuid) to authenticated;
grant execute on function public.is_recording_cleanup_request(text, uuid)
  to authenticated;
grant execute on function public.delete_production(uuid) to authenticated;

commit;
