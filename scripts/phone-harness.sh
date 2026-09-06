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
set -euo pipefail
cd "$(dirname "$0")/.."

TEST="${1:-integration_test/android_rehearsal_harness_test.dart}"
PKG=com.tiltastech.castcircle
EVAL=.asr-eval
KOKORO_PACK=kokoro-en-fp16-v1_0
KOKORO_ID=4cafe1c49bf4b0a7f9c2fab9f2b010b05544dde2b28b66e3211e832308a1a1f9

require_file_size() {
  FILE=$1
  EXPECTED_SIZE=$2
  [ -f "$FILE" ] \
    || { echo "ERROR: $FILE missing — incomplete model pack" >&2; exit 1; }
  ACTUAL_SIZE=$(wc -c <"$FILE" | tr -d '[:space:]')
  [ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ] \
    || { echo "ERROR: $FILE is $ACTUAL_SIZE bytes, expected $EXPECTED_SIZE" >&2; exit 1; }
}

# ── Device selection: $DEVICE, else the only connected device ──
if [ -z "${DEVICE:-}" ]; then
  if ! DEVICES=$(adb devices | awk 'NR>1 && $2=="device" {print $1}'); then
    echo "ERROR: failed to list connected devices" >&2
    exit 1
  fi
  COUNT=$(echo "$DEVICES" | grep -c . || true)
  if [ "$COUNT" -eq 0 ]; then echo "ERROR: no device connected"; exit 1; fi
  if [ "$COUNT" -gt 1 ]; then
    echo "ERROR: multiple devices, set DEVICE=<id>:"; echo "$DEVICES"; exit 1
  fi
  DEVICE=$DEVICES
fi
ADB=(adb -s "$DEVICE")
OUT=$(mktemp "${TMPDIR:-/tmp}/phone-harness.XXXXXX") \
  || { echo "ERROR: could not create harness log" >&2; exit 1; }
echo "device: $DEVICE  test: $TEST  log: $OUT"

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/phone-harness-stage.XXXXXX") \
  || { echo "ERROR: could not create secure staging directory" >&2; rm -f "$OUT"; exit 1; }
TESTPID=""
POWER_STAYON_SET=0
cleanup() {
  STATUS=$?
  trap - EXIT INT TERM
  if [ -n "$TESTPID" ] && kill -0 "$TESTPID" 2>/dev/null; then
    kill "$TESTPID" 2>/dev/null || true
    wait "$TESTPID" 2>/dev/null || true
  fi
  if [ "$POWER_STAYON_SET" -eq 1 ]; then
    "${ADB[@]}" shell svc power stayon false >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGING_DIR" || true
  exit "$STATUS"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── Prereqs: model packs staged locally ──
for d in "$EVAL/$KOKORO_PACK" "$EVAL/kroko"; do
  [ -d "$d" ] || { echo "ERROR: $d missing — stage packs first (see docs/ANDROID_LIVE_MATCHING.md)"; exit 1; }
done
[ -d "$EVAL/$KOKORO_PACK/espeak-ng-data" ] \
  || { echo "ERROR: $EVAL/$KOKORO_PACK/espeak-ng-data missing — incomplete model pack" >&2; exit 1; }
require_file_size "$EVAL/$KOKORO_PACK/model.fp16.onnx" 163493590
require_file_size "$EVAL/$KOKORO_PACK/voices.bin" 27678720
require_file_size "$EVAL/$KOKORO_PACK/tokens.txt" 687
require_file_size "$EVAL/$KOKORO_PACK/lexicon-us-en.txt" 5956885
require_file_size "$EVAL/$KOKORO_PACK/lexicon-gb-en.txt" 6366635
require_file_size "$EVAL/$KOKORO_PACK/espeak-ng-data/phonindex" 39074

# ── Replace staged packs on the device ──
"${ADB[@]}" shell rm -rf "/data/local/tmp/$KOKORO_PACK" \
  || { echo "ERROR: could not clear old kokoro pack"; exit 1; }
"${ADB[@]}" push --sync "$EVAL/$KOKORO_PACK" /data/local/tmp/ >/dev/null \
  || { echo "ERROR: kokoro pack push failed"; exit 1; }

KROKO_STAGE="$STAGING_DIR/kroko-min"
mkdir -p "$KROKO_STAGE" \
  || { echo "ERROR: could not create local kroko staging directory"; exit 1; }
for f in encoder.onnx decoder.onnx joiner.onnx tokens.txt; do
  [ -f "$EVAL/kroko/$f" ] || { echo "ERROR: $EVAL/kroko/$f missing — incomplete model pack"; exit 1; }
  cp "$EVAL/kroko/$f" "$KROKO_STAGE/" \
    || { echo "ERROR: failed to stage $EVAL/kroko/$f"; exit 1; }
done
"${ADB[@]}" shell rm -rf /data/local/tmp/kroko-min \
  || { echo "ERROR: could not clear old kroko pack"; exit 1; }
"${ADB[@]}" push --sync "$KROKO_STAGE" /data/local/tmp/ >/dev/null \
  || { echo "ERROR: kroko pack push failed"; exit 1; }
echo "packs staged on device"

if "${ADB[@]}" shell svc power stayon true >/dev/null; then
  POWER_STAYON_SET=1
else
  echo "WARNING: could not keep the device screen awake" >&2
fi
UNINSTALL_OUTPUT=""
if ! UNINSTALL_OUTPUT=$("${ADB[@]}" uninstall "$PKG" 2>&1); then
  echo "WARNING: uninstall command failed; confirming package absence" >&2
  printf '%s\n' "$UNINSTALL_OUTPUT" >&2
fi
if ! PACKAGE_OUTPUT=$("${ADB[@]}" shell pm list packages 2>&1); then
  echo "ERROR: could not confirm package absence before Flutter install" >&2
  printf '%s\n' "$PACKAGE_OUTPUT" >&2
  exit 1
fi
if grep -Fx "package:$PKG" <<<"$PACKAGE_OUTPUT" >/dev/null; then
  echo "ERROR: $PKG is still installed after uninstall attempt" >&2
  printf '%s\n' "$UNINSTALL_OUTPUT" >&2
  exit 1
fi

# ── Launch the test; provision the app as soon as the install lands ──
flutter test "$TEST" -d "$DEVICE" >"$OUT" 2>&1 &
TESTPID=$!
PACKAGE_READY=0
PACKS_READY=0
TEMP_KOKORO=app_flutter/models/.kpack-tmp
TEMP_LIVE_ASR=app_flutter/models/.live-asr-tmp
KOKORO_CONTENT_CHECK="test -d $TEMP_KOKORO/espeak-ng-data && test \"\$(wc -c < $TEMP_KOKORO/model.fp16.onnx)\" -eq 163493590 && test \"\$(wc -c < $TEMP_KOKORO/voices.bin)\" -eq 27678720 && test \"\$(wc -c < $TEMP_KOKORO/tokens.txt)\" -eq 687 && test \"\$(wc -c < $TEMP_KOKORO/lexicon-us-en.txt)\" -eq 5956885 && test \"\$(wc -c < $TEMP_KOKORO/lexicon-gb-en.txt)\" -eq 6366635 && test \"\$(wc -c < $TEMP_KOKORO/espeak-ng-data/phonindex)\" -eq 39074"
LIVE_ASR_CHECK="test -f $TEMP_LIVE_ASR/encoder.onnx && test -f $TEMP_LIVE_ASR/decoder.onnx && test -f $TEMP_LIVE_ASR/joiner.onnx && test -f $TEMP_LIVE_ASR/tokens.txt"
FINAL_KOKORO_CHECK=${KOKORO_CONTENT_CHECK//"$TEMP_KOKORO"/"app_flutter/models/$KOKORO_PACK"}
FINAL_LIVE_ASR_CHECK=${LIVE_ASR_CHECK//"$TEMP_LIVE_ASR"/app_flutter/models/live_asr}
for i in $(seq 1 120); do
  if PACKAGE_OUTPUT=$("${ADB[@]}" shell pm list packages 2>/dev/null) \
    && grep -Fx "package:$PKG" <<<"$PACKAGE_OUTPUT" >/dev/null; then
    PACKAGE_READY=1
    sleep 2
    if ! "${ADB[@]}" shell pm grant "$PKG" android.permission.RECORD_AUDIO; then
      echo "ERROR: failed to grant RECORD_AUDIO to $PKG" >&2
      exit 1
    fi
    "${ADB[@]}" shell cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
    "${ADB[@]}" shell media volume --stream 3 --set 13 >/dev/null 2>&1 || true

    # Build and validate both model directories under temporary names. Only a
    # complete pack receives the pinned archive identity marker and replaces
    # the deterministic destination.
    for attempt in 1 2 3; do
      if "${ADB[@]}" shell run-as "$PKG" sh -c \
        "'mkdir -p app_flutter/models && rm -rf $TEMP_KOKORO $TEMP_LIVE_ASR && cp -r /data/local/tmp/$KOKORO_PACK $TEMP_KOKORO && rm -f $TEMP_KOKORO/.castcircle-ready && cp -r /data/local/tmp/kroko-min $TEMP_LIVE_ASR && $KOKORO_CONTENT_CHECK && $LIVE_ASR_CHECK && printf %s $KOKORO_ID > $TEMP_KOKORO/.castcircle-ready && test \"\$(cat $TEMP_KOKORO/.castcircle-ready)\" = \"$KOKORO_ID\" && rm -rf app_flutter/models/$KOKORO_PACK app_flutter/models/live_asr && mv $TEMP_KOKORO app_flutter/models/$KOKORO_PACK && mv $TEMP_LIVE_ASR app_flutter/models/live_asr'"; then
        if "${ADB[@]}" shell run-as "$PKG" sh -c \
          "'$FINAL_KOKORO_CHECK && test \"\$(cat app_flutter/models/$KOKORO_PACK/.castcircle-ready)\" = \"$KOKORO_ID\" && $FINAL_LIVE_ASR_CHECK'" >/dev/null 2>&1; then
          PACKS_READY=1
          echo "provisioned (mic, packs) at t=$((i*3))s (attempt $attempt)"
          break
        fi
      fi
      sleep 3
    done
    if [ "$PACKS_READY" -ne 1 ]; then
      echo "ERROR: model provisioning failed after 3 attempts" >&2
      exit 1
    fi
    break
  fi
  sleep 3
done

if [ "$PACKAGE_READY" -ne 1 ]; then
  echo "ERROR: $PKG was not installed within the provisioning timeout" >&2
  exit 1
fi

if wait "$TESTPID"; then
  STATUS=0
else
  STATUS=$?
fi
TESTPID=""
echo "── PROBE metrics ──"
grep -E "PROBE:" "$OUT" || echo "(none — see $OUT)"
grep -E "All tests passed|Some tests failed" "$OUT" || true
exit "$STATUS"
