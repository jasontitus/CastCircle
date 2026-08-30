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

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [auto|ipad|iphone|phone|udid]" >&2
  exit 2
fi

CRASHDIR="$(mktemp -d "${TMPDIR:-/tmp}/castcircle-crashes.XXXXXX")"
chmod 700 "$CRASHDIR"
trap 'rm -rf "$CRASHDIR"' EXIT
if [[ -L "$CRASHDIR" || ! -d "$CRASHDIR" ]]; then
  echo "ERROR: private crash directory is not a real directory" >&2
  exit 1
fi
OWNER_UID="$(stat -f %u "$CRASHDIR")"
if [[ "$OWNER_UID" != "$(id -u)" ]]; then
  echo "ERROR: private crash directory has unexpected owner $OWNER_UID" >&2
  exit 1
fi

TARGET="${1:-auto}"
UDID=""

first_flutter_udid() {
  awk -F'•' -v pattern="$1" '
    tolower($0) ~ tolower(pattern) {
      value=$2
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      if (first == "") first=value
    }
    END { print first }
  '
}

if [[ "$TARGET" == "auto" ]]; then
  if DEVICE_OUTPUT="$(xcrun devicectl list devices 2>/dev/null)"; then
    UDID="$(printf '%s\n' "$DEVICE_OUTPUT" | awk 'tolower($0) ~ /iphone|ipad/ && first == "" { first=$NF } END { print first }')"
  fi
  if [[ -z "$UDID" ]]; then
    if FLUTTER_DEVICES="$(flutter devices 2>/dev/null)"; then
      UDID="$(printf '%s\n' "$FLUTTER_DEVICES" | first_flutter_udid 'ios[[:space:]]')"
    fi
  fi
elif [[ "$TARGET" == "ipad" ]]; then
  if ! FLUTTER_DEVICES="$(flutter devices 2>/dev/null)"; then
    echo "ERROR: flutter could not list devices" >&2
    exit 1
  fi
  UDID="$(printf '%s\n' "$FLUTTER_DEVICES" | first_flutter_udid 'ipad')"
elif [[ "$TARGET" == "iphone" || "$TARGET" == "phone" ]]; then
  if ! FLUTTER_DEVICES="$(flutter devices 2>/dev/null)"; then
    echo "ERROR: flutter could not list devices" >&2
    exit 1
  fi
  UDID="$(printf '%s\n' "$FLUTTER_DEVICES" | awk -F'•' '
    tolower($0) ~ /iphone|jazzman/ {
      value=$2
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      if (tolower($0) !~ /wireless/ && wired == "") wired=value
      if (any == "") any=value
    }
    END { print wired != "" ? wired : any }
  ')"
else
  UDID="$TARGET"
fi

if [[ -z "$UDID" ]]; then
  echo "ERROR: No device found for target '$TARGET'" >&2
  echo "Connected iOS devices:" >&2
  if FLUTTER_DEVICES="$(flutter devices 2>/dev/null)"; then
    if ! printf '%s\n' "$FLUTTER_DEVICES" | grep -E 'ios[[:space:]]' >&2; then
      echo "  (none)" >&2
    fi
  else
    echo "  (device listing failed)" >&2
  fi
  exit 1
fi

echo "Device: $UDID"
echo "Pulling crash logs..."
PULL_ERR="$CRASHDIR/pull.stderr"
if idevicecrashreport -u "$UDID" -k "$CRASHDIR" 2>"$PULL_ERR"; then
  :
else
  STATUS=$?
  echo "ERROR: crash-report pull failed with status $STATUS:" >&2
  if [[ -s "$PULL_ERR" ]]; then
    cat "$PULL_ERR" >&2
  else
    echo "  idevicecrashreport produced no diagnostic" >&2
  fi
  exit "$STATUS"
fi

MANIFEST="$CRASHDIR/crashes.nul"
if ! find -P "$CRASHDIR" -type f \( -name 'Runner-*.ips' -o -name 'ExcUserFault_Runner-*.ips' \) -print0 >"$MANIFEST"; then
  echo "ERROR: could not enumerate pulled crash logs" >&2
  exit 1
fi
if [[ ! -s "$MANIFEST" ]]; then
  echo "No Runner crash logs found on device."
  exit 0
fi
if [[ -z "${HOME:-}" ]]; then
  echo "ERROR: HOME is required to persist the selected crash report" >&2
  exit 1
fi
LOG_ROOT="$HOME/Library/Logs/CastCircle"
if [[ -L "$LOG_ROOT" || ( -e "$LOG_ROOT" && ! -d "$LOG_ROOT" ) ]]; then
  echo "ERROR: crash log destination is not a real directory: $LOG_ROOT" >&2
  exit 1
fi
if [[ ! -d "$LOG_ROOT" ]]; then
  if ! mkdir -p "$LOG_ROOT"; then
    echo "ERROR: could not create crash log destination $LOG_ROOT" >&2
    exit 1
  fi
fi
chmod 700 "$LOG_ROOT"
LOG_ROOT_OWNER="$(stat -f %u "$LOG_ROOT")"
if [[ "$LOG_ROOT_OWNER" != "$(id -u)" ]]; then
  echo "ERROR: crash log destination has unexpected owner $LOG_ROOT_OWNER" >&2
  exit 1
fi
REPORT_DIR="$(mktemp -d "$LOG_ROOT/crash-report.XXXXXX")"
chmod 700 "$REPORT_DIR"
REPORT_DIR_OWNER="$(stat -f %u "$REPORT_DIR")"
if [[ -L "$REPORT_DIR" || "$REPORT_DIR_OWNER" != "$(id -u)" ]]; then
  echo "ERROR: unique crash report directory failed ownership validation" >&2
  exit 1
fi


if python3 - "$MANIFEST" "$REPORT_DIR" <<'PYEOF'
import json
import os
import shutil
import sys

manifest = sys.argv[1]
report_directory = sys.argv[2]
with open(manifest, "rb") as manifest_file:
    paths = [os.fsdecode(value) for value in manifest_file.read().split(b"\0") if value]
paths.sort(key=lambda value: os.path.basename(value), reverse=True)
latest = paths[0]
persisted = os.path.join(report_directory, "Runner-latest.ips")
shutil.copyfile(latest, persisted)
os.chmod(persisted, 0o600)

print()
print(f"=== MOST RECENT CRASH: {os.path.basename(latest)} ===")
print()

with open(persisted, encoding="utf-8") as crash_file:
    lines = crash_file.readlines()
if len(lines) < 2:
    raise ValueError("crash report does not contain metadata and report JSON")
meta = json.loads(lines[0])
crash = json.loads("".join(lines[1:]))

print(f"App: {meta.get('app_name', '?')} {meta.get('app_version', '?')} (build {meta.get('build_version', '?')})")
print(f"Time: {meta.get('timestamp', '?')}")
print(f"OS: {meta.get('os_version', '?')}")
print(f"Bundle: {meta.get('bundleID', '?')}")
print()

exception = crash.get("exception", {})
print(f"Exception Type: {exception.get('type', '?')} ({exception.get('signal', '?')})")
if "subtype" in exception:
    print(f"Exception Subtype: {exception['subtype']}")
if crash.get("termination", {}).get("reason"):
    print(f"Termination Reason: {crash['termination']['reason']}")
print()

last_exception = crash.get("lastExceptionBacktrace", [])
if last_exception:
    print("=== LAST EXCEPTION BACKTRACE (top 20 frames) ===")
    for frame in last_exception[:20]:
        image_index = frame.get("imageIndex", "?")
        symbol = frame.get("symbol", "")
        offset = frame.get("imageOffset", 0)
        image_name = ""
        if isinstance(image_index, int) and image_index < len(crash.get("usedImages", [])):
            image_name = crash["usedImages"][image_index].get("name", "")
        address = hex(offset) if isinstance(offset, int) else str(offset)
        line = f"  {image_name:30s} {address}"
        if symbol:
            line += f" {symbol}"
        print(line)
    print()

crashed_index = crash.get("faultingThread", 0)
threads = crash.get("threads", [])
if isinstance(crashed_index, int) and 0 <= crashed_index < len(threads):
    frames = threads[crashed_index].get("frames", [])
    print(f"=== CRASHED THREAD {crashed_index} (top 30 frames) ===")
    for frame in frames[:30]:
        image_index = frame.get("imageIndex", "?")
        symbol = frame.get("symbol", "")
        offset = frame.get("imageOffset", 0)
        image_name = ""
        if isinstance(image_index, int) and image_index < len(crash.get("usedImages", [])):
            image_name = crash["usedImages"][image_index].get("name", "")
        address = hex(offset) if isinstance(offset, int) else str(offset)
        line = f"  {image_name:30s} {address}"
        if symbol:
            line += f" {symbol}"
        print(line)
    print()

if crash.get("memoryStatus"):
    memory_status = crash["memoryStatus"]
    print(f"Memory: footprint={memory_status.get('memoryFootprint', '?')} limit={memory_status.get('memoryLimit', '?')}")

print(f"Full crash log: {persisted}")
if len(paths) > 1:
    print()
    print("=== OTHER RECENT CRASHES ===")
    for path in paths[1:6]:
        print(f"  {os.path.basename(path)}")
PYEOF
then
  :
else
  STATUS=$?
  echo "ERROR: could not parse the pulled crash report (status $STATUS)" >&2
  exit "$STATUS"
fi
