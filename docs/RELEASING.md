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
./scripts/play-changelog.sh "What changed"   # release notes for THIS versionCode
./scripts/generate-play-screenshots.sh       # phone screenshots (device must be attached)
./scripts/play-preflight.sh                  # gate: everything checkable locally
./scripts/ship-play.sh                       # preflight + signed AAB + upload to internal
./scripts/ship-play.sh --closed              # → CLOSED testing (alpha) as a DRAFT release
./scripts/ship-play.sh --closed --validate   # dry run: Google validates it, nothing ships
./scripts/ship-play.sh --closed --live       # → closed testing, rolled out to testers now
./scripts/ship-play.sh --build               # build the signed AAB only, no upload
cd fastlane && fastlane android metadata     # push listing text + graphics + screenshots
cd fastlane && fastlane android promote      # internal → production
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
cd fastlane && fastlane android beta         # build AAB + upload to internal track
cd fastlane && fastlane android closed_beta  # → closed testing (alpha), draft release
cd fastlane && fastlane android promote      # internal → production
```

**Track names.** Play's UI names and the API's names differ, which makes the
lanes look mismatched:

| Play Console | API / fastlane `track:` | Lane |
|---|---|---|
| Internal testing | `internal` | `beta` |
| **Closed testing** | `alpha` | **`closed_beta`** |
| Open testing | `beta` | — |
| Production | `production` | `promote` |

`closed_beta` defaults to `release_status: draft`: the build and listing are
staged in Play Console and the roll-out button stays yours. Pass
`status:completed` (or `ship-play.sh --closed --live`) to push it to testers
in the same step, and `validate:true` to have Google validate the whole
upload and then discard the edit. Unlike the internal lane it also uploads
the store listing and graphics, since closed testers see the listing page.
Needs the Play service-account JSON at `~/.google-play/play-store-key.json`
(set up 2026-07-30, copied from the open-testimony project — same Play
developer account).

Fastfile path gotchas (fixed 2026-07-30 — this repo keeps `fastlane/` at the
repo ROOT, unlike where the file was copied from): `sh()` commands run inside
`fastlane/` (so the build step is `cd ..`), while fastlane *actions* resolve
relative paths from the repo root (so the `aab:` path has no `../` prefix).

### Play Console checklist (the parts no script can do)

Run `./scripts/play-preflight.sh` first — it verifies everything checkable
from this machine (signing, credentials, metadata limits, release notes for
THIS versionCode, store graphics, screenshot aspect ratios, the AAB). It
exits non-zero and names what to fix; `ship-play.sh` refuses to upload
until it passes.

What preflight CANNOT check, because it only exists in Play Console:

| Step | Where | Notes |
|---|---|---|
| ~~Create the app~~ **DONE 2026-08-14** | Console → All apps → Create app | |
| Opt into Play App Signing + grab its SHA-1 | Test and release → Setup → App integrity | Google re-signs the AAB, so Play-delivered builds present *that* cert. The SHA-1 is what's still missing to restrict the Android API key (see `docs/OPEN_DECISIONS.md` §3) |
| ~~First upload must be through the Console~~ | — | **Not true here.** Long-standing guidance says the API can't upload a new app's first bundle; build 150 went up via `ship-play.sh --closed` as the first bundle on 2026-08-14, validated first with `--validate`. Only *creating* the app needs the Console. |
| **Data safety** form | Policy → App content | Declare: audio recordings + email, stored on Supabase, not shared/sold. Rehearsal audio never leaves the device unless the user shares with their cast. |
| **Content rating** questionnaire | Policy → App content | Utility/productivity; no ads, no UGC feed |
| Target audience + ads declaration | Policy → App content | No ads |
| Privacy policy URL | Store presence → Main store listing | Same URL as the App Store listing |
| Countries / pricing (free) | Release → Production | |
| App access (test credentials) | Policy → App content | Reviewers need a login OR the "Continue without account" path documented — the app works fully offline without one |

### Closed beta (closed testing) — what still needs a human

`./scripts/ship-play.sh --closed` stages the build, the listing text, the
graphics and the screenshots. What it *cannot* do, because it lives behind
Console forms:

1. **Create the tester list.** Test and release → Testing → Closed testing →
   Testers. Either an email list (paste addresses) or a Google Group. A build
   in the track is invisible until someone is on that list.
2. **Complete App content** (see the table above). A closed-testing release
   can be *uploaded* without these, but the roll-out is blocked until data
   safety, content rating, target audience, privacy policy, and app access
   are signed off.
3. **Countries/regions** for the closed track.
4. **Send the opt-in link.** Console gives a `play.google.com/apps/testing/…`
   URL; testers must accept it before Play will show them the app.

If this is a **personal** (individual) developer account created after Nov
2023, Google additionally requires ≥12 testers opted in and the closed test
running ≥14 continuous days before production access unlocks — worth knowing
before planning the public launch date, since the clock starts at roll-out,
not at upload.

### Assets and how they're produced

| Asset | Path | Made by |
|---|---|---|
| Icon 512×512 (no alpha) | `fastlane/metadata/android/en-US/images/icon.png` | `python3 scripts/generate-icons.py` |
| Feature graphic 1024×500 | `.../images/featureGraphic.png` | `python3 scripts/generate-icons.py` (icon + wordmark on a gradient sampled from the artwork) |
| Phone screenshots (≥2) | `.../images/phoneScreenshots/` | `./scripts/generate-play-screenshots.sh` — drives a CONNECTED device, then letterboxes each frame onto 1080×2160 |
| Release notes | `.../changelogs/<versionCode>.txt` | `./scripts/play-changelog.sh "…"` (or from a matching CHANGELOG.md section) |

**Why screenshots are regenerated rather than reused from iOS:** Play rejects
anything more extreme than a 2:1 aspect ratio. iPhone 6.9" shots are 1:2.17
and a raw Galaxy capture is 1:2.17 — both too tall. The script letterboxes
onto an exact 1:2 canvas in the app's surface colour instead of cropping
(cropping cut off the app bar).

### Download size (measured 2026-08-14, build 148)

The 231 MB figure from `flutter build apk` is the **universal** APK — every
ABI and density in one file. What Play actually delivers, measured with
bundletool on the real AAB:

| ABI | Download |
|---|---|
| arm64-v8a | ~60 MB |
| armeabi-v7a | ~58 MB |
| x86_64 | ~62 MB |

Comfortably under Play's 200 MB limit, so no asset packs / Play Asset
Delivery are needed. (Re-measure if the bundled models grow: the PaddleOCR
assets alone are 30 MB.)

```bash
# how that was measured
java -jar bundletool.jar build-apks --bundle=build/app/outputs/bundle/release/app-release.aab \
  --output=/tmp/app.apks --mode=default
java -jar bundletool.jar get-size total --apks=/tmp/app.apks --dimensions=SDK,ABI
```

---

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
