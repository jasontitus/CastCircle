-- Security, correctness, and retention fixes from the 2026-08 Supabase review.
-- Bound lock acquisition during live migration rather than queueing traffic
-- indefinitely behind hot tables and indexes.
set lock_timeout = '5s';

-- Serialize each account's rate-limit window and retire stale attempts from all
-- accounts. The attempted_at index makes the bounded global cleanup cheap.
create index if not exists idx_join_code_attempts_time
  on public.join_code_attempts (attempted_at);

create or replace function public.check_join_rate_limit()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  recent integer;
begin
  if caller_id is null then
    raise exception 'Sign in to verify a join code';
  end if;

  -- Prevent concurrent requests for one account from all passing the count
  -- before any of them records its attempt.
  perform pg_advisory_xact_lock(hashtextextended(caller_id::text, 1129270853));

  -- Each request removes substantially more expired rows than it creates,
  -- including rows left by accounts that never return.
  delete from public.join_code_attempts
  where ctid in (
    select ctid
    from public.join_code_attempts
    where attempted_at < now() - interval '1 hour'
    order by attempted_at
    limit 1000
    for update skip locked
  );

  select count(*) into recent
  from public.join_code_attempts
  where user_id = caller_id
    and attempted_at > now() - interval '5 minutes';

  if recent >= 20 then
    raise exception 'Too many join-code attempts — try again in a few minutes';
  end if;

  insert into public.join_code_attempts (user_id) values (caller_id);
end;
$$;

revoke execute on function public.check_join_rate_limit() from public, anon, authenticated;

-- Every pre-membership code check goes through the same rate limiter.
create or replace function public.verify_join_code(prod_id uuid, code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.check_join_rate_limit();
  return exists (
    select 1
    from public.productions p
    where p.id = prod_id
      and p.join_code = upper(code)
  );
end;
$$;

revoke execute on function public.verify_join_code(uuid, text) from public, anon, authenticated;

-- A code lookup exposes only the pre-join identity contract, not organizer
-- account identifiers, standing credentials, or future production columns.
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
  select json_build_object('id', p.id, 'title', p.title) into result
  from public.productions p
  where p.join_code = upper(lookup_code)
  limit 1;
  return result;
end;
$$;

revoke execute on function public.lookup_production_by_join_code(text) from public, anon;
grant execute on function public.lookup_production_by_join_code(text) to authenticated;

-- Before joining, expose whether a role is claimable without disclosing linked
-- auth account UUIDs. Existing members retain the full roster contract.
create or replace function public.fetch_cast_for_join(prod_id text, code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  caller_is_member boolean;
  result json;
begin
  if caller_id is null then
    raise exception 'Sign in to view this cast';
  end if;

  caller_is_member := public.is_production_member(production_uuid, caller_id);
  if not caller_is_member then
    if not public.verify_join_code(production_uuid, code) then
      raise exception 'Invalid join code for this production';
    end if;
  end if;

  select coalesce(json_agg(
    case when caller_is_member then
      json_build_object(
        'id', cm.id,
        'production_id', cm.production_id,
        'character_name', cm.character_name,
        'display_name', cm.display_name,
        'role', cm.role,
        'claimed', cm.user_id is not null,
        'user_id', cm.user_id)
    else
      json_build_object(
        'id', cm.id,
        'production_id', cm.production_id,
        'character_name', cm.character_name,
        'display_name', cm.display_name,
        'role', cm.role,
        'claimed', cm.user_id is not null)
    end
  ), '[]'::json) into result
  from public.cast_members cm
  where cm.production_id = production_uuid;

  return result;
end;
$$;

revoke execute on function public.fetch_cast_for_join(text, text) from public, anon;
grant execute on function public.fetch_cast_for_join(text, text) to authenticated;

-- Large sync reads should build the caller's small membership set once rather
-- than invoking a non-inlineable SECURITY DEFINER probe for every result row.
create or replace function public.current_user_production_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public
as $$
  select cm.production_id
  from public.cast_members cm
  where cm.user_id = auth.uid();
$$;

revoke execute on function public.current_user_production_ids() from public, anon;
grant execute on function public.current_user_production_ids() to authenticated;

drop policy if exists "Members can read production recordings" on public.recordings;
create policy "Members can read production recordings"
  on public.recordings for select
  to authenticated
  using (
    production_id in (select public.current_user_production_ids())
  );

drop policy if exists "Members read script lines" on public.script_lines;
create policy "Members read script lines"
  on public.script_lines for select
  to authenticated
  using (
    production_id in (select public.current_user_production_ids())
  );

drop policy if exists "Cast members can read script scenes" on public.script_scenes;
create policy "Cast members can read script scenes"
  on public.script_scenes for select
  to authenticated
  using (
    production_id in (select public.current_user_production_ids())
  );

drop policy if exists "Members read recording objects" on storage.objects;
create policy "Members read recording objects"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'recordings'
    and public.recording_object_production(name)
      in (select public.current_user_production_ids())
  );

-- A cast row's organizer label is authoritative only when the production names
-- that same account as organizer. Normalize spoofed/stale organizer labels
-- before choosing which duplicate membership survives.
update public.cast_members cm
set role = 'actor'
where cm.role = 'organizer'
  and (
    cm.user_id is null
    or not exists (
      select 1
      from public.productions p
      where p.id = cm.production_id
        and p.organizer_id = cm.user_id
    )
  );

-- Remove duplicate claimed memberships before restoring the intended database
-- invariant. Prefer only an authoritative organizer row, then the earliest
-- joined row.
with ranked_memberships as (
  select
    cm.id,
    row_number() over (
      partition by cm.production_id, cm.user_id
      order by
        case when cm.role = 'organizer' and exists (
          select 1
          from public.productions p
          where p.id = cm.production_id
            and p.organizer_id = cm.user_id
        ) then 0 else 1 end,
        cm.joined_at nulls last,
        cm.created_at,
        cm.id
    ) as duplicate_number
  from public.cast_members cm
  where cm.user_id is not null
)
delete from public.cast_members cm
using ranked_memberships duplicate
where cm.id = duplicate.id
  and duplicate.duplicate_number > 1;

create unique index if not exists cast_members_production_user_unique
  on public.cast_members (production_id, user_id)
  where user_id is not null;

-- Keep the full production-leading index for invitation/roster scans; the
-- partial unique index excludes unclaimed rows. The reverse index supports the
-- current-user membership-set helper without scanning all productions.
create index if not exists idx_cast_members_production_user
  on public.cast_members (production_id, user_id);
create index if not exists idx_cast_members_user_production
  on public.cast_members (user_id, production_id)
  where user_id is not null;

-- One character has one primary assignment across organizer devices. Preserve
-- an authoritative claimed row first, then any other claimed row, then the
-- oldest invitation; demote the remaining duplicates to understudy.
with ranked_primary_roles as (
  select
    cm.id,
    row_number() over (
      partition by cm.production_id, lower(btrim(cm.character_name))
      order by
        case
          when cm.user_id is not null and exists (
            select 1
            from public.productions p
            where p.id = cm.production_id
              and p.organizer_id = cm.user_id
          ) then 0
          when cm.user_id is not null then 1
          else 2
        end,
        cm.joined_at nulls last,
        cm.created_at,
        cm.id
    ) as duplicate_number
  from public.cast_members cm
  where cm.role = 'actor'
    and nullif(btrim(cm.character_name), '') is not null
)
update public.cast_members cm
set role = 'understudy'
from ranked_primary_roles duplicate
where cm.id = duplicate.id
  and duplicate.duplicate_number > 1;

create unique index if not exists cast_members_primary_character_unique
  on public.cast_members (
    production_id,
    lower(btrim(character_name))
  )
  where role = 'actor'
    and nullif(btrim(character_name), '') is not null;

-- Audit tools share authenticated accounts. A server-side lease group keeps a
-- temporary membership alive until the last concurrent process releases it.
create table if not exists public.audit_membership_groups (
  production_id uuid not null references public.productions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  membership_id uuid not null references public.cast_members(id) on delete cascade,
  created_membership boolean not null,
  created_at timestamptz not null default now(),
  primary key (production_id, user_id)
);

create table if not exists public.audit_membership_leases (
  id uuid primary key default gen_random_uuid(),
  production_id uuid not null,
  user_id uuid not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  foreign key (production_id, user_id)
    references public.audit_membership_groups(production_id, user_id)
    on delete cascade
);

create index if not exists idx_audit_membership_leases_expiry
  on public.audit_membership_leases (expires_at);

alter table public.audit_membership_groups enable row level security;
alter table public.audit_membership_leases enable row level security;
revoke all on public.audit_membership_groups from anon, authenticated;
revoke all on public.audit_membership_leases from anon, authenticated;

-- Joining is authenticated, code-gated, and idempotent. A retry returns the
-- existing membership without changing its organizer-assigned attributes.
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
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  result json;
  audit_membership_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in to join a production';
  end if;

  if not public.verify_join_code(production_uuid, code) then
    raise exception 'Invalid join code for this production';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    production_uuid::text || ':' || caller_id::text,
    1096107081
  ));

  select groups.membership_id into audit_membership_id
  from public.audit_membership_groups groups
  where groups.production_id = production_uuid
    and groups.user_id = caller_id
    and groups.created_membership;

  if audit_membership_id is not null then
    update public.cast_members cm
    set character_name = char_name,
        display_name = join_production.display_name,
        role = 'actor',
        joined_at = now()
    where cm.id = audit_membership_id
    returning row_to_json(cm.*) into result;

    update public.audit_membership_groups
    set created_membership = false
    where production_id = production_uuid
      and user_id = caller_id;

    return result;
  end if;

  insert into public.cast_members (
    production_id, user_id, character_name, display_name, role, joined_at)
  values (
    production_uuid, caller_id, char_name, display_name, 'actor', now())
  on conflict (production_id, user_id) where user_id is not null
  do update set user_id = excluded.user_id
  returning row_to_json(cast_members.*) into result;

  -- A normal join promotes any temporary audit-created membership to a real
  -- user-owned membership so audit lease release cannot remove it.
  update public.audit_membership_groups
  set created_membership = false
  where production_id = production_uuid
    and user_id = caller_id;

  return result;
end;
$$;

revoke execute on function public.join_production(text, text, text, text) from public, anon;
grant execute on function public.join_production(text, text, text, text) to authenticated;

-- Organizer cast creation returns typed conflicts instead of forcing clients
-- to parse Postgres error strings. It covers both unclaimed invitations and
-- direct assignments.
drop function if exists public.create_cast_member(
  text, text, text, text, text, text, text
);
create function public.create_cast_member(
  prod_id text,
  char_name text,
  new_display_name text,
  member_role text,
  contact_info text default null,
  assigned_user_id text default null,
  member_id text default null,
  invited_at_value timestamptz default null,
  joined_at_value timestamptz default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  target_user_id uuid :=
    case when assigned_user_id is null then null else assigned_user_id::uuid end;
  target_member_id uuid :=
    case when member_id is null then gen_random_uuid() else member_id::uuid end;
  result json;
  violated_constraint text;
  audit_membership_id uuid;
begin
  if caller_id is null
     or not public.is_production_organizer(production_uuid, caller_id) then
    raise exception 'Only the production organizer can create cast members';
  end if;

  if member_role not in ('actor', 'understudy') then
    raise exception 'Cast role must be actor or understudy';
  end if;
  if member_role = 'actor' and nullif(btrim(char_name), '') is null then
    raise exception 'A primary cast member requires a character name';
  end if;

  if target_user_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(
      production_uuid::text || ':' || target_user_id::text,
      1096107081
    ));
  end if;

  if target_user_id is not null then
    select groups.membership_id into audit_membership_id
    from public.audit_membership_groups groups
    where groups.production_id = production_uuid
      and groups.user_id = target_user_id
      and groups.created_membership;

    if audit_membership_id is not null then
      update public.cast_members cm
      set character_name = char_name,
          display_name = new_display_name,
          contact_info = create_cast_member.contact_info,
          role = member_role,
          invited_at = coalesce(invited_at_value, cm.invited_at, now()),
          joined_at = coalesce(joined_at_value, now())
      where cm.id = audit_membership_id
      returning row_to_json(cm.*) into result;

      update public.audit_membership_groups
      set created_membership = false
      where production_id = production_uuid
        and user_id = target_user_id;

      return json_build_object('status', 'created', 'member', result);
    end if;
  end if;

  insert into public.cast_members (
    id,
    production_id,
    user_id,
    character_name,
    display_name,
    contact_info,
    role,
    invited_at,
    joined_at
  )
  values (
    target_member_id,
    production_uuid,
    target_user_id,
    char_name,
    new_display_name,
    contact_info,
    member_role,
    coalesce(invited_at_value, now()),
    coalesce(
      joined_at_value,
      case when target_user_id is null then null else now() end
    )
  )
  returning row_to_json(cast_members.*) into result;

  return json_build_object('status', 'created', 'member', result);
exception when unique_violation then
  get stacked diagnostics violated_constraint = constraint_name;
  if violated_constraint = 'cast_members_primary_character_unique' then
    return json_build_object('status', 'already_assigned', 'member', null);
  end if;
  if violated_constraint = 'cast_members_production_user_unique' then
    update public.audit_membership_groups
    set created_membership = false
    where production_id = production_uuid
      and user_id = target_user_id;
    return json_build_object('status', 'already_member', 'member', null);
  end if;
  if violated_constraint = 'cast_members_pkey' then
    select row_to_json(cm.*) into result
    from public.cast_members cm
    where cm.id = target_member_id
      and cm.production_id = production_uuid;
    if result is null then
      raise exception 'Cast member id belongs to another production';
    end if;
    return json_build_object('status', 'already_exists', 'member', result);
  end if;
  raise;
end;
$$;

revoke execute on function public.create_cast_member(
  text, text, text, text, text, text, text, timestamptz, timestamptz
) from public, anon;
grant execute on function public.create_cast_member(
  text, text, text, text, text, text, text, timestamptz, timestamptz
) to authenticated;

create or replace function public.cleanup_expired_audit_memberships()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  lease_group record;
  group_membership_id uuid;
  group_created_membership boolean;
begin
  for lease_group in
    select distinct leases.production_id, leases.user_id
    from public.audit_membership_leases leases
    where leases.expires_at <= now()
    order by leases.production_id, leases.user_id
    limit 100
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      lease_group.production_id::text || ':' || lease_group.user_id::text,
      1096107081
    ));

    delete from public.audit_membership_leases leases
    where leases.production_id = lease_group.production_id
      and leases.user_id = lease_group.user_id
      and leases.expires_at <= now();

    if not exists (
      select 1
      from public.audit_membership_leases leases
      where leases.production_id = lease_group.production_id
        and leases.user_id = lease_group.user_id
    ) then
      select groups.membership_id, groups.created_membership
      into group_membership_id, group_created_membership
      from public.audit_membership_groups groups
      where groups.production_id = lease_group.production_id
        and groups.user_id = lease_group.user_id;

      if group_created_membership then
        delete from public.cast_members cm
        where cm.id = group_membership_id
          and cm.production_id = lease_group.production_id
          and cm.user_id = lease_group.user_id;
      end if;

      delete from public.audit_membership_groups groups
      where groups.production_id = lease_group.production_id
        and groups.user_id = lease_group.user_id;
    end if;
  end loop;
end;
$$;

revoke execute on function public.cleanup_expired_audit_memberships()
  from public, anon, authenticated;

create or replace function public.begin_audit_membership(
  prod_id text,
  code text,
  char_name text default 'Audit',
  display_name text default 'Audit'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  group_membership_id uuid;
  group_created_membership boolean;
  inserted_membership_id uuid;
  lease_id uuid;
  lease_expiry timestamptz := now() + interval '6 hours';
begin
  if caller_id is null then
    raise exception 'Sign in to begin an audit membership';
  end if;
  if not public.verify_join_code(production_uuid, code) then
    raise exception 'Invalid join code for this production';
  end if;

  perform public.cleanup_expired_audit_memberships();
  perform pg_advisory_xact_lock(hashtextextended(
    production_uuid::text || ':' || caller_id::text,
    1096107081
  ));

  -- Reap this group again after acquiring its lock in case it was not in the
  -- bounded global cleanup batch.
  delete from public.audit_membership_leases leases
  where leases.production_id = production_uuid
    and leases.user_id = caller_id
    and leases.expires_at <= now();

  select groups.membership_id, groups.created_membership
  into group_membership_id, group_created_membership
  from public.audit_membership_groups groups
  where groups.production_id = production_uuid
    and groups.user_id = caller_id;

  if group_membership_id is not null and not exists (
    select 1
    from public.audit_membership_leases leases
    where leases.production_id = production_uuid
      and leases.user_id = caller_id
  ) then
    if group_created_membership then
      delete from public.cast_members cm
      where cm.id = group_membership_id
        and cm.production_id = production_uuid
        and cm.user_id = caller_id;
    end if;
    delete from public.audit_membership_groups groups
    where groups.production_id = production_uuid
      and groups.user_id = caller_id;
    group_membership_id := null;
  end if;

  if group_membership_id is null then
    select cm.id into group_membership_id
    from public.cast_members cm
    where cm.production_id = production_uuid
      and cm.user_id = caller_id;

    group_created_membership := false;
    if group_membership_id is null then
      insert into public.cast_members (
        production_id,
        user_id,
        character_name,
        display_name,
        role,
        joined_at
      )
      values (
        production_uuid,
        caller_id,
        begin_audit_membership.char_name,
        begin_audit_membership.display_name,
        'understudy',
        now()
      )
      on conflict (production_id, user_id) where user_id is not null
      do nothing
      returning id into inserted_membership_id;

      if inserted_membership_id is not null then
        group_membership_id := inserted_membership_id;
        group_created_membership := true;
      else
        select cm.id into group_membership_id
        from public.cast_members cm
        where cm.production_id = production_uuid
          and cm.user_id = caller_id;
      end if;
    end if;

    insert into public.audit_membership_groups (
      production_id,
      user_id,
      membership_id,
      created_membership
    )
    values (
      production_uuid,
      caller_id,
      group_membership_id,
      group_created_membership
    );
  end if;

  insert into public.audit_membership_leases (
    production_id,
    user_id,
    expires_at
  )
  values (production_uuid, caller_id, lease_expiry)
  returning id into lease_id;

  return json_build_object(
    'lease_id', lease_id,
    'membership_id', group_membership_id,
    'expires_at', lease_expiry
  );
end;
$$;

revoke execute on function public.begin_audit_membership(text, text, text, text)
  from public, anon;
grant execute on function public.begin_audit_membership(text, text, text, text)
  to authenticated;

create or replace function public.end_audit_membership(lease_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  lease_uuid uuid := lease_id::uuid;
  lease_production_id uuid;
  lease_user_id uuid;
  group_membership_id uuid;
  group_created_membership boolean;
begin
  if caller_id is null then
    raise exception 'Sign in to end an audit membership';
  end if;

  select leases.production_id, leases.user_id
  into lease_production_id, lease_user_id
  from public.audit_membership_leases leases
  where leases.id = lease_uuid;

  if lease_production_id is null then
    return 'already_absent';
  end if;
  if lease_user_id <> caller_id then
    raise exception 'Audit membership lease belongs to another account';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    lease_production_id::text || ':' || lease_user_id::text,
    1096107081
  ));

  delete from public.audit_membership_leases leases
  where leases.id = lease_uuid
    and leases.user_id = caller_id;
  if not found then
    return 'already_absent';
  end if;

  delete from public.audit_membership_leases leases
  where leases.production_id = lease_production_id
    and leases.user_id = caller_id
    and leases.expires_at <= now();

  if not exists (
    select 1
    from public.audit_membership_leases leases
    where leases.production_id = lease_production_id
      and leases.user_id = caller_id
  ) then
    select groups.membership_id, groups.created_membership
    into group_membership_id, group_created_membership
    from public.audit_membership_groups groups
    where groups.production_id = lease_production_id
      and groups.user_id = caller_id;

    if group_created_membership then
      delete from public.cast_members cm
      where cm.id = group_membership_id
        and cm.production_id = lease_production_id
        and cm.user_id = caller_id;
    end if;

    delete from public.audit_membership_groups groups
    where groups.production_id = lease_production_id
      and groups.user_id = caller_id;
  end if;

  return 'released';
end;
$$;

revoke execute on function public.end_audit_membership(text) from public, anon;
grant execute on function public.end_audit_membership(text) to authenticated;

create or replace function public.renew_audit_membership(lease_id text)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  lease_uuid uuid := lease_id::uuid;
  lease_production_id uuid;
  lease_user_id uuid;
  renewed_expiry timestamptz;
begin
  if caller_id is null then
    raise exception 'Sign in to renew an audit membership';
  end if;

  select leases.production_id, leases.user_id
  into lease_production_id, lease_user_id
  from public.audit_membership_leases leases
  where leases.id = lease_uuid;

  if lease_production_id is null then
    raise exception 'Audit membership lease does not exist';
  end if;
  if lease_user_id <> caller_id then
    raise exception 'Audit membership lease belongs to another account';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    lease_production_id::text || ':' || lease_user_id::text,
    1096107081
  ));

  update public.audit_membership_leases leases
  set expires_at = now() + interval '6 hours'
  where leases.id = lease_uuid
    and leases.user_id = caller_id
    and leases.expires_at > now()
  returning leases.expires_at into renewed_expiry;

  if renewed_expiry is null then
    raise exception 'Audit membership lease has expired';
  end if;

  return renewed_expiry;
end;
$$;

revoke execute on function public.renew_audit_membership(text)
  from public, anon;
grant execute on function public.renew_audit_membership(text)
  to authenticated;

-- Production deletion is a resumable state machine: once begun, recording
-- publication is frozen, storage is cleaned by prefix, and only finalize may
-- remove the relational production graph.
alter table public.productions
  add column if not exists deleting_at timestamptz;
alter table public.productions
  add column if not exists deleting_by uuid references auth.users(id);

create table if not exists public.production_deletion_jobs (
  production_id uuid primary key,
  organizer_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  finalized_at timestamptz
);
alter table public.production_deletion_jobs enable row level security;
revoke all on public.production_deletion_jobs from anon, authenticated;

create or replace function public.enforce_production_deletion_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.deleting_at is not null
     and (
       new.deleting_at is distinct from old.deleting_at
       or new.deleting_by is distinct from old.deleting_by
     ) then
    raise exception 'Production deletion state is immutable';
  end if;

  if old.deleting_at is null and new.deleting_at is not null then
    if new.deleting_by is null or not exists (
      select 1
      from public.production_deletion_jobs jobs
      where jobs.production_id = new.id
        and jobs.organizer_id = new.deleting_by
        and jobs.finalized_at is null
    ) then
      raise exception 'Use begin_production_deletion to delete a production';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_production_deletion_state
  on public.productions;
create trigger enforce_production_deletion_state
  before update of deleting_at, deleting_by on public.productions
  for each row execute function public.enforce_production_deletion_state();

drop policy if exists "RPC-only production deletion" on public.productions;
create policy "RPC-only production deletion"
  on public.productions
  as restrictive
  for delete
  to authenticated
  using (false);

create or replace function public.guard_recording_metadata_during_deletion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  production_ids uuid[];
  guarded_production_id uuid;
begin
  if tg_op = 'UPDATE' then
    production_ids := array[old.production_id, new.production_id];
  else
    production_ids := array[new.production_id];
  end if;

  for guarded_production_id in
    select distinct ids.production_id
    from unnest(production_ids) as ids(production_id)
    where ids.production_id is not null
    order by ids.production_id
  loop
    perform pg_advisory_xact_lock_shared(hashtextextended(
      guarded_production_id::text,
      1346651471
    ));
    if exists (
      select 1
      from public.productions p
      where p.id = guarded_production_id
        and p.deleting_at is not null
    ) then
      raise exception 'Recording publication is closed while production deletion is in progress';
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists guard_recording_metadata_during_deletion
  on public.recordings;
create trigger guard_recording_metadata_during_deletion
  before insert or update on public.recordings
  for each row execute function public.guard_recording_metadata_during_deletion();

create or replace function public.guard_recording_object_during_deletion()
returns trigger
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  production_ids uuid[];
  guarded_production_id uuid;
begin
  if tg_op = 'UPDATE' then
    if old.bucket_id <> 'recordings' and new.bucket_id <> 'recordings' then
      return new;
    end if;
    production_ids := array[
      case when old.bucket_id = 'recordings' then
        public.recording_object_production(old.name)
      else null end,
      case when new.bucket_id = 'recordings' then
        public.recording_object_production(new.name)
      else null end
    ];
  else
    if new.bucket_id <> 'recordings' then
      return new;
    end if;
    production_ids := array[public.recording_object_production(new.name)];
  end if;

  for guarded_production_id in
    select distinct ids.production_id
    from unnest(production_ids) as ids(production_id)
    where ids.production_id is not null
    order by ids.production_id
  loop
    perform pg_advisory_xact_lock_shared(hashtextextended(
      guarded_production_id::text,
      1346651471
    ));
    if exists (
      select 1
      from public.productions p
      where p.id = guarded_production_id
        and p.deleting_at is not null
    ) then
      raise exception 'Recording uploads are closed while production deletion is in progress';
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists guard_recording_object_during_deletion
  on storage.objects;
create trigger guard_recording_object_during_deletion
  before insert or update on storage.objects
  for each row execute function public.guard_recording_object_during_deletion();

create or replace function public.begin_production_deletion(prod_id text)
returns json
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  production_organizer_id uuid;
  existing_deleting_at timestamptz;
  job_organizer_id uuid;
  job_finalized_at timestamptz;
  started_deleting_at timestamptz;
  result_status text;
begin
  if caller_id is null then
    raise exception 'Sign in to delete a production';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    production_uuid::text,
    1346651471
  ));

  select p.organizer_id, p.deleting_at
  into production_organizer_id, existing_deleting_at
  from public.productions p
  where p.id = production_uuid
  for update;

  if production_organizer_id is null then
    select jobs.organizer_id, jobs.finalized_at
    into job_organizer_id, job_finalized_at
    from public.production_deletion_jobs jobs
    where jobs.production_id = production_uuid;

    if job_organizer_id = caller_id and job_finalized_at is not null then
      return json_build_object(
        'status', 'already_finalized',
        'production_id', production_uuid,
        'storage_prefix', production_uuid::text || '/',
        'deleting_at', null
      );
    end if;
    raise exception 'Production is unavailable or caller is not its organizer';
  end if;

  if production_organizer_id <> caller_id then
    raise exception 'Only the production organizer can delete it';
  end if;

  insert into public.production_deletion_jobs (
    production_id,
    organizer_id
  )
  values (production_uuid, caller_id)
  on conflict (production_id) do nothing;

  select jobs.organizer_id, jobs.finalized_at
  into job_organizer_id, job_finalized_at
  from public.production_deletion_jobs jobs
  where jobs.production_id = production_uuid;

  if job_organizer_id <> caller_id then
    raise exception 'Production deletion belongs to another organizer';
  end if;
  if job_finalized_at is not null then
    return json_build_object(
      'status', 'already_finalized',
      'production_id', production_uuid,
      'storage_prefix', production_uuid::text || '/',
      'deleting_at', existing_deleting_at
    );
  end if;

  update public.productions p
  set deleting_at = coalesce(p.deleting_at, now()),
      deleting_by = coalesce(p.deleting_by, caller_id)
  where p.id = production_uuid
  returning p.deleting_at into started_deleting_at;

  result_status :=
    case when existing_deleting_at is null then 'started' else 'resumed' end;
  return json_build_object(
    'status', result_status,
    'production_id', production_uuid,
    'storage_prefix', production_uuid::text || '/',
    'deleting_at', started_deleting_at
  );
end;
$$;

revoke execute on function public.begin_production_deletion(text)
  from public, anon;
grant execute on function public.begin_production_deletion(text)
  to authenticated;

create or replace function public.finalize_production_deletion(prod_id text)
returns json
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  job_organizer_id uuid;
  job_finalized_at timestamptz;
  production_deleting_at timestamptz;
begin
  if caller_id is null then
    raise exception 'Sign in to finalize production deletion';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    production_uuid::text,
    1346651471
  ));

  select jobs.organizer_id, jobs.finalized_at
  into job_organizer_id, job_finalized_at
  from public.production_deletion_jobs jobs
  where jobs.production_id = production_uuid
  for update;

  if job_organizer_id is null or job_organizer_id <> caller_id then
    raise exception 'Begin production deletion before finalizing it';
  end if;
  if job_finalized_at is not null then
    return json_build_object(
      'status', 'already_finalized',
      'production_id', production_uuid
    );
  end if;

  select p.deleting_at into production_deleting_at
  from public.productions p
  where p.id = production_uuid
  for update;
  if production_deleting_at is null then
    raise exception 'Production is not in deleting state';
  end if;

  if exists (
    select 1
    from storage.objects objects
    where objects.bucket_id = 'recordings'
      and left(objects.name, length(production_uuid::text) + 1)
        = production_uuid::text || '/'
  ) then
    return json_build_object(
      'status', 'storage_not_empty',
      'production_id', production_uuid
    );
  end if;

  delete from public.productions p
  where p.id = production_uuid;

  update public.production_deletion_jobs jobs
  set finalized_at = now()
  where jobs.production_id = production_uuid;

  return json_build_object(
    'status', 'finalized',
    'production_id', production_uuid
  );
end;
$$;

revoke execute on function public.finalize_production_deletion(text)
  from public, anon;
grant execute on function public.finalize_production_deletion(text)
  to authenticated;

-- Serialize metadata replacement for one user's line so the caller receives
-- the exact superseded object URL and can delete that storage object safely.
create or replace function public.save_recording_metadata(
  prod_id text,
  line_id text,
  audio_url text,
  duration_ms integer,
  recorded_at timestamptz default now()
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  previous_audio_url text;
  result json;
begin
  if caller_id is null then
    raise exception 'Sign in to save recording metadata';
  end if;
  if not public.is_production_member(production_uuid, caller_id) then
    raise exception 'Join this production before saving recordings';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    production_uuid::text || ':' || save_recording_metadata.line_id
      || ':' || caller_id::text,
    1380273485
  ));

  select recordings.audio_url into previous_audio_url
  from public.recordings recordings
  where recordings.production_id = production_uuid
    and recordings.line_id = save_recording_metadata.line_id
    and recordings.user_id = caller_id
  for update;

  if found then
    update public.recordings recordings
    set audio_url = save_recording_metadata.audio_url,
        duration_ms = save_recording_metadata.duration_ms,
        recorded_at = save_recording_metadata.recorded_at
    where recordings.production_id = production_uuid
      and recordings.line_id = save_recording_metadata.line_id
      and recordings.user_id = caller_id
    returning row_to_json(recordings.*) into result;
  else
    insert into public.recordings (
      production_id,
      line_id,
      user_id,
      audio_url,
      duration_ms,
      recorded_at
    )
    values (
      production_uuid,
      save_recording_metadata.line_id,
      caller_id,
      save_recording_metadata.audio_url,
      save_recording_metadata.duration_ms,
      save_recording_metadata.recorded_at
    )
    returning row_to_json(recordings.*) into result;
  end if;

  return json_build_object(
    'recording', result,
    'previous_audio_url', previous_audio_url
  );
end;
$$;

revoke execute on function public.save_recording_metadata(
  text, text, text, integer, timestamptz
) from public, anon;
grant execute on function public.save_recording_metadata(
  text, text, text, integer, timestamptz
) to authenticated;

-- Delete metadata first and return its object URL for the client's durable,
-- resumable storage cleanup queue.
create or replace function public.delete_recording_metadata(
  prod_id text,
  line_id text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  removed_audio_url text;
begin
  if caller_id is null then
    raise exception 'Sign in to delete recording metadata';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    production_uuid::text || ':' || delete_recording_metadata.line_id
      || ':' || caller_id::text,
    1380273485
  ));

  delete from public.recordings recordings
  where recordings.production_id = production_uuid
    and recordings.line_id = delete_recording_metadata.line_id
    and recordings.user_id = caller_id
  returning recordings.audio_url into removed_audio_url;

  if removed_audio_url is null then
    return json_build_object(
      'status', 'already_absent',
      'audio_url', null
    );
  end if;

  return json_build_object(
    'status', 'deleted',
    'audio_url', removed_audio_url
  );
end;
$$;

revoke execute on function public.delete_recording_metadata(text, text)
  from public, anon;
grant execute on function public.delete_recording_metadata(text, text)
  to authenticated;

-- Claiming updates the joiner's display name in the same transaction and never
-- reports success for a missing, invalid, or already-claimed invitation. A
-- retry by the same account is idempotent and returns its existing row.
drop function if exists public.claim_cast_invitation(text, text);
create function public.claim_cast_invitation(
  member_id text,
  code text,
  new_display_name text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  target_production uuid;
  result json;
begin
  if caller_id is null then
    raise exception 'Sign in to claim a cast invitation';
  end if;

  select cm.production_id into target_production
  from public.cast_members cm
  where cm.id = member_id::uuid;

  if target_production is null then
    perform public.check_join_rate_limit();
    raise exception 'Unable to claim this cast invitation';
  end if;

  if not public.verify_join_code(target_production, code) then
    raise exception 'Unable to claim this cast invitation';
  end if;

  update public.cast_members cm
  set user_id = caller_id,
      display_name = coalesce(new_display_name, cm.display_name),
      joined_at = now()
  where cm.id = member_id::uuid
    and cm.user_id is null
  returning row_to_json(cm.*) into result;

  if result is null then
    select row_to_json(cm.*) into result
    from public.cast_members cm
    where cm.id = member_id::uuid
      and cm.user_id = caller_id;
  end if;

  if result is null then
    raise exception 'Unable to claim this cast invitation';
  end if;

  return result;
end;
$$;

revoke execute on function public.claim_cast_invitation(text, text, text) from public, anon;
grant execute on function public.claim_cast_invitation(text, text, text) to authenticated;

-- Joining and invitation claiming are RPC-only. Organizers retain their
-- separate policy for deliberate cast management.
drop policy if exists "Users can self-join" on public.cast_members;
drop policy if exists "Users insert own membership" on public.cast_members;
drop policy if exists "Users can claim invitation" on public.cast_members;
drop policy if exists "Users can claim their invitation" on public.cast_members;
drop policy if exists "Authenticated users can join productions" on public.cast_members;
drop policy if exists "auth_insert_cast" on public.cast_members;
drop policy if exists "auth_update_cast" on public.cast_members;

-- Organizer deletion needs to distinguish a harmless retry from an RLS or
-- authorization failure. Supplying the production id lets the function
-- authorize even after the member row has already disappeared.
create or replace function public.remove_cast_member(
  member_id text,
  prod_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
  production_uuid uuid := prod_id::uuid;
  removed_id uuid;
begin
  if caller_id is null
     or not public.is_production_organizer(production_uuid, caller_id) then
    raise exception 'Only the production organizer can remove a cast member';
  end if;

  delete from public.cast_members cm
  where cm.id = member_id::uuid
    and cm.production_id = production_uuid
  returning cm.id into removed_id;

  if removed_id is not null then
    return 'removed';
  end if;

  -- A real row in a different production is not an idempotent absence.
  if exists (
    select 1 from public.cast_members cm
    where cm.id = member_id::uuid
  ) then
    raise exception 'Cast member does not belong to this production';
  end if;

  return 'already_absent';
end;
$$;

revoke execute on function public.remove_cast_member(text, text) from public, anon;
grant execute on function public.remove_cast_member(text, text) to authenticated;

-- Members may replace only objects they uploaded. Object deletion is available
-- to the uploader and to the production organizer so metadata/blob deletion can
-- be completed together by the application.
drop policy if exists "Members update recording objects" on storage.objects;
drop policy if exists "Owners update recording objects" on storage.objects;
create policy "Owners update recording objects"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'recordings'
    and owner_id = auth.uid()::text
  )
  with check (
    bucket_id = 'recordings'
    and owner_id = auth.uid()::text
    and public.is_production_member(
      public.recording_object_production(name), auth.uid())
  );

drop policy if exists "Owners delete recording objects" on storage.objects;
create policy "Owners delete recording objects"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'recordings'
    and owner_id = auth.uid()::text
  );

drop policy if exists "Organizers delete recording objects" on storage.objects;
create policy "Organizers delete recording objects"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'recordings'
    and public.is_production_organizer(
      public.recording_object_production(name), auth.uid())
  );

-- RLS expressions require authenticated callers to execute these helpers, but
-- anonymous callers have no legitimate direct use and must not get an oracle.
revoke execute on function public.is_production_member(uuid, uuid) from public, anon;
revoke execute on function public.is_production_organizer(uuid, uuid) from public, anon;
grant execute on function public.is_production_member(uuid, uuid) to authenticated;
grant execute on function public.is_production_organizer(uuid, uuid) to authenticated;

-- New codes and the repaired legacy population must use at least one character
-- outside the old hexadecimal alphabet.
create or replace function public.generate_join_code()
returns text
language plpgsql
set search_path = public
as $$
declare
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text;
begin
  loop
    result := '';
    for i in 1..6 loop
      result := result || substr(
        chars, floor(random() * length(chars) + 1)::integer, 1);
    end loop;
    exit when result !~ '^[0-9A-F]{6}$';
  end loop;
  return result;
end;
$$;

do $$
declare
  production_row record;
  attempts integer;
begin
  for production_row in
    select id
    from public.productions
    where join_code ~ '^[0-9A-F]{6}$'
  loop
    attempts := 0;
    loop
      attempts := attempts + 1;
      begin
        update public.productions
        set join_code = public.generate_join_code()
        where id = production_row.id;
        exit;
      exception when unique_violation then
        if attempts >= 100 then
          raise exception 'Could not generate a unique join code for production %',
            production_row.id;
        end if;
      end;
    end loop;
  end loop;
end;
$$;

-- UNIQUE (production_id, sort_order) already owns an equivalent index.
drop index if exists public.idx_script_scenes_production;

reset lock_timeout;
