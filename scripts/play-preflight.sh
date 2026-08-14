#!/usr/bin/env bash
#
# Pre-release gate for Google Play. Checks everything that can be checked
# from this machine BEFORE an upload, so a release fails here (in seconds)
# rather than in Play Console review (in days).
#
#   ./scripts/play-preflight.sh            # check only
#   ./scripts/play-preflight.sh --build    # build the AAB first, then check
#
# Exit code 0 = ready to upload. Anything else prints what to fix.
set -euo pipefail
cd "$(dirname "$0")/.."

FAIL=0
warn() { echo "⚠ $*"; }
bad()  { echo "✗ $*"; FAIL=1; }
ok()   { echo "✓ $*"; }

VERSION_LINE="$(grep '^version:' pubspec.yaml)"
VERSION_NAME="${VERSION_LINE#version: }"; VERSION_NAME="${VERSION_NAME%%+*}"
VERSION_CODE="${VERSION_LINE##*+}"
echo "▶ CastCircle $VERSION_NAME (versionCode $VERSION_CODE)"
echo

# ── 1. Signing ────────────────────────────────────────────
if [[ ! -f android/key.properties ]]; then
  bad "android/key.properties missing — the build would be DEBUG signed and Play will reject it."
else
  STOREFILE="$(grep '^storeFile=' android/key.properties | cut -d= -f2-)"
  if [[ -f "android/app/$STOREFILE" ]]; then
    ok "release keystore present (android/app/$STOREFILE)"
  else
    bad "keystore android/app/$STOREFILE not found (storeFile is relative to android/app/)"
  fi
fi

# ── 2. Play service account (upload credentials) ──────────
KEY="$HOME/.google-play/play-store-key.json"
if [[ -f "$KEY" ]]; then
  ok "Play service-account key present"
else
  bad "missing $KEY — fastlane cannot upload (see docs/RELEASING.md)"
fi

# ── 3. Store listing metadata ─────────────────────────────
MD=fastlane/metadata/android/en-US
for f in title.txt short_description.txt full_description.txt; do
  if [[ -s "$MD/$f" ]]; then ok "metadata/$f"; else bad "metadata/$f missing or empty"; fi
done
# Play's hard limits — exceeded text is rejected at upload.
if [[ -s "$MD/title.txt" ]] && (( $(wc -c < "$MD/title.txt") > 31 )); then
  bad "title.txt must be ≤ 30 characters"
fi
if [[ -s "$MD/short_description.txt" ]] && (( $(wc -c < "$MD/short_description.txt") > 81 )); then
  bad "short_description.txt must be ≤ 80 characters"
fi
if [[ -s "$MD/full_description.txt" ]] && (( $(wc -c < "$MD/full_description.txt") > 4001 )); then
  bad "full_description.txt must be ≤ 4000 characters"
fi

# ── 4. Release notes for THIS versionCode ─────────────────
if [[ -s "$MD/changelogs/$VERSION_CODE.txt" ]]; then
  ok "release notes for versionCode $VERSION_CODE"
else
  bad "no release notes: $MD/changelogs/$VERSION_CODE.txt (run scripts/play-changelog.sh)"
fi

# ── 5. Graphics ───────────────────────────────────────────
IMG="$MD/images"
if [[ -f "$IMG/icon.png" ]]; then
  read -r W Hh <<<"$(sips -g pixelWidth -g pixelHeight "$IMG/icon.png" 2>/dev/null | awk '/pixel/{print $2}' | tr '\n' ' ')"
  [[ "$W" == "512" && "$Hh" == "512" ]] && ok "icon.png 512×512" || bad "icon.png must be 512×512 (is ${W}×${Hh})"
  # Play rejects a store icon with an alpha channel.
  HAS_ALPHA=$(python3 -c "from PIL import Image; print(1 if Image.open('$IMG/icon.png').mode in ('RGBA','LA','P') else 0)" 2>/dev/null || echo 0)
  if [[ "$HAS_ALPHA" == "1" ]]; then
    bad "icon.png has an alpha channel — Play rejects it (regenerate: scripts/generate-icons.py)"
  fi
else
  bad "$IMG/icon.png missing"
fi
# The store graphics are generated from the source artwork; if that artwork is
# newer, the listing would ship the previous icon. (This shipped the stock
# Flutter logo once, because nobody had replaced the placeholder icons.)
ART=assets/castcircleicon.jpeg
if [[ -f "$ART" && -f "$IMG/icon.png" ]] && (( $(stat -f %m "$ART") > $(stat -f %m "$IMG/icon.png") )); then
  bad "$ART is newer than the generated icons — run: python3 scripts/generate-icons.py"
fi
if [[ -f "$IMG/featureGraphic.png" ]]; then
  read -r W Hh <<<"$(sips -g pixelWidth -g pixelHeight "$IMG/featureGraphic.png" 2>/dev/null | awk '/pixel/{print $2}' | tr '\n' ' ')"
  [[ "$W" == "1024" && "$Hh" == "500" ]] && ok "featureGraphic.png 1024×500" || bad "featureGraphic must be 1024×500 (is ${W}×${Hh})"
else
  bad "$IMG/featureGraphic.png missing"
fi
SHOTS=$(ls "$IMG/phoneScreenshots"/*.png 2>/dev/null | wc -l | tr -d ' ' || true)
SHOTS=${SHOTS:-0}
if (( SHOTS >= 2 )); then
  ok "$SHOTS phone screenshots"
  # Play rejects anything outside a 1:2 … 2:1 aspect ratio.
  for s in "$IMG/phoneScreenshots"/*.png; do
    read -r W Hh <<<"$(sips -g pixelWidth -g pixelHeight "$s" 2>/dev/null | awk '/pixel/{print $2}' | tr '\n' ' ')"
    RATIO=$(python3 -c "print(round(max($W/$Hh, $Hh/$W), 3))")
    TOO_TALL=$(python3 -c "print(1 if $RATIO > 2.0 else 0)")
    (( TOO_TALL == 0 )) || bad "$(basename "$s") is ${W}×${Hh} (ratio $RATIO) — Play's limit is 2:1"
  done
else
  bad "need at least 2 phone screenshots in $IMG/phoneScreenshots (run scripts/generate-play-screenshots.sh)"
fi

# ── 6. The bundle itself ──────────────────────────────────
AAB=build/app/outputs/bundle/release/app-release.aab
if [[ "${1:-}" == "--build" ]]; then
  echo "▶ Building release AAB..."
  flutter build appbundle --release >/dev/null
fi
if [[ -f "$AAB" ]]; then
  # Is this AAB actually built from the current tree? Age alone doesn't
  # answer that, and a stale artifact is the classic "I shipped the wrong
  # build" mistake — including shipping the previous versionCode, which Play
  # rejects as a duplicate.
  NEWER=$(find pubspec.yaml lib android/app/src -newer "$AAB" -type f -print -quit 2>/dev/null || true)
  if [[ -n "$NEWER" ]]; then
    bad "AAB is older than $NEWER — rebuild: ./scripts/play-preflight.sh --build"
  else
    ok "AAB is newer than every source file"
  fi
  SIZE_MB=$(( $(stat -f %z "$AAB") / 1024 / 1024 ))
  ok "AAB present (${SIZE_MB}MB on disk; per-device download is far smaller — see docs/RELEASING.md)"
else
  bad "no AAB at $AAB — run with --build"
fi

echo
if (( FAIL )); then
  echo "✗ NOT ready to upload — fix the ✗ items above."
  exit 1
fi
echo "✓ Preflight passed. Upload with: ./scripts/ship-play.sh"
echo "  Reminder — Console-only steps (once per app): Data safety form,"
echo "  content rating questionnaire, target audience, and the FIRST manual"
echo "  upload. See docs/RELEASING.md → Android → Play Console checklist."
