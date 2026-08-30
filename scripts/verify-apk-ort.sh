#!/bin/bash
# Assert the APK packages SHERPA's libonnxruntime.so version (not the ORT
# Java AAR's), plus the vendored Java JNI bridge. Wrong C-runtime version =
# sherpa's JNI (needs C-API v27) dies at runtime — see the dependencies
# comment in android/app/build.gradle.kts.
#
# Compares complete VERSION STRING SETS, not hashes: AGP rewrites native libs
# during packaging, so byte-comparison against the source .so is meaningless.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [release.apk]" >&2
  exit 2
fi
APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"
if [[ ! -f "$APK" || ! -r "$APK" || ! -s "$APK" ]]; then
  echo "FAIL: APK is missing, unreadable, or empty: $APK" >&2
  exit 1
fi

if ! LOCKED_VERSION="$(awk '
  $0 == "  sherpa_onnx_android_arm64:" {
    package_count++
    inside=1
    next
  }
  inside && /^  [^ ]/ { inside=0 }
  inside && /^    version:[[:space:]]*/ {
    version_count++
    value=$0
    sub(/^    version:[[:space:]]*/, "", value)
    if (value ~ /^".*"$/) value=substr(value, 2, length(value)-2)
  }
  END {
    if (package_count != 1 || version_count != 1 || value == "") exit 1
    print value
  }
' pubspec.lock)"; then
  echo "FAIL: pubspec.lock must contain exactly one sherpa_onnx_android_arm64 package and version" >&2
  exit 1
fi
case "$LOCKED_VERSION" in
  ''|*[!0-9A-Za-z.+-]*)
    echo "FAIL: locked sherpa_onnx_android_arm64 version is malformed: '$LOCKED_VERSION'" >&2
    exit 1
    ;;
esac

PUB_CACHE_ROOT="${PUB_CACHE:-$HOME/.pub-cache}"
SHERPA_PACKAGE="$PUB_CACHE_ROOT/hosted/pub.dev/sherpa_onnx_android_arm64-$LOCKED_VERSION"
SHERPA_SO="$SHERPA_PACKAGE/jniLibs/arm64-v8a/libonnxruntime.so"
if [[ ! -f "$SHERPA_SO" || ! -r "$SHERPA_SO" || ! -s "$SHERPA_SO" ]]; then
  echo "FAIL: locked sherpa $LOCKED_VERSION libonnxruntime.so not found at $SHERPA_SO" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-apk-ort.XXXXXX")"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

if ! unzip -tq "$APK" >/dev/null; then
  echo "FAIL: APK is not a valid ZIP archive: $APK" >&2
  exit 1
fi
if ! unzip -p "$APK" lib/arm64-v8a/libonnxruntime.so >"$TMP/packaged.so" 2>"$TMP/unzip.err"; then
  echo "FAIL: APK has no readable arm64 libonnxruntime.so" >&2
  cat "$TMP/unzip.err" >&2
  exit 1
fi
[[ -s "$TMP/packaged.so" ]] || { echo "FAIL: APK's arm64 libonnxruntime.so is empty" >&2; exit 1; }

collect_version_tags() {
  INPUT="$1"
  OUTPUT="$2"
  LABEL="$3"
  RAW="$TMP/$LABEL.strings"
  FILTERED="$TMP/$LABEL.filtered"
  if ! strings "$INPUT" >"$RAW"; then
    echo "FAIL: strings could not inspect $LABEL libonnxruntime.so" >&2
    exit 1
  fi
  if grep -E '^VERS_[0-9]+([.][0-9]+)*$' "$RAW" >"$FILTERED"; then
    :
  else
    STATUS=$?
    if [[ "$STATUS" -ne 1 ]]; then
      echo "FAIL: could not parse $LABEL version tags (grep status $STATUS)" >&2
      exit 1
    fi
    : >"$FILTERED"
  fi
  LC_ALL=C sort -u "$FILTERED" >"$OUTPUT"
  if [[ ! -s "$OUTPUT" ]]; then
    echo "FAIL: $LABEL libonnxruntime.so contains no VERS_ tags" >&2
    exit 1
  fi
}

collect_version_tags "$SHERPA_SO" "$TMP/want.tags" "locked-sherpa-$LOCKED_VERSION"
collect_version_tags "$TMP/packaged.so" "$TMP/got.tags" packaged

if ! cmp -s "$TMP/got.tags" "$TMP/want.tags"; then
  echo "FAIL: packaged libonnxruntime.so version-tag set differs from locked sherpa $LOCKED_VERSION" >&2
  if diff -u "$TMP/want.tags" "$TMP/got.tags" >&2; then
    :
  else
    DIFF_STATUS=$?
    if [[ "$DIFF_STATUS" -ne 1 ]]; then
      echo "FAIL: diff could not compare version-tag sets (status $DIFF_STATUS)" >&2
    fi
  fi
  exit 1
fi

if ! unzip -Z1 "$APK" >"$TMP/apk.entries" 2>"$TMP/list.err"; then
  echo "FAIL: could not enumerate APK entries" >&2
  cat "$TMP/list.err" >&2
  exit 1
fi
if ! grep -F -x 'lib/arm64-v8a/libonnxruntime4j_jni.so' "$TMP/apk.entries" >/dev/null; then
  echo "FAIL: libonnxruntime4j_jni.so (ORT Java bridge) missing from APK" >&2
  exit 1
fi

echo "OK: APK matches locked sherpa_onnx_android_arm64 $LOCKED_VERSION version tags:"
sed 's/^/  /' "$TMP/want.tags"
echo "OK: APK also contains the ORT Java JNI bridge"
