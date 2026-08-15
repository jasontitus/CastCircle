# Getting the cast in

A plan for the invite flow: how an organizer is led into inviting, how the
invite reaches and converts a castmate, and how the loop closes so the
organizer knows it worked.

Grounded in the code as it stands on build 155. File references are where the
behaviour lives today.

---

## Where it breaks today

Eight findings, in the order a real invite hits them.

| # | What happens now | Where | Cost |
|---|---|---|---|
| 1 | Nothing prompts an organizer to invite anyone. The only mention is one page of the first-run walkthrough. | `welcome_screen.dart` | Most productions never send a single invite |
| 2 | Inviting is four taps deep: Cast & Roles → tap a character → Invite. | `cast_manager_screen.dart` `_inviteActor` | Found by people already looking for it |
| 3 | The invite link is `castcircle://join?code=…` — a **custom scheme**. | `deep_link_service.dart` `buildUri`, `AndroidManifest.xml` intent-filter | **Tapping it does nothing at all unless the app is already installed.** This is the biggest leak: the recipient's first and most likely action silently fails |
| 4 | The share text tells an app-less recipient to "Download the app to get started" — with no store link and no code they can act on later. | `cast_manager_screen.dart` `_inviteActor` | Dead end |
| 5 | Joining requires an account, and the sign-in wall appears **before** the recipient sees what they're joining. | `join_production_screen.dart` | Asked to sign up for something unexplained |
| 6 | The organizer is never told when someone joins. | — | The loop never closes |
| 7 | Cast progress exists as one dense line: "N of M actors joined · X/Y lines recorded (Z%)". | `cast_manager_screen.dart` | Real information, invisible placement |
| 8 | No analytics on any of it. | — | We cannot tell which step leaks |

Two things are already in place and worth building on:

- **`joined_at` is written when someone joins** (`supabase_service.dart`), so
  the data the feedback loop needs already exists.
- **Realtime is proven** on `recordings:$productionId`
  (`supabase_service.dart`) — the same pattern extends to `cast_members`
  without new infrastructure.

And one constraint: **there is no push notification stack** — no
`firebase_messaging`, no local notifications. Every "they joined!" signal has
to be in-app until that changes (see M4).

---

## Principles

1. **One link for the whole cast beats N individual invites.** Casts have a
   group chat. The highest-value action is a single link anyone can use to
   claim their own part — the production join code already works this way;
   it just isn't presented as the main path.
2. **Explain before authenticating.** A recipient should see the production,
   the part, and what they get before being asked for an account.
3. **Never fabricate activity.** Any "your cast is busy" signal must come
   from real events. If there is no activity, show nothing. No simulated
   counts, no implied presence, no "12 people rehearsing now."
4. **Nudge on a budget.** Reminders are capped and stoppable, and never a
   modal.

---

## Act I — the organizer

**The moment.** Right after a script is imported, the app knows the character
list and that no one is cast. That is when inviting makes sense — not buried
in a screen they have no reason to open.

**The card** (production hub, dismissible, returns while roles are uncast):

> **Who's playing these parts?**
> 12 speaking roles, none cast yet.
> [Share one link with the cast] [Invite someone for a part]

- **Share one link** → the production join code + link, straight to the
  system share sheet. The recipient picks their own part.
- **Invite someone for a part** → today's per-character flow, which is right
  when the organizer knows who plays what.

**Copy carries the value**, not the mechanism: "They get the script, their
part, and can record their lines for you."

**Roles matter.** Only organizers see invite prompts. An actor who joined
someone else's production is not nagged to recruit.

---

## Act II — the recipient

This act is where the leak is, and M1 exists to fix it.

**The link becomes an https link** — `https://<domain>/j/ABC123` — backed by
Universal Links (`apple-app-site-association`) and Android App Links
(`assetlinks.json`, `autoVerify="true"`). Keep the `castcircle://` scheme
working for old links.

**The landing page does real work** when the app isn't installed:

- The production title and who invited them ("Jason invited you to play
  OPHELIA in *Hamlet*").
- Store buttons for iOS and Android.
- **The six-character code in large type**, with "open CastCircle and enter
  this code" — a plain instruction that survives the store round trip.

Deliberately *not* doing fingerprint-based deferred deep linking: it is
privacy-hostile and brittle. A code the reader can see and retype is
honest and works.

**In-app, the join is one tap.** The link carries `code` and `char`, so the
join sheet opens already knowing both: "Join *Hamlet* as OPHELIA — 381
lines." Sign-in comes after that, framed as what it buys ("so your recordings
reach the rest of the cast"), not as a gate before the explanation.

---

## Act III — the loop closes

**The organizer finds out.** Two paths, both needed:

- **Live** — a realtime subscription on `cast_members` for productions where
  I'm the organizer, mirroring the existing `recordings:` channel. In-app:
  "MARIA joined as OPHELIA."
- **Cold** — on app open, diff `joined_at` against a per-production
  last-seen timestamp and summarise: "2 castmates joined since you were last
  here." This is the one that matters, because the organizer is usually not
  in the app when someone joins.

**Cast progress view.** Promote what already exists into something legible at
a glance, on the production card and at the top of the hub:

- A ring or bar plus plain words: **"7 of 12 parts cast."**
- Percentage framing only where it reads naturally ("58% of your cast is
  here") — count roles with a joined actor over total speaking roles.
- Three states: **nobody yet** (invite CTA), **partial** (progress + invite
  the rest), **complete** (say so once, then stop showing it).

**Reminders, with rules:**

| Rule | Value |
|---|---|
| Trigger | Production has uncast roles, and no invite shared for it in 7 days |
| Placement | Dismissible strip in the hub — never a modal, never a push |
| Frequency | At most one per production per week; at most one per session |
| Give up | After two dismissals, stop for that production |
| Off switch | "Don't remind me about this production" in the strip |

---

## Activity signals — real or absent

The ask is a sense that things are alive without leaderboards or invented
numbers. Everything below is derived from events already in the data
(`recordings.created_at`, `cast_members.joined_at`):

- "Someone recorded lines for MARCELLUS."
- "Your cast has been rehearsing this week."
- A quiet dot on a castmate's row who has recorded recently.

Rules that keep it honest:

- **Real events only.** No fabrication, no estimates dressed as facts.
- **Silence when quiet.** No activity → the strip is absent, not filled with
  something vague.
- **Coarse time.** "This week", not timestamps — nobody needs to know a
  castmate rehearsed at 1am.
- **Production-scoped.** Never cross-production or global "other users are
  active" claims. If a global signal is ever wanted, it has to be a real
  aggregate, and it isn't worth showing until the numbers are real.
- **Opt-out** in settings, for people who don't want their rehearsing
  broadcast to their cast.

---

## Build order

| | Milestone | Contents | Why here |
|---|---|---|---|
| M1 | **Links that work** | Domain + landing page, AASA + assetlinks, https links in share text, App Link intent filter, invite analytics | Everything else is worth less while the link is dead. Needs a domain — the only external dependency in this plan |
| M2 | **Getting asked, and seeing progress** | Post-import invite card, share-one-link path, cast progress view | Turns a hidden feature into a step in the flow |
| M3 | **Closing the loop** | Realtime + on-open join diff, reminder strip with the rules above | Meaningful once invites are actually going out |
| M4 | **Ambient + push** | Activity signals; optionally push notifications (FCM + APNs + a server function) | Push is its own project — scope it separately, and only if the in-app loop proves insufficient |

## Instrumentation

Without this the funnel is guesswork. Six events, in order:

1. `invite_shared` — with `{scope: link|character}`
2. `invite_link_opened` — on the landing page
3. `app_opened_with_code` — deep link or manual entry
4. `join_started`
5. `join_completed`
6. `invitee_first_recording`

The interesting number is the drop between 2 and 3 (the store round trip),
which is exactly what finding 3 predicts is near-total today.

---

## Decisions needed from Jason

1. **Domain** for invite links (`castcircle.app`? something already owned?).
   M1 can't start without it. Hosting is free — the page is static.
2. **Can someone join without an account?** Today's answer is no. Letting a
   recipient in far enough to see the script, with sign-in required only to
   record or sync, would cut the biggest remaining friction — but it means a
   local-only cast member the cloud doesn't know about.
3. **Push notifications: worth it?** They are the honest answer to "tell me
   when someone joins" and they are a real project (FCM + APNs, server
   function, permission prompt, a new privacy surface).
4. **How much celebration?** A cast reaching full strength is a genuine
   milestone. One quiet moment, or nothing at all?
