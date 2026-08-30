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
PKG="com.tiltastech.castcircle"
EVAL=".asr-eval"
INSTALL_TIMEOUT_SECONDS="${PHONE_HARNESS_INSTALL_TIMEOUT:-360}"
TEST_TIMEOUT_SECONDS="${PHONE_HARNESS_TEST_TIMEOUT:-1800}"
POLL_SECONDS="${PHONE_HARNESS_POLL_SECONDS:-3}"

validate_positive_decimal() {
  case "$2" in
    ''|*[!0-9]*)
      echo "ERROR: $1 must be a positive decimal (got '$2')" >&2
      exit 2
      ;;
  esac
  case "$2" in
    *[1-9]*) ;;
    *) echo "ERROR: $1 must be greater than zero" >&2; exit 2 ;;
  esac
}

validate_positive_decimal PHONE_HARNESS_INSTALL_TIMEOUT "$INSTALL_TIMEOUT_SECONDS"
validate_positive_decimal PHONE_HARNESS_TEST_TIMEOUT "$TEST_TIMEOUT_SECONDS"
validate_positive_decimal PHONE_HARNESS_POLL_SECONDS "$POLL_SECONDS"
normalize_decimal() {
  local value="$1"
  while [[ "${#value}" -gt 1 && "$value" == 0* ]]; do
    value="${value#0}"
  done
  printf '%s\n' "$value"
}
INSTALL_TIMEOUT_SECONDS="$(normalize_decimal "$INSTALL_TIMEOUT_SECONDS")"
TEST_TIMEOUT_SECONDS="$(normalize_decimal "$TEST_TIMEOUT_SECONDS")"
POLL_SECONDS="$(normalize_decimal "$POLL_SECONDS")"

if [[ -z "${DEVICE:-}" ]]; then
  if ! DEVICE_LIST="$(adb devices)"; then
    echo "ERROR: adb could not list devices" >&2
    exit 1
  fi
  DEVICES="$(printf '%s\n' "$DEVICE_LIST" | awk 'NR>1 && $2=="device" {print $1}')"
  COUNT="$(printf '%s\n' "$DEVICES" | awk 'NF {count++} END {print count+0}')"
  if [[ "$COUNT" -eq 0 ]]; then
    echo "ERROR: no device connected" >&2
    exit 1
  fi
  if [[ "$COUNT" -gt 1 ]]; then
    echo "ERROR: multiple devices, set DEVICE=<id>:" >&2
    printf '%s\n' "$DEVICES" >&2
    exit 1
  fi
  DEVICE="$DEVICES"
fi
ADB=(adb -s "$DEVICE")

for d in "$EVAL/kokoro-en-fp16-v1_0" "$EVAL/kroko"; do
  [[ -d "$d" ]] || { echo "ERROR: $d missing — stage packs first (see docs/ANDROID_LIVE_MATCHING.md)" >&2; exit 1; }
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/phone-harness.XXXXXX")"
chmod 700 "$WORKDIR"
OUT="$WORKDIR/test.log"
KROKO_MIN="$WORKDIR/kroko-min"
mkdir -p "$KROKO_MIN"

TESTPID=""
TEST_PGID=""
POWER_STATE_CAPTURED=0
ORIGINAL_STAY_ON=""

print_log_tail() {
  if [[ -f "$OUT" ]]; then
    echo "── test log tail ──" >&2
    tail -60 "$OUT" >&2
  fi
}

process_group_is_empty() {
  local pgid="$1"
  if kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  return 0
}

stop_test() {
  local group_empty=1
  local stop_deadline=0

  if [[ -n "$TEST_PGID" ]]; then
    if ! process_group_is_empty "$TEST_PGID"; then
      if ! kill -TERM -- "-$TEST_PGID" 2>/dev/null; then
        if ! process_group_is_empty "$TEST_PGID"; then
          echo "ERROR: could not send TERM to test process group $TEST_PGID" >&2
          CLEANUP_FAILED=1
        fi
      fi
      stop_deadline=$(( $(date +%s) + 10 ))
      while ! process_group_is_empty "$TEST_PGID" && [[ $(date +%s) -lt $stop_deadline ]]; do
        sleep 1
      done
      if ! process_group_is_empty "$TEST_PGID"; then
        echo "WARNING: test process group $TEST_PGID ignored TERM; sending KILL" >&2
        if ! kill -KILL -- "-$TEST_PGID" 2>/dev/null; then
          if ! process_group_is_empty "$TEST_PGID"; then
            echo "ERROR: could not send KILL to test process group $TEST_PGID" >&2
            CLEANUP_FAILED=1
          fi
        fi
        stop_deadline=$(( $(date +%s) + 5 ))
        while ! process_group_is_empty "$TEST_PGID" && [[ $(date +%s) -lt $stop_deadline ]]; do
          sleep 1
        done
      fi
    fi
    if process_group_is_empty "$TEST_PGID"; then
      group_empty=1
    else
      echo "ERROR: test process group $TEST_PGID is not empty after cleanup" >&2
      group_empty=0
      CLEANUP_FAILED=1
    fi
  elif [[ -n "$TESTPID" ]] && kill -0 "$TESTPID" 2>/dev/null; then
    # This path is reachable only if dedicated-group validation itself fails.
    if ! kill -TERM "$TESTPID" 2>/dev/null; then
      echo "ERROR: could not terminate ungrouped test process $TESTPID" >&2
      CLEANUP_FAILED=1
    fi
    stop_deadline=$(( $(date +%s) + 10 ))
    while kill -0 "$TESTPID" 2>/dev/null && [[ $(date +%s) -lt $stop_deadline ]]; do
      sleep 1
    done
    if kill -0 "$TESTPID" 2>/dev/null; then
      if ! kill -KILL "$TESTPID" 2>/dev/null; then
        echo "ERROR: could not kill ungrouped test process $TESTPID" >&2
        CLEANUP_FAILED=1
      fi
      stop_deadline=$(( $(date +%s) + 5 ))
      while kill -0 "$TESTPID" 2>/dev/null && [[ $(date +%s) -lt $stop_deadline ]]; do
        sleep 1
      done
    fi
    if kill -0 "$TESTPID" 2>/dev/null; then
      echo "ERROR: ungrouped test process $TESTPID is still running after cleanup" >&2
      group_empty=0
      CLEANUP_FAILED=1
    fi
  fi

  if [[ -n "$TESTPID" ]] && ! kill -0 "$TESTPID" 2>/dev/null; then
    if wait "$TESTPID" 2>/dev/null; then
      :
    else
      WAIT_STATUS=$?
      if [[ "$WAIT_STATUS" -ne 1 && "$WAIT_STATUS" -ne 143 && "$WAIT_STATUS" -ne 137 ]]; then
        echo "test process exited with status $WAIT_STATUS during cleanup" >&2
      fi
    fi
  fi
  if [[ "$group_empty" -eq 1 ]]; then
    TESTPID=""
    TEST_PGID=""
  fi
}

cleanup() {
  STATUS=$?
  trap - EXIT INT TERM
  CLEANUP_FAILED=0

  stop_test

  if [[ "$POWER_STATE_CAPTURED" -eq 1 ]]; then
    if [[ "$ORIGINAL_STAY_ON" == "null" ]]; then
      if ! "${ADB[@]}" shell settings delete global stay_on_while_plugged_in >/dev/null; then
        echo "ERROR: failed to restore absent device stay-awake setting" >&2
        CLEANUP_FAILED=1
      fi
    else
      if ! "${ADB[@]}" shell settings put global stay_on_while_plugged_in "$ORIGINAL_STAY_ON" >/dev/null; then
        echo "ERROR: failed to restore device stay-awake setting to $ORIGINAL_STAY_ON" >&2
        CLEANUP_FAILED=1
      fi
    fi

    if [[ "$CLEANUP_FAILED" -eq 0 ]]; then
      if RESTORED_STAY_ON="$("${ADB[@]}" shell settings get global stay_on_while_plugged_in | tr -d '\r\n')"; then
        if [[ "$RESTORED_STAY_ON" != "$ORIGINAL_STAY_ON" ]]; then
          echo "ERROR: device stay-awake restore verification failed (got '$RESTORED_STAY_ON', want '$ORIGINAL_STAY_ON')" >&2
          CLEANUP_FAILED=1
        fi
      else
        echo "ERROR: could not verify restored device stay-awake setting" >&2
        CLEANUP_FAILED=1
      fi
    fi
  fi

  if [[ "$STATUS" -ne 0 || "${KEEP_PHONE_HARNESS_LOG:-0}" == "1" ]]; then
    echo "test log retained at $OUT" >&2
  else
    if ! rm -rf "$WORKDIR"; then
      echo "ERROR: could not remove private harness directory $WORKDIR" >&2
      CLEANUP_FAILED=1
    fi
  fi

  if [[ "$STATUS" -eq 0 && "$CLEANUP_FAILED" -ne 0 ]]; then
    STATUS=1
  fi
  exit "$STATUS"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "device: $DEVICE  test: $TEST  log: $OUT"

if ! "${ADB[@]}" push --sync "$EVAL/kokoro-en-fp16-v1_0" /data/local/tmp/kpack >/dev/null; then
  echo "ERROR: kokoro pack push failed" >&2
  exit 1
fi
for f in encoder.onnx decoder.onnx joiner.onnx tokens.txt; do
  [[ -s "$EVAL/kroko/$f" ]] || { echo "ERROR: $EVAL/kroko/$f missing or empty — incomplete model pack" >&2; exit 1; }
  cp "$EVAL/kroko/$f" "$KROKO_MIN/"
done
if ! "${ADB[@]}" push --sync "$KROKO_MIN" /data/local/tmp/ >/dev/null; then
  echo "ERROR: kroko pack push failed" >&2
  exit 1
fi
echo "packs staged on device"

if ! ORIGINAL_STAY_ON="$("${ADB[@]}" shell settings get global stay_on_while_plugged_in | tr -d '\r\n')"; then
  echo "ERROR: could not read the device stay-awake setting" >&2
  exit 1
fi
case "$ORIGINAL_STAY_ON" in
  null) ;;
  ''|*[!0-9]*) echo "ERROR: unexpected stay_on_while_plugged_in value '$ORIGINAL_STAY_ON'" >&2; exit 1 ;;
esac
POWER_STATE_CAPTURED=1
if ! "${ADB[@]}" shell svc power stayon true; then
  echo "ERROR: failed to enable device stay-awake state" >&2
  exit 1
fi
if ! CURRENT_STAY_ON="$("${ADB[@]}" shell settings get global stay_on_while_plugged_in | tr -d '\r\n')"; then
  echo "ERROR: could not verify device stay-awake state" >&2
  exit 1
fi
case "$CURRENT_STAY_ON" in
  ''|*[!0-9]*) echo "ERROR: device did not enable stay-awake state (got '$CURRENT_STAY_ON')" >&2; exit 1 ;;
esac
if [[ "$CURRENT_STAY_ON" -eq 0 ]]; then
  echo "ERROR: device did not enable stay-awake state (got '$CURRENT_STAY_ON')" >&2
  exit 1
fi

if ! PACKAGE_LIST="$("${ADB[@]}" shell pm list packages 2>&1)"; then
  echo "ERROR: adb package probe failed before uninstall:" >&2
  printf '%s\n' "$PACKAGE_LIST" >&2
  exit 1
fi
if printf '%s\n' "$PACKAGE_LIST" | grep -F "package:$PKG" >/dev/null; then
  if ! "${ADB[@]}" uninstall "$PKG" >/dev/null; then
    echo "ERROR: failed to uninstall existing $PKG" >&2
    exit 1
  fi
fi

command -v ps >/dev/null 2>&1 || { echo "ERROR: ps is required to validate the test process group" >&2; exit 1; }
set -m
flutter test "$TEST" -d "$DEVICE" >"$OUT" 2>&1 &
TESTPID=$!
# With monitor mode enabled, Bash assigns a background job PGID equal to its
# leader PID. Retain that expected PGID before any fallible validation so the
# EXIT trap can still kill descendants if ps itself fails.
TEST_PGID="$TESTPID"
TEST_PGID_CANDIDATE=""
if ! TEST_PGID_CANDIDATE="$(ps -o pgid= -p "$TESTPID" | tr -d '[:space:]')"; then
  echo "ERROR: could not inspect flutter test process group" >&2
  exit 1
fi
case "$TEST_PGID_CANDIDATE" in
  ''|*[!0-9]*) echo "ERROR: ps returned invalid test process group '$TEST_PGID_CANDIDATE'" >&2; exit 1 ;;
esac
if [[ "$TEST_PGID_CANDIDATE" != "$TESTPID" ]]; then
  echo "ERROR: flutter test was not launched in a dedicated process group (pid $TESTPID, pgid $TEST_PGID_CANDIDATE)" >&2
  exit 1
fi
set +m
STARTED_AT=$(date +%s)
INSTALL_DEADLINE=$((STARTED_AT + INSTALL_TIMEOUT_SECONDS))
TEST_DEADLINE=$((STARTED_AT + TEST_TIMEOUT_SECONDS))
INSTALLED=0

while [[ $(date +%s) -lt $INSTALL_DEADLINE ]]; do
  if ! PACKAGE_LIST="$("${ADB[@]}" shell pm list packages 2>&1)"; then
    echo "ERROR: adb package probe failed while waiting for the test install:" >&2
    printf '%s\n' "$PACKAGE_LIST" >&2
    exit 1
  fi
  if printf '%s\n' "$PACKAGE_LIST" | grep -F "package:$PKG" >/dev/null; then
    INSTALLED=1
    break
  fi
  if ! kill -0 "$TESTPID" 2>/dev/null; then
    if wait "$TESTPID"; then
      EARLY_STATUS=0
    else
      EARLY_STATUS=$?
    fi
    TESTPID=""
    echo "ERROR: flutter test exited with status $EARLY_STATUS before installing $PKG" >&2
    print_log_tail
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

if [[ "$INSTALLED" -ne 1 ]]; then
  echo "ERROR: app was not installed within ${INSTALL_TIMEOUT_SECONDS}s" >&2
  print_log_tail
  exit 1
fi

sleep 2
if ! "${ADB[@]}" shell pm grant "$PKG" android.permission.RECORD_AUDIO; then
  echo "ERROR: failed to grant RECORD_AUDIO" >&2
  exit 1
fi
if ! PERMISSION_STATE="$("${ADB[@]}" shell dumpsys package "$PKG" 2>&1)"; then
  echo "ERROR: failed to verify RECORD_AUDIO grant" >&2
  exit 1
fi
if ! printf '%s\n' "$PERMISSION_STATE" | grep -F "android.permission.RECORD_AUDIO: granted=true" >/dev/null; then
  echo "ERROR: RECORD_AUDIO is not granted after pm grant" >&2
  exit 1
fi

if ! "${ADB[@]}" shell cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND allow; then
  echo "ERROR: failed to allow RUN_ANY_IN_BACKGROUND" >&2
  exit 1
fi
if ! APP_OP_STATE="$("${ADB[@]}" shell cmd appops get "$PKG" RUN_ANY_IN_BACKGROUND 2>&1)"; then
  echo "ERROR: failed to verify RUN_ANY_IN_BACKGROUND" >&2
  exit 1
fi
if ! printf '%s\n' "$APP_OP_STATE" | grep -E 'RUN_ANY_IN_BACKGROUND:[[:space:]]+allow' >/dev/null; then
  echo "ERROR: RUN_ANY_IN_BACKGROUND is not allowed after appops set" >&2
  exit 1
fi

if ! "${ADB[@]}" shell cmd media_session volume --stream 3 --set 13; then
  echo "ERROR: failed to set media volume" >&2
  exit 1
fi
if ! VOLUME_STATE="$("${ADB[@]}" shell cmd media_session volume --stream 3 --get 2>&1)"; then
  echo "ERROR: failed to verify media volume" >&2
  exit 1
fi
if ! printf '%s\n' "$VOLUME_STATE" | grep -E 'volume is 13([^0-9]|$)' >/dev/null; then
  echo "ERROR: media volume is not 13 after setting it: $VOLUME_STATE" >&2
  exit 1
fi

PROVISIONED=0
ATTEMPT=1
while [[ $ATTEMPT -le 3 ]]; do
  if "${ADB[@]}" shell run-as "$PKG" sh -c "'mkdir -p app_flutter/models/live_asr && rm -rf app_flutter/models/.kpack-tmp && cp -r /data/local/tmp/kpack app_flutter/models/.kpack-tmp && rm -rf app_flutter/models/kokoro-en-fp16-v1_0 && mv app_flutter/models/.kpack-tmp app_flutter/models/kokoro-en-fp16-v1_0 && cp /data/local/tmp/kroko-min/* app_flutter/models/live_asr/'"; then
    if "${ADB[@]}" shell run-as "$PKG" sh -c "'test -d app_flutter/models/kokoro-en-fp16-v1_0 && test -s app_flutter/models/live_asr/encoder.onnx && test -s app_flutter/models/live_asr/decoder.onnx && test -s app_flutter/models/live_asr/joiner.onnx && test -s app_flutter/models/live_asr/tokens.txt'"; then
      PROVISIONED=1
      break
    fi
    echo "provision attempt $ATTEMPT copied incomplete model files" >&2
  else
    COPY_STATUS=$?
    echo "provision attempt $ATTEMPT failed with status $COPY_STATUS" >&2
  fi
  ATTEMPT=$((ATTEMPT + 1))
  if [[ $ATTEMPT -le 3 ]]; then
    sleep "$POLL_SECONDS"
  fi
done

if [[ "$PROVISIONED" -ne 1 ]]; then
  echo "ERROR: model provisioning failed after 3 attempts" >&2
  print_log_tail
  exit 1
fi
ELAPSED=$(( $(date +%s) - STARTED_AT ))
echo "provisioned (mic, volume, packs) at t=${ELAPSED}s (attempt $ATTEMPT)"

while kill -0 "$TESTPID" 2>/dev/null; do
  if [[ $(date +%s) -ge $TEST_DEADLINE ]]; then
    echo "ERROR: flutter test exceeded ${TEST_TIMEOUT_SECONDS}s overall timeout" >&2
    print_log_tail
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

if wait "$TESTPID"; then
  STATUS=0
else
  STATUS=$?
fi
TESTPID=""

echo "── PROBE metrics ──"
if ! grep -E "PROBE:" "$OUT"; then
  echo "(none — see $OUT)"
fi
if ! grep -E "All tests passed|Some tests failed" "$OUT"; then
  echo "(no Flutter test summary — see $OUT)" >&2
fi
exit "$STATUS"
