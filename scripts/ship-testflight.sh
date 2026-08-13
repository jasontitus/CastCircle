#!/usr/bin/env bash
#
# Ship CastCircle to TestFlight. This encodes the EXACT working recipe — every
# step is load-bearing. Run this; do NOT hand-run the steps or route it through
# fastlane.
#
#   ./scripts/ship-testflight.sh            # bump build number, build, export, upload
#   ./scripts/ship-testflight.sh --no-bump  # reuse the current build number (rare)
#
# Traps that cost real time, settled here once (2026-06-13):
#   - API key is 7C7256MDM6 (NOT 9FY5W363V5). Same issuer for both. The team is
#     A6G8H8NGAM, shared with the open-testimony app — its scripts/ship-testflight.sh
#     is the sibling reference if this ever drifts.
#   - The local keychain has NO "iOS Distribution" cert and never has;
#     `-allowProvisioningUpdates` + the API key provisions signing on the fly.
#     Do NOT hunt for certs or sign in to Xcode → Accounts. `security
#     find-identity` showing only "Apple Development" is normal and fine.
#   - `flutter build ipa` ALWAYS "fails" at its own export sub-step ("No signing
#     certificate" / "Copy failed"). That is EXPECTED — the .xcarchive is still
#     produced. We export the IPA manually in step 5 with the API key.
#   - The manual export needs PATH=/usr/bin:$PATH so xcodebuild uses the SYSTEM
#     rsync; Homebrew's rsync drops --extended-attributes and aborts ("Copy
#     failed").
#   - Do NOT use `fastlane ios beta`: fastlane forces Homebrew Ruby, which breaks
#     the `pod install` that `flutter build` runs ("CocoaPods is installed but
#     broken"); and its `increment_build_number` runs agvtool, which overwrites
#     Flutter's $(FLUTTER_BUILD_NUMBER) in Info.plist + pbxproj with a literal
#     "1" (shipping build 1). The pure-shell path below sidesteps both.
#   - VERIFY the archive's CFBundleVersion == the number we just bumped BEFORE
#     exporting (step 4 gate), or a silently-stale archive ships the prior build.
#
set -euo pipefail

cd "$(dirname "$0")/.."                  # -> repo root

# ASC key/issuer ids come from the environment or ~/.appstoreconnect/ids.env
# (git-ignored) — credential identifiers don't belong in committed code,
# even though the actual secret (the .p8) already lives outside the repo.
if [[ -f "$HOME/.appstoreconnect/ids.env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.appstoreconnect/ids.env"
fi
KEY="${ASC_KEY_ID:-}"
ISSUER="${ASC_ISSUER_ID:-}"
if [[ -z "$KEY" || -z "$ISSUER" ]]; then
  echo "✗ Set ASC_KEY_ID and ASC_ISSUER_ID (env or ~/.appstoreconnect/ids.env)" >&2
  exit 1
fi
KEYPATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY}.p8"
ARCHIVE=build/ios/archive/Runner.xcarchive
ARCHIVE_PLIST="$ARCHIVE/Products/Applications/Runner.app/Info.plist"
EXPORT_OPTS=ios/ExportOptions.plist
IPA=build/ios/ipa/castcircle.ipa

[[ -f "$KEYPATH" ]] || { echo "✗ missing ASC API key at $KEYPATH" >&2; exit 1; }

# 1. Bump the build number (+N -> +N+1). App Store Connect rejects a reused one.
if [[ "${1:-}" != "--no-bump" ]]; then
  CUR=$(grep -E '^version:' pubspec.yaml | sed 's/version: *//')   # e.g. 0.1.1+70
  BASE=${CUR%+*}; NUM=${CUR##*+}; NEW=$((NUM + 1))
  sed -i '' -E "s/^version: .*/version: ${BASE}+${NEW}/" pubspec.yaml
  echo "▶ bumped build to ${BASE}+${NEW}"
fi
WANT=$(grep -E '^version:' pubspec.yaml | sed -E 's/.*\+//')       # expected CFBundleVersion

# 2+3. Build the device .app, then the .xcarchive. The `|| true` is because the
#      ipa export sub-step always errors here (see header); the archive is made.
rm -rf "$ARCHIVE" build/ios/ipa
flutter build ios --release
flutter build ipa --release --export-options-plist="$EXPORT_OPTS" || true

# 4. GATE: never export/ship a stale archive.
GOT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$ARCHIVE_PLIST" 2>/dev/null || echo MISSING)
if [[ "$GOT" != "$WANT" ]]; then
  echo "✗ archive is build $GOT, expected $WANT — archive build failed. Not exporting." >&2
  exit 1
fi
echo "▶ archive verified at build $GOT — exporting IPA"

# 5. Export the signed IPA. PATH=/usr/bin first (system rsync) fixes "Copy
#    failed"; -allowProvisioningUpdates + the API key signs without a local cert.
PATH=/usr/bin:$PATH xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath build/ios/ipa \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEYPATH" \
  -authenticationKeyID "$KEY" \
  -authenticationKeyIssuerID "$ISSUER"

[[ -f "$IPA" ]] || { echo "✗ export produced no $IPA" >&2; ls -1 build/ios/ipa 2>/dev/null || true; exit 1; }

# 6. Upload to App Store Connect / TestFlight.
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY" --apiIssuer "$ISSUER"
echo "▶ uploaded build $GOT — pushing dSYMs to Crashlytics"

# 7. Push dSYMs so crashes symbolicate (best-effort; never blocks the ship).
if [[ -x ios/Pods/FirebaseCrashlytics/upload-symbols ]]; then
  ios/Pods/FirebaseCrashlytics/upload-symbols \
    -gsp ios/Runner/GoogleService-Info.plist -p ios "$ARCHIVE/dSYMs" \
    || echo "⚠ dSYM upload failed (non-fatal) — push manually if crashes are unsymbolicated"
else
  echo "⚠ FirebaseCrashlytics/upload-symbols not found (run 'cd ios && pod install') — dSYMs not pushed"
fi

echo "✓ build $GOT shipped to TestFlight"
