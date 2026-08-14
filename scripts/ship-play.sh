#!/usr/bin/env bash
#
# Ship CastCircle to Google Play. Mirrors scripts/ship-testflight.sh for iOS.
# See docs/RELEASING.md for the full recipe + first-upload caveat.
#
#   ./scripts/ship-play.sh             # build signed AAB + upload to the internal track
#   ./scripts/ship-play.sh --closed    # upload to CLOSED testing (alpha) as a draft release
#   ./scripts/ship-play.sh --closed --live   # ...and roll it out to testers immediately
#   ./scripts/ship-play.sh --validate  # dry run: Google validates the upload, nothing ships
#   ./scripts/ship-play.sh --build     # build the signed AAB only (no upload)
#
# Prereqs (set up once, both git-ignored / local-only):
#   - android/key.properties + android/app/castcircle-upload.jks  (release signing)
#   - ~/.google-play/play-store-key.json                          (Play service account, upload only)
#
# NOTE: the FIRST upload must be done by hand in Play Console (the API can't
# create the app listing). After that this script automates every upload.
set -euo pipefail
cd "$(dirname "$0")/.."

# Which track, and whether the release goes live or waits in Play Console.
LANE=beta            # fastlane lane 'beta' = internal track
LANE_ARGS=""
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --closed)   LANE=closed_beta ;;
    --live)     LANE_ARGS="status:completed" ;;
    --validate) LANE_ARGS="${LANE_ARGS} validate:true" ;;
    --build)    BUILD_ONLY=1 ;;
    *) echo "✗ unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [[ "$LANE" == "beta" && -n "$LANE_ARGS" ]]; then
  echo "✗ --live/--validate only apply to --closed (the internal lane has no such options)." >&2
  exit 2
fi

# 1. Release signing must exist, or Gradle silently falls back to DEBUG signing
#    and Play rejects the build.
if [[ ! -f android/key.properties ]]; then
  echo "✗ android/key.properties missing — release build would be debug-signed." >&2
  echo "  See docs/RELEASING.md → Android → Signing." >&2
  exit 1
fi

echo "▶ Building signed release AAB..."
flutter build appbundle --release
AAB="build/app/outputs/bundle/release/app-release.aab"
[[ -f "$AAB" ]] || { echo "✗ AAB not produced at $AAB" >&2; exit 1; }

# Sanity-check it's signed with our upload key, not the Android debug key.
# Enumerate the actual signature entry instead of assuming 'UPLOAD.RSA':
# with a differently-named alias the old fixed path came back empty and the
# guard silently printed "signed: unknown" and proceeded — failing at its
# one job. An unreadable cert is now fatal, not a shrug.
KT="$(/usr/libexec/java_home 2>/dev/null)/bin/keytool"; [[ -x "$KT" ]] || KT=keytool
SIG_ENTRY="$(unzip -l "$AAB" 'META-INF/*' 2>/dev/null | grep -oE 'META-INF/[^ ]+\.(RSA|DSA|EC)' | head -1 || true)"
OWNER=""
if [[ -n "$SIG_ENTRY" ]]; then
  OWNER="$(unzip -p "$AAB" "$SIG_ENTRY" 2>/dev/null | "$KT" -printcert 2>/dev/null | grep -m1 'Owner:' || true)"
fi
if [[ -z "$OWNER" ]]; then
  echo "✗ Could not read the AAB's signing cert (entry: ${SIG_ENTRY:-none}) — refusing to upload unverified." >&2
  exit 1
fi
if echo "$OWNER" | grep -qi 'Android Debug'; then
  echo "✗ AAB is DEBUG-signed ($OWNER) — Play will reject it. Check key.properties." >&2
  exit 1
fi
echo "✓ AAB built ($(du -h "$AAB" | cut -f1)), signed: $OWNER"

# 3. Everything Play will reject us for, checked here in seconds instead of
#    days later in review (metadata limits, release notes for THIS build,
#    store graphics, screenshot aspect ratios, signing). This runs AFTER the
#    build: preflight's staleness check compares the AAB against the source
#    tree, so running it first always judged the PREVIOUS build.
echo "▶ Preflight..."
if ! ./scripts/play-preflight.sh; then
  echo "✗ Preflight failed — not uploading." >&2
  exit 1
fi

if (( BUILD_ONLY )); then
  echo "▶ --build: skipping upload. AAB at $AAB"
  exit 0
fi

# 2. Upload needs the Play service account.
if [[ ! -f "$HOME/.google-play/play-store-key.json" ]]; then
  echo "✗ ~/.google-play/play-store-key.json missing — can't upload via fastlane." >&2
  echo "  Either add it, or upload $AAB manually in Play Console (required for the FIRST upload)." >&2
  exit 1
fi

if [[ "$LANE" == "closed_beta" ]]; then
  echo "▶ Uploading to Play CLOSED testing (alpha) via fastlane... ${LANE_ARGS:-(draft release)}"
else
  echo "▶ Uploading to Play internal track via fastlane..."
fi
# shellcheck disable=SC2086  # LANE_ARGS is intentionally word-split into fastlane options
( cd fastlane && fastlane android "$LANE" $LANE_ARGS )
echo "✓ shipped to Play ($LANE)"
