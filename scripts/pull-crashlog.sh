#!/bin/bash
# Pull the most recent crash log from a connected iOS device and output
# a Claude-friendly summary.
#
# Usage:
#   ./scripts/pull-crashlog.sh          # auto-detect device
#   ./scripts/pull-crashlog.sh ipad     # target iPad
#   ./scripts/pull-crashlog.sh iphone   # target iPhone
#   ./scripts/pull-crashlog.sh <udid>   # target by UDID

set -euo pipefail

CRASHDIR=$(mktemp -d "${TMPDIR:-/tmp}/castcircle-crashes.XXXXXX")
KEEP_CRASHDIR=0
cleanup() {
  if [[ "$KEEP_CRASHDIR" -eq 0 ]]; then
    rm -rf "$CRASHDIR" || true
  fi
}
trap cleanup EXIT

# Resolve device
TARGET="${1:-auto}"
UDID=""

if [[ "$TARGET" == "auto" ]]; then
  UDID=$(xcrun devicectl list devices 2>/dev/null | grep -i "iphone\|ipad" | head -1 | awk '{print $NF}' || true)
  if [[ -z "$UDID" ]]; then
    UDID=$(flutter devices 2>/dev/null | grep -E "ios\s" | head -1 | awk -F'•' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
  fi
elif [[ "$TARGET" == "ipad" ]]; then
  UDID=$(flutter devices 2>/dev/null | grep -i ipad | awk -F'•' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | head -1)
elif [[ "$TARGET" == "iphone" || "$TARGET" == "phone" ]]; then
  UDID=$(flutter devices 2>/dev/null | grep -i -E "iphone|jazzman" | grep -v wireless | awk -F'•' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | head -1)
  if [[ -z "$UDID" ]]; then
    UDID=$(flutter devices 2>/dev/null | grep -i -E "iphone|jazzman" | awk -F'•' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | head -1)
  fi
else
  UDID="$TARGET"
fi

if [[ -z "$UDID" ]]; then
  echo "ERROR: No device found for target '$TARGET'"
  echo "Connected devices:"
  flutter devices 2>/dev/null | grep ios || echo "  (none)"
  exit 1
fi

echo "Device: $UDID"
echo "Pulling crash logs..."

# Pull crash logs (keep on device with -k). A fresh directory ensures the
# summary can only include reports returned by this invocation.
if ! idevicecrashreport -u "$UDID" -k "$CRASHDIR"; then
  echo "ERROR: Failed to pull crash logs from device $UDID." >&2
  exit 1
fi

# Find Runner crash logs from this pull, sorted by filename (contains timestamp)
CRASHES=$(find "$CRASHDIR" \( -name "Runner-*.ips" -o -name "ExcUserFault_Runner-*.ips" \) | while read f; do echo "$(basename "$f") $f"; done | sort -r | awk '{print $2}')

if [[ -z "$CRASHES" ]]; then
  echo "No Runner crash logs found on device."
  exit 0
fi

LATEST=$(echo "$CRASHES" | head -1)
# Keep this unique pull directory so the reported path remains usable after
# the script exits.
KEEP_CRASHDIR=1
echo ""
echo "=== MOST RECENT CRASH: $(basename "$LATEST") ==="
echo ""

# Parse the .ips JSON crash log and extract useful info
python3 -c "
import json, sys

with open('$LATEST') as f:
    lines = f.readlines()

# First line is metadata JSON, rest is crash report JSON
meta = json.loads(lines[0])
crash = json.loads(''.join(lines[1:]))

print(f\"App: {meta.get('app_name', '?')} {meta.get('app_version', '?')} (build {meta.get('build_version', '?')})\")
print(f\"Time: {meta.get('timestamp', '?')}\")
print(f\"OS: {meta.get('os_version', '?')}\")
print(f\"Bundle: {meta.get('bundleID', '?')}\")
print()

# Exception info
exc = crash.get('exception', {})
print(f\"Exception Type: {exc.get('type', '?')} ({exc.get('signal', '?')})\")
if 'subtype' in exc:
    print(f\"Exception Subtype: {exc['subtype']}\")
if crash.get('termination', {}).get('reason'):
    print(f\"Termination Reason: {crash['termination']['reason']}\")
print()

# Last exception backtrace (Dart/Flutter typically here)
last_exc = crash.get('lastExceptionBacktrace', [])
if last_exc:
    print('=== LAST EXCEPTION BACKTRACE (top 20 frames) ===')
    for frame in last_exc[:20]:
        img = frame.get('imageIndex', '?')
        sym = frame.get('symbol', '')
        offset = frame.get('imageOffset', 0)
        img_name = ''
        if isinstance(img, int) and 'usedImages' in crash:
            img_name = crash['usedImages'][img].get('name', '')
        addr = hex(offset) if isinstance(offset, int) else str(offset)
        line = f\"  {img_name:30s} {addr}\"
        if sym:
            line += f\" {sym}\"
        print(line)
    print()

# Crashed thread backtrace
crashed_idx = crash.get('faultingThread', 0)
threads = crash.get('threads', [])
if crashed_idx < len(threads):
    thread = threads[crashed_idx]
    frames = thread.get('frames', [])
    print(f\"=== CRASHED THREAD {crashed_idx} (top 30 frames) ===\")
    for frame in frames[:30]:
        img = frame.get('imageIndex', '?')
        sym = frame.get('symbol', '')
        offset = frame.get('imageOffset', 0)
        img_name = ''
        if isinstance(img, int) and 'usedImages' in crash:
            img_name = crash['usedImages'][img].get('name', '')
        addr = hex(offset) if isinstance(offset, int) else str(offset)
        line = f\"  {img_name:30s} {addr}\"
        if sym:
            line += f\" {sym}\"
        print(line)
    print()

# Jetsam info if memory kill
if crash.get('memoryStatus'):
    ms = crash['memoryStatus']
    print(f\"Memory: footprint={ms.get('memoryFootprint', '?')} limit={ms.get('memoryLimit', '?')}\")

" 2>&1 || {
  # Fallback: just show raw header + exception
  echo "--- Raw crash header ---"
  head -5 "$LATEST"
  echo ""
  grep -A5 -i "exception\|termination\|fault" "$LATEST" | head -30 || true
}
echo "Full crash log: $LATEST"

# List other recent crashes
OTHER=$(echo "$CRASHES" | tail -n +2 | head -5)
if [[ -n "$OTHER" ]]; then
  echo ""
  echo "=== OTHER RECENT CRASHES ==="
  echo "$OTHER" | while read f; do
    echo "  $(basename "$f")"
  done
fi
