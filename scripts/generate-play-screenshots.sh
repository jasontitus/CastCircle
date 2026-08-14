#!/usr/bin/env bash
#
# Generate Google Play phone screenshots by driving the app through its core
# flows on a CONNECTED Android device (or a running emulator), then convert
# them to Play-compliant images.
#
#   ./scripts/generate-play-screenshots.sh
#
# Output: fastlane/metadata/android/en-US/images/phoneScreenshots/
#
# Why not reuse the iOS shots: Play rejects anything outside a 2:1 aspect
# ratio, and modern phones are ~9:19.5 — both the iPhone screenshots AND a
# raw Galaxy capture are too tall, so each frame is letterboxed onto a 1:2
# canvas here rather than being cropped (cropping cut off the app bar).
#
# NOTE: this takes over the device for a few minutes and installs a test
# build over the app. Recordings/imports on the device are not touched, but
# don't run it mid-rehearsal.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="build/screenshots-android"
PLAY_DIR="fastlane/metadata/android/en-US/images/phoneScreenshots"

# --convert-only re-runs just the image conversion over frames already in
# build/screenshots-android, without touching the device.
CONVERT_ONLY=0
if [[ "${1:-}" == "--convert-only" ]]; then CONVERT_ONLY=1; shift; fi

DEVICE="${1:-}"
if [[ -z "$DEVICE" && $CONVERT_ONLY -eq 0 ]]; then
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [[ -z "$DEVICE" && $CONVERT_ONLY -eq 0 ]]; then
  echo "✗ No Android device/emulator connected (adb devices is empty)." >&2
  echo "  Plug in a phone with USB debugging, or start an emulator." >&2
  exit 1
fi

DRIVE_STATUS=0
if (( CONVERT_ONLY )); then
  echo "▶ --convert-only: reusing the frames already in $OUT_DIR"
  mkdir -p "$PLAY_DIR"
else
  echo "▶ Using device $DEVICE"
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR" "$PLAY_DIR"

  echo "▶ Driving the app (a few minutes)..."
  # A failing test does NOT mean a failed capture: the driver writes each
  # frame as it arrives, and debug-only framework assertions in unrelated
  # widgets (e.g. ListTile-inside-PopupMenuItem) fail the test after every
  # screenshot has already landed. Judge on the frames, but never hide the
  # failure — print it loudly below.
  set +e
  flutter drive \
    --driver=test_driver/screenshot_driver.dart \
    --target=integration_test/screenshot_test.dart \
    -d "$DEVICE"
  DRIVE_STATUS=$?
  set -e
fi

shopt -s nullglob
RAW=("$OUT_DIR"/*.png)
if (( ${#RAW[@]} == 0 )); then
  echo "✗ No screenshots produced in $OUT_DIR." >&2
  (( DRIVE_STATUS == 0 )) || echo "  flutter drive exited $DRIVE_STATUS — see its output above." >&2
  exit 1
fi
if (( DRIVE_STATUS != 0 )); then
  echo
  echo "⚠ ────────────────────────────────────────────────────────────"
  echo "⚠ flutter drive exited $DRIVE_STATUS, but ${#RAW[@]} frames were captured."
  echo "⚠ Converting them anyway. READ the drive output above before"
  echo "⚠ trusting these images — a genuine mid-run failure would show"
  echo "⚠ up as missing or half-drawn frames."
  echo "⚠ ────────────────────────────────────────────────────────────"
  echo
fi

# Play accepts at most 8 phone screenshots and shows them in filename order,
# so the set and the order are chosen here rather than being whatever the
# capture run happened to produce. Anything captured but not listed is
# reported below, never dropped silently.
PLAY_ORDER=(
  06_rehearsal_actor        # the core loop first: rehearse against your cues
  05_rehearsal_readthrough
  04_production_hub
  09_cast_manager
  03_import_preview
  08_ai_models
  07_settings
  02_home_with_production
)

rm -f "$PLAY_DIR"/*.png   # a reorder must not leave orphans behind
echo "▶ Converting frames to Play-compliant images..."
python3 - "$OUT_DIR" "$PLAY_DIR" "${PLAY_ORDER[@]}" <<'PYEOF'
import sys, os, glob
from PIL import Image

src_dir, dst_dir = sys.argv[1], sys.argv[2]
order = sys.argv[3:]
# Play: 320px–3840px per side, aspect ratio no more extreme than 2:1.
# Letterbox onto exactly 1:2 so tall phone captures stay whole.
TARGET_W, TARGET_H = 1080, 2160
BG = (18, 16, 24)  # the app's dark surface, so bars read as part of the design

available = {os.path.splitext(os.path.basename(p))[0]: p
             for p in glob.glob(os.path.join(src_dir, '*.png'))}
chosen = [n for n in order if n in available]
missing = [n for n in order if n not in available]
skipped = sorted(set(available) - set(chosen))
if missing:
    print('  ! wanted but not captured: ' + ', '.join(missing))
if skipped:
    print('  · captured but not used (Play caps at 8): ' + ', '.join(skipped))
if len(chosen) < 2:
    sys.exit('✗ need at least 2 usable frames, have %d' % len(chosen))

for i, name in enumerate(chosen, 1):
    path = available[name]
    im = Image.open(path).convert('RGB')
    scale = min(TARGET_W / im.width, TARGET_H / im.height)
    im = im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))),
                   Image.LANCZOS)
    canvas = Image.new('RGB', (TARGET_W, TARGET_H), BG)
    canvas.paste(im, ((TARGET_W - im.width) // 2, (TARGET_H - im.height) // 2))
    # Strip the capture-order prefix so the Play prefix is the only one.
    label = name.split('_', 1)[1] if name[:2].isdigit() else name
    out = os.path.join(dst_dir, f'{i:02d}_{label}.png')
    canvas.save(out)
    print(f'  {out}  {canvas.size[0]}x{canvas.size[1]}')
PYEOF

echo
echo "✓ Play screenshots in $PLAY_DIR"
ls -1 "$PLAY_DIR"
echo
echo "Next: ./scripts/play-preflight.sh"
