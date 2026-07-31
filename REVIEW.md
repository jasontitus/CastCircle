# Security Review: lib/main.dart and lib/data/services/supabase_service.dart

- [high] lib/data/services/supabase_service.dart:544 — `getPublicUrl()` returns publicly accessible recording URLs — anyone with the URL (stored in DB, logged, or intercepted) can download voice recordings without authentication, bypassing RLS entirely — use `createSignedUrl()` for time-limited authenticated access, or store object paths and download via authenticated `download()`

- [high] lib/data/services/supabase_service.dart:564 — Same issue in `uploadRecordingBytes()` — `return _client.storage.from('recordings').getPublicUrl(path);` exposes recordings as publicly accessible URLs — use `createSignedUrl()` instead

- [medium] lib/data/services/supabase_service.dart:443 — Join code logged in plaintext — `dlog.log(LogCategory.network, 'Join lookup: code=$code, initialized=$_initialized, signedIn=$isSignedIn');` — if debug logs are accessible via crash reports, log aggregation, or shared devices, join codes are exposed, allowing unauthorized production access — log a redacted hash or omit the code value entirely

- [medium] lib/data/services/supabase_service.dart:452 — Full RPC result logged — `dlog.log(LogCategory.network, 'RPC result: type=${rpcResult.runtimeType}, isMap=${rpcResult is Map}, value=$rpcResult');` — debug logs may contain production titles, IDs, and metadata — log only success/failure status, not full result values

- [medium] lib/data/services/supabase_service.dart:455 — Production title logged — `dlog.log(LogCategory.network, 'RPC success: ${rpcResult['title']}');` — production titles exposed in debug logs — log only success/failure, not titles or other production data

- [medium] lib/data/services/supabase_service.dart:474 — Join code logged again in fallback path — `dlog.log(LogCategory.network, 'Trying direct query for join_code=$code');` — same exposure as line 443 — redact or hash the code

- [low] lib/main.dart:96 — Supabase anon key hardcoded as default — `defaultValue: 'sb_publicable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI'` — while Supabase publishable keys are designed to be public, a committed default fallback reduces key rotation flexibility, exposes the project endpoint to anyone with source access, and silently connects to a fixed project if the env var is unset — remove the default or require the key at build time via `--dart-define`
