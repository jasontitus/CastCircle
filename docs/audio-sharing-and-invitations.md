# Cast invitations & audio sharing — how it works, how to debug it

How a cast joins a production and how recordings are shared between members,
plus the tooling for diagnosing and reproducing multi-device issues.

## Flows

**Joining a production**
1. Director creates a production → it gets a 6-char `join_code` and the director
   is added as a `cast_members` row (role `organizer`).
2. Director assigns/invites a character → a `cast_members` row with
   `character_name` set and `user_id` null (an *unclaimed invitation*), shared
   via a `castcircle://join?code=…&char=…` deep link or the bare code.
3. Actor enters the code → `lookup_production_by_join_code` RPC → picks their
   character → **claims** the invitation (`claim_cast_invitation` RPC, with a
   direct-update fallback) or **self-joins** (new row). The production + the
   actor's membership are saved locally and the cloud script is pulled.

**Sharing recordings**
- Recorded locally first (AAC-LC `.m4a`, 128 kbps mono, ~15–50 KB/line), then
  uploaded to Supabase Storage (`recordings` bucket) with a row in the
  `recordings` table (`production_id, line_id, user_id, audio_url, …`,
  unique on `production_id+line_id+user_id`).
- Other members **download** castmates' takes into a local cache and play them
  in rehearsal (the "understudy" path, on by default). A **realtime**
  subscription streams new/updated recordings as they arrive.
- Sync is started by an app-root listener on `currentProductionProvider`, so it
  runs whether you **open** a production from home or **join** one (the join
  screen would otherwise navigate away before its sync could run).

## Storage key layout

Each take is uploaded to a **unique** key:

```
recordings/{productionId}/{character}/{lineId}/{timestamp+rand}.m4a
```

Unique-per-take because the bucket has only an INSERT policy — overwriting a key
is RLS-blocked, so a fixed key would make re-records silently fail. Downloads
resolve the **exact object from the stored `audio_url`** (not by rebuilding the
path), so old fixed keys and awkward character names both work. Superseded
objects orphan harmlessly; the `recordings` row always holds the latest URL.

## Debugging from the in-app log

Everything in the upload/download/sync/join paths logs under the **NET**
category (visible in the in-app Debug Log screen). To trace an issue, filter to
NET and look for:

- **Upload:** `SyncQueue: queued upload …` → `uploading …` → `uploaded … → <url>`;
  retries as `… (attempt n/5, will retry)`; a permanent failure as
  `SyncQueue: GAVE UP on line=…` (the take never reached the cloud).
- **Storage:** `Storage upload → recordings/<key>` / `Storage download ← …`;
  failures name the key. `Recording metadata save FAILED …` points at RLS.
- **Realtime:** `Realtime channel status … → subscribed` is the "is live sharing
  even connected?" signal; `Realtime INSERT/UPDATE: line=…` for each event.
- **Join:** `Join: joining production …` → claim (RPC/fallback) → script pull →
  `Join: success` / `Join FAILED …`.

## Reproducing multi-phone issues on one machine

`tool/sim_multi_user.dart` drives **two real Supabase sessions** through the
whole join + sharing flow and prints a ✓/✗ checklist — RLS cross-user read,
storage round-trip, join/claim, and re-record propagation — creating and
cleaning up a throwaway production.

```
dart run tool/sim_multi_user.dart <emailA> <passA> <emailB> <passB>
```

It creates the accounts on first use (signups on, email confirmation off).
Realtime *live delivery* can't be tested from the standalone Dart client (its
WebSocket URL is malformed) — verify that on two real devices (the macOS app +
a phone, signed into different accounts on the same production).

## Known backend item

`claim_cast_invitation` RPC fails with `column "user_id" is of type uuid but
expression is of type text`. The app still joins via its direct-update fallback,
so impact is just a wasted round-trip + a logged error per invited-actor join.
Fix (Supabase SQL editor):

```sql
create or replace function public.claim_cast_invitation(member_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.cast_members set user_id = auth.uid(), joined_at = now()
  where id = member_id and user_id is null;
$$;
```

(An alternative to the unique-key storage workaround above is to add an UPDATE
policy to the `recordings` bucket; the client fix means it's not required.)
