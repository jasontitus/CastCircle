#!/usr/bin/env bash
# Autonomous Android test driver: runs an integration test on a device or
# emulator with everything the tests need — model packs sideloaded via
# run-as, RECORD_AUDIO granted, media volume up, screen kept on — and prints
# the PROBE metric lines. No human interaction required.
#
#   scripts/phone-harness.sh [integration_test/<file>.dart]
#   DEVICE=emulator-5554 scripts/phone-harness.sh
#
# Default test: the full rehearsal-loop harness. The app is uninstalled first
# (flutter test's install replaces it and wipes data anyway); reinstall a
# release build afterwards if the device is a daily driver.
set -uo pipefail
cd "$(dirname "$0")/.."

TEST="${1:-integration_test/android_rehearsal_harness_test.dart}"
PKG=com.tiltastech.castcircle
EVAL=.asr-eval
OUT="${TMPDIR:-/tmp}/phone-harness-$(date +%s).log"

# ── Device selection: $DEVICE, else the only connected device ──
if [ -z "${DEVICE:-}" ]; then
  DEVICES=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  COUNT=$(echo "$DEVICES" | grep -c . || true)
  if [ "$COUNT" -eq 0 ]; then echo "ERROR: no device connected"; exit 1; fi
  if [ "$COUNT" -gt 1 ]; then
    echo "ERROR: multiple devices, set DEVICE=<id>:"; echo "$DEVICES"; exit 1
  fi
  DEVICE=$DEVICES
fi
ADB="adb -s $DEVICE"
echo "device: $DEVICE  test: $TEST  log: $OUT"

# ── Prereqs: model packs staged locally ──
for d in "$EVAL/kokoro-en-fp16-v1_0" "$EVAL/kroko"; do
  [ -d "$d" ] || { echo "ERROR: $d missing — stage packs first (see docs/ANDROID_LIVE_MATCHING.md)"; exit 1; }
done

# ── Stage packs on the device once (--sync makes re-runs cheap) ──
$ADB push --sync "$EVAL/kokoro-en-fp16-v1_0" /data/local/tmp/kpack >/dev/null
mkdir -p /tmp/kroko-min
for f in encoder.onnx decoder.onnx joiner.onnx tokens.txt; do
  cp "$EVAL/kroko/$f" /tmp/kroko-min/
done
# Push to the parent so re-runs don't nest a copy inside an existing dir.
$ADB push --sync /tmp/kroko-min /data/local/tmp/ >/dev/null
echo "packs staged on device"

$ADB shell svc power stayon true
$ADB uninstall $PKG >/dev/null 2>&1 || true

# ── Launch the test; provision the app as soon as the install lands ──
( flutter test "$TEST" -d "$DEVICE" >"$OUT" 2>&1 ) &
TESTPID=$!
for i in $(seq 1 120); do
  if $ADB shell pm list packages 2>/dev/null | grep -q $PKG; then
    sleep 2
    $ADB shell pm grant $PKG android.permission.RECORD_AUDIO 2>/dev/null
    $ADB shell cmd appops set $PKG RUN_ANY_IN_BACKGROUND allow 2>/dev/null
    $ADB shell media volume --stream 3 --set 13 2>/dev/null
    # Nested quotes: adb shell strips one layer before the device sh sees it.
    $ADB shell run-as $PKG sh -c "'mkdir -p app_flutter/models/live_asr && cp -r /data/local/tmp/kpack app_flutter/models/kokoro-en-fp16-v1_0 && cp /data/local/tmp/kroko-min/* app_flutter/models/live_asr/'" \
      && echo "provisioned (mic, volume, packs) at t=$((i*3))s"
    break
  fi
  sleep 3
done

wait $TESTPID
STATUS=$?
echo "── PROBE metrics ──"
grep -E "PROBE:" "$OUT" || echo "(none — see $OUT)"
grep -E "All tests passed|Some tests failed" "$OUT"
exit $STATUS
