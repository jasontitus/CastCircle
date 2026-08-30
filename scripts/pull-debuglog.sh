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

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [positive line count]" >&2
  exit 2
fi

DEVICE="${CASTCIRCLE_DEVICE:-00008150-000669303687801C}"
BUNDLE="com.tiltastech.castcircle"
LINES="${1:-120}"
case "$LINES" in
  ''|*[!0-9]*)
    echo "ERROR: line count must be a positive decimal (got '$LINES')" >&2
    exit 2
    ;;
esac
case "$LINES" in
  *[1-9]*) ;;
  *) echo "ERROR: line count must be greater than zero" >&2; exit 2 ;;
esac
while [[ "${#LINES}" -gt 1 && "$LINES" == 0* ]]; do
  LINES="${LINES#0}"
done

OUT="$(mktemp -d "${TMPDIR:-/tmp}/castcircle-debug.XXXXXX")"
chmod 700 "$OUT"
trap 'rm -rf "$OUT"' EXIT
LOG="$OUT/debug_log.txt"
COPY_LOG="$OUT/copy.log"

echo "Pulling debug_log.txt from $BUNDLE ($DEVICE)..."
if xcrun devicectl device copy from \
      --device "$DEVICE" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" \
      --source Documents/debug_log.txt \
      --destination "$LOG" >"$COPY_LOG" 2>&1; then
  tail -3 "$COPY_LOG"
else
  STATUS=$?
  tail -3 "$COPY_LOG" >&2
  echo "ERROR: copy failed with status $STATUS. Is the device unlocked and the app installed?" >&2
  exit "$STATUS"
fi

if [[ ! -f "$LOG" ]]; then
  echo "ERROR: copy reported success but did not create debug_log.txt" >&2
  exit 1
fi
if [[ ! -s "$LOG" ]]; then
  echo "ERROR: copied debug_log.txt is empty" >&2
  exit 1
fi

echo ""
echo "=== last $LINES lines of debug_log.txt ==="
tail -n "$LINES" "$LOG"
