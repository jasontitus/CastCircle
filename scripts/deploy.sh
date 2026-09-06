#!/usr/bin/env bash
# Build CastCircle (release), install to the device with retries (the device
# refuses install assertions while busy/locked — error 4016), and launch it.
#
# Usage: ./scripts/deploy.sh            # build + install + launch
#        ./scripts/deploy.sh --no-build # install the existing build only
set -euo pipefail

DEVICE="${CASTCIRCLE_DEVICE:-00008150-000669303687801C}"
BUNDLE="com.tiltastech.castcircle"
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--no-build" ]]; then
  echo "Building (release)..."
  BUILD_LOG=$(mktemp "${TMPDIR:-/tmp}/castcircle-build.XXXXXX")
  trap 'rm -f "$BUILD_LOG"' EXIT
  if flutter build ios --release >"$BUILD_LOG" 2>&1; then
    tail -4 "$BUILD_LOG"
  else
    echo "✗ release build failed:" >&2
    cat "$BUILD_LOG" >&2
    exit 1
  fi
fi

APP="build/ios/iphoneos/Runner.app"
[[ -d "$APP" ]] || { echo "✗ no build at $APP" >&2; exit 1; }

for i in $(seq 1 6); do
  echo "install attempt $i..."
  if INSTALL_OUTPUT=$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1); then
    if [[ "$INSTALL_OUTPUT" == *"App installed"* ]]; then
      echo "✓ installed"
      echo "launching..."
      if LAUNCH_OUTPUT=$(xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" 2>&1); then
        echo "✓ launched"
        exit 0
      fi
      echo "✗ installed, but launch failed:" >&2
      printf '%s\n' "$LAUNCH_OUTPUT" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$INSTALL_OUTPUT" >&2
  sleep 8
done
echo "✗ install failed after retries — device locked/busy? Unlock and retry." >&2
exit 1
