#!/usr/bin/env bash
# Pull CastCircle's on-device debug_log.txt off the app container.
#
# The in-app DebugLogService now flushes every entry to disk synchronously, so
# this captures the full step-by-step trail right up to a hard kill — including
# OOM/jetsam SIGKILLs that Crashlytics never records. Pair with pull-crashlog.sh
# (symbolicated native/Dart crash) for the complete picture.
#
# Usage: ./scripts/pull-debuglog.sh [N]      # show last N lines (default 120)
set -euo pipefail

DEVICE="${CASTCIRCLE_DEVICE:-00008150-000669303687801C}"
BUNDLE="com.tiltastech.castcircle"
OUT="/tmp/castcircle-debug"
LINES="${1:-120}"

rm -rf "$OUT" && mkdir -p "$OUT"
echo "Pulling debug_log.txt from $BUNDLE ($DEVICE)..."
if ! xcrun devicectl device copy from \
      --device "$DEVICE" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" \
      --source Documents/debug_log.txt \
      --destination "$OUT/debug_log.txt" 2>&1 | tail -3; then
  echo "ERROR: copy failed. Is the device unlocked and the app installed?" >&2
  exit 1
fi

echo ""
echo "=== last $LINES lines of debug_log.txt ==="
tail -n "$LINES" "$OUT/debug_log.txt"
