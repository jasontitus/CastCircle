# Releasing CastCircle

Canonical build + upload recipe for every platform. **Read this before shipping** — don't improvise.

App identity: bundle/package `com.tiltastech.castcircle` · Apple team `A6G8H8NGAM` · Firebase project `castcircle-app`.

---

## iOS → TestFlight

**One command — do NOT hand-run xcodebuild and do NOT use fastlane for iOS:**

```bash
./scripts/ship-testflight.sh            # bumps build number, builds, exports IPA, uploads
./scripts/ship-testflight.sh --no-bump  # reuse current build number (rare)
```

Prereqs (already on the build Mac):
- ASC API key **7C7256MDM6**, issuer **69a6de81-894e-47e3-e053-5b8c7c11a4d1**, key at `~/.appstoreconnect/private_keys/AuthKey_7C7256MDM6.p8`.
- Signing is provisioned on the fly via `-allowProvisioningUpdates` + the API key. The local keychain has **no** "iOS Distribution" cert and never needs one. `security find-identity` showing only "Apple Development" is normal.

Expected (not an error): `flutter build ipa` always "fails" at its own export sub-step (`exportArchive Copy failed`) — the `.xcarchive` is still produced and the script exports the IPA manually. Success line: `✓ build NN shipped to TestFlight`.

---

## macOS → notarized DMG (sideload / direct distribution)

macOS has no App Store build here; it's a notarized Developer ID app shipped as a DMG. Kokoro is NOT on macOS (system TTS).

```bash
flutter build macos --release
# deep-sign inside-out (nested dylibs, then frameworks, then the app last) with:
#   codesign --force --options runtime --timestamp \
#     --entitlements macos/Runner/Release.entitlements \
#     --sign "Developer ID Application: Jason Titus (A6G8H8NGAM)"  <app>
# then:
xcrun notarytool submit <app>.zip --key ~/.appstoreconnect/private_keys/AuthKey_7C7256MDM6.p8 \
  --key-id 7C7256MDM6 --issuer 69a6de81-894e-47e3-e053-5b8c7c11a4d1 --wait
xcrun stapler staple <app>
# package: hdiutil create -volname CastCircle -srcfolder <stage> -format UDZO Out.dmg
# notarize + staple the DMG too, then verify: spctl -a -vvv -t exec <app>  → "Notarized Developer ID"
```

Notes: hardened runtime (`--options runtime`) + secure timestamp are required. `codesign` is set to "Always Allow" for the Developer ID key, so signing runs unattended. The signing identity is `9BD82FF2CFBF77A58566C98CBA6B8116DDB9FECB`.

---

## Android → Google Play

**One command:**

```bash
./scripts/ship-play.sh          # builds signed AAB + uploads to Play internal track (fastlane)
./scripts/ship-play.sh --build  # build the signed AAB only, no upload
```

### Signing (set up once — DONE 2026-06-22)
- Upload keystore: `android/app/castcircle-upload.jks` (alias `upload`), password in `android/key.properties`. **Both git-ignored.** The password is the only copy — losing it means resetting the upload key in Play (fine for Play App Signing; fatal for sideloaded/Amazon builds).
- `android/app/build.gradle.kts` wires `key.properties` → `signingConfigs.release` → `buildTypes.release`. Since 2026-07-30 a release build **fails loudly** when `key.properties` is missing (it used to fall back silently to debug signing). Use a debug build for local work.
- `storeFile` is relative to `android/app/`, not `android/`.
- Upload key fingerprints (register with Play App Signing / Firebase if needed):
  - SHA-1 `22:F4:9D:A5:55:E5:BF:AB:44:A7:35:96:18:A4:F6:DE:0B:69:93:E9`
  - SHA-256 `DF:88:96:A3:A7:86:7B:37:7B:51:63:21:2A:92:6B:89:05:ED:FF:62:76:6D:61:D9:70:64:99:87:38:02:8D:64`

### Build
```bash
flutter build appbundle --release   # → build/app/outputs/bundle/release/app-release.aab (signed)
flutter build apk --release          # sideload/Amazon APK instead
```

### Upload
Fastlane lane (in `fastlane/Fastfile`, platform `:android`):
```bash
cd fastlane && fastlane android beta      # build AAB + upload to internal track
cd fastlane && fastlane android promote   # internal → production
```
Needs the Play service-account JSON at `~/.google-play/play-store-key.json`
(set up 2026-07-30, copied from the open-testimony project — same Play
developer account).

Fastfile path gotchas (fixed 2026-07-30 — this repo keeps `fastlane/` at the
repo ROOT, unlike where the file was copied from): `sh()` commands run inside
`fastlane/` (so the build step is `cd ..`), while fastlane *actions* resolve
relative paths from the repo root (so the `aab:` path has no `../` prefix).

**First upload is manual — STILL PENDING as of 2026-07-30** (the Play API can
only upload to an app that already exists; automated upload ends at
`Package not found: com.tiltastech.castcircle`): in Play Console create the
app `com.tiltastech.castcircle`, opt into **Play App Signing**, and upload the
AAB to the **Internal testing** track once. After that, `ship-play.sh` /
`fastlane android beta` automate every subsequent upload — the whole chain
below that step (auth, signing, paths) is verified working.

---

## Version numbers
`pubspec.yaml` `version: 0.1.1+NN` drives both iOS `CFBundleVersion` and Android `versionCode`. `ship-testflight.sh` auto-bumps `NN`. Keep Android's `versionCode` ahead of whatever Play has already seen.

---

## Supabase auth email (Resend SMTP)

Email confirmation is **required** for signup, and mail goes out through
Resend on the shared `tiltastech.com` sending domain (same Resend account
as `whats-goin-on`, which already verified the domain).

**Before ANY `supabase config push`, export the key:**

```bash
export RESEND_API_KEY=re_...          # from the Resend dashboard
supabase config push --yes
```

`supabase/config.toml` stores `pass = "env(RESEND_API_KEY)"`, so the secret
is never committed — but that also means **a push without the variable set
sends an empty password and silently breaks every auth email** (signup
confirmations, password resets). If confirmation emails stop arriving, that
is the first thing to check.

Verify a change end to end:
1. `POST /auth/v1/signup` with an address on a verified domain → expect
   HTTP 200 with `confirmation_sent_at` set and **no** `access_token`
   (a broken SMTP config returns HTTP 500 instead).
2. `GET https://api.resend.com/emails?limit=3` with the key → the
   "Confirm Your Signup" message should be listed as `delivered`
   (a nonexistent test mailbox will show `bounced`, which still proves
   the pipeline works — avoid repeating it, bounces cost reputation).
