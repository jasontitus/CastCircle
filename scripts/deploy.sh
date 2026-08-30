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

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--no-build" ) ]]; then
  echo "Usage: $0 [--no-build]" >&2
  exit 2
fi

if [[ "${1:-}" != "--no-build" ]]; then
  echo "Building (release)..."
  flutter build ios --release 2>&1 | tail -4
fi

APP="build/ios/iphoneos/Runner.app"
[[ -d "$APP" ]] || { echo "✗ no build at $APP" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/castcircle-deploy.XXXXXX")"
chmod 700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT
INSTALL_LOG="$WORKDIR/install.log"
LAUNCH_LOG="$WORKDIR/launch.log"

ATTEMPT=1
while [[ $ATTEMPT -le 6 ]]; do
  echo "install attempt $ATTEMPT..."
  if xcrun devicectl device install app --device "$DEVICE" "$APP" >"$INSTALL_LOG" 2>&1; then
    if grep -F "App installed" "$INSTALL_LOG" >/dev/null; then
      echo "✓ installed"
      if xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >"$LAUNCH_LOG" 2>&1; then
        echo "✓ launched"
        exit 0
      else
        STATUS=$?
        echo "✗ install succeeded, but launch failed (status $STATUS):" >&2
        cat "$LAUNCH_LOG" >&2
        exit "$STATUS"
      fi
    fi
    echo "install command succeeded without confirming 'App installed':" >&2
  else
    STATUS=$?
    echo "install attempt $ATTEMPT failed (status $STATUS):" >&2
  fi
  tail -20 "$INSTALL_LOG" >&2
  ATTEMPT=$((ATTEMPT + 1))
  if [[ $ATTEMPT -le 6 ]]; then
    sleep 8
  fi
done

echo "✗ install failed after retries — device locked/busy? Unlock and retry." >&2
exit 1
