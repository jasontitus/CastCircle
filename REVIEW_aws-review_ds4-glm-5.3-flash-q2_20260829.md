# Pi sweep review — CastCircle

Exhaustive per-file pass: 1 code files across 1 batches — model ds4/GLM-5.3-Flash-Q2:off — 2026-08-29.

## Findings

- [info] supabase/config.toml:225-238 — SMTP credentials are referenced via `env(RESEND_API_KEY)` substitution rather than a literal, but the file is a committed config that documents a shared production Resend account and verified sending domain; verify it is not committed with a real key substituted — consequence: if a literal key were ever substituted locally and committed, the shared mailer account could be abused for spam/phishing from tiltastech.com — smallest safe fix: keep the `env(...)` placeholder and confirm no substituted value exists in git history.
- [medium] supabase/config.toml:154-156 — `additional_redirect_urls` includes the custom scheme `castcircle://auth-callback` alongside the production site URL; in local dev this config is also used for hosted auth flows, and an exact-URL allow-list containing a non-HTTPS custom scheme widens the redirect surface if any wildcard-ish provider ever echoes the URL — consequence: a crafted auth callback could land users on a non-web scheme handler instead of the app, enabling limited token/consent confusion on mobile — smallest safe fix: keep the custom scheme only in the app build config and restrict this list to HTTPS origins.
- [low] supabase/config.toml:164-167 — `refresh_token_reuse_interval = 10` permits a stolen refresh token to be replayed for up to 10 seconds after expiry while rotation is enabled; this is a deliberate reuse-window tradeoff, but it weakens the rotation guarantee the surrounding comments describe — consequence: a token captured in that window can mint a session despite rotation detection — smallest safe fix: set the reuse interval to 0 (reject reuse immediately) unless a client needs the grace window.
- [low] supabase/config.toml:174-178 — `minimum_password_length = 6` with empty `password_requirements` is the weakest accepted password policy; combined with `enable_signup = true` (169) and email confirmations, accounts can be created with trivially guessable passwords — consequence: credential-stuffing against 6-char passwords can compromise user accounts even though confirmation gates mass account minting — smallest safe fix: raise minimum to 8 and set `password_requirements = "letters_digits"`.

## Coverage
supabase/config.toml — findings: 4

## Run stats

input 7261 tok (+1089 cached), output 478 tok — sync requests, discounted — 1 files in 0m (3600.0 files/h, 0.0 min/batch)
