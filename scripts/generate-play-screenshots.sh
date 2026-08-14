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

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [[ -z "$DEVICE" ]]; then
  echo "✗ No Android device/emulator connected (adb devices is empty)." >&2
  echo "  Plug in a phone with USB debugging, or start an emulator." >&2
  exit 1
fi
echo "▶ Using device $DEVICE"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" "$PLAY_DIR"

echo "▶ Driving the app (a few minutes)..."
flutter drive \
  --driver=test_driver/screenshot_driver.dart \
  --target=integration_test/screenshot_test.dart \
  -d "$DEVICE"

shopt -s nullglob
RAW=("$OUT_DIR"/*.png)
if (( ${#RAW[@]} == 0 )); then
  echo "✗ No screenshots produced in $OUT_DIR." >&2
  exit 1
fi

echo "▶ Converting ${#RAW[@]} frames to Play-compliant images..."
python3 - "$OUT_DIR" "$PLAY_DIR" <<'PYEOF'
import sys, os, glob
from PIL import Image

src_dir, dst_dir = sys.argv[1], sys.argv[2]
# Play: 320px–3840px per side, aspect ratio no more extreme than 2:1.
# Letterbox onto exactly 1:2 so tall phone captures stay whole.
TARGET_W, TARGET_H = 1080, 2160
BG = (18, 16, 24)  # the app's dark surface, so bars read as part of the design

for i, path in enumerate(sorted(glob.glob(os.path.join(src_dir, '*.png'))), 1):
    im = Image.open(path).convert('RGB')
    scale = min(TARGET_W / im.width, TARGET_H / im.height)
    im = im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))),
                   Image.LANCZOS)
    canvas = Image.new('RGB', (TARGET_W, TARGET_H), BG)
    canvas.paste(im, ((TARGET_W - im.width) // 2, (TARGET_H - im.height) // 2))
    name = os.path.splitext(os.path.basename(path))[0]
    out = os.path.join(dst_dir, f'{i:02d}_{name}.png')
    canvas.save(out)
    print(f'  {out}  {canvas.size[0]}x{canvas.size[1]}')
PYEOF

echo
echo "✓ Play screenshots in $PLAY_DIR"
ls -1 "$PLAY_DIR"
echo
echo "Next: ./scripts/play-preflight.sh"
