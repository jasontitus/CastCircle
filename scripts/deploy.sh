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
  flutter build ios --release 2>&1 | tail -4
fi

APP="build/ios/iphoneos/Runner.app"
[[ -d "$APP" ]] || { echo "✗ no build at $APP" >&2; exit 1; }

for i in $(seq 1 6); do
  echo "install attempt $i..."
  if xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | grep -q "App installed"; then
    xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
    echo "✓ deployed + launched"
    exit 0
  fi
  sleep 8
done
echo "✗ install failed after retries — device locked/busy? Unlock and retry." >&2
exit 1
