#!/bin/bash
# Re-vendor the ONNX Runtime Java bindings for PaddleOcrPlugin.kt.
# See the dependencies comment in android/app/build.gradle.kts for WHY the
# Maven AAR can't be used directly (libonnxruntime.so collision with sherpa).
#
# Usage: ./scripts/fetch-ort-java.sh [version]   (default 1.22.0)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [pinned-version]" >&2
  exit 2
fi
V="${1:-1.22.0}"
if ! printf '%s\n' "$V" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null; then
  echo "✗ ORT version must be numeric major.minor.patch (got '$V')." >&2
  exit 2
fi

case "$V" in
  1.22.0) EXPECTED_SHA="04a4617a9c797cf49225595e45b5546081cb34c86ac817581141577d3b7dbfe2" ;;
  *)
    echo "✗ onnxruntime-android $V is not accepted because it has no reviewed SHA-256 pin." >&2
    echo "  Add its reviewed Maven artifact hash to the allowlist before vendoring it." >&2
    exit 1
    ;;
esac

URL="https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/$V/onnxruntime-android-$V.aar"
TMP="$(mktemp -d "android/app/.fetch-ort-java.XXXXXX")"
chmod 700 "$TMP"
COMMITTED=0
ROLLBACK_FAILED=0

restore_destination() {
  DESTINATION="$1"
  KEY="$2"
  if [[ -e "$TMP/backup/$KEY" || -L "$TMP/backup/$KEY" ]]; then
    if ! rm -f "$DESTINATION"; then
      echo "ERROR: rollback could not remove replacement $DESTINATION" >&2
      ROLLBACK_FAILED=1
      return
    fi
    if ! mv "$TMP/backup/$KEY" "$DESTINATION"; then
      echo "ERROR: rollback could not restore $DESTINATION" >&2
      ROLLBACK_FAILED=1
    fi
  elif [[ -f "$TMP/absent/$KEY" ]]; then
    if ! rm -f "$DESTINATION"; then
      echo "ERROR: rollback could not remove newly-created $DESTINATION" >&2
      ROLLBACK_FAILED=1
    fi
  fi
}

cleanup() {
  STATUS=$?
  trap - EXIT INT TERM
  if [[ "$COMMITTED" -ne 1 ]]; then
    restore_destination "android/app/libs/onnxruntime-java-$V.jar" classes.jar
    restore_destination "android/app/src/main/jniLibs/arm64-v8a/libonnxruntime4j_jni.so" arm64-v8a
    restore_destination "android/app/src/main/jniLibs/armeabi-v7a/libonnxruntime4j_jni.so" armeabi-v7a
    restore_destination "android/app/src/main/jniLibs/x86/libonnxruntime4j_jni.so" x86
    restore_destination "android/app/src/main/jniLibs/x86_64/libonnxruntime4j_jni.so" x86_64
  fi
  if ! rm -rf "$TMP"; then
    echo "ERROR: could not remove private staging directory $TMP" >&2
    ROLLBACK_FAILED=1
  fi
  if [[ "$STATUS" -eq 0 && "$ROLLBACK_FAILED" -ne 0 ]]; then
    STATUS=1
  fi
  exit "$STATUS"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v curl >/dev/null 2>&1 || { echo "✗ curl is required." >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "✗ unzip is required." >&2; exit 1; }
command -v patchelf >/dev/null 2>&1 || { echo "✗ patchelf is required." >&2; exit 1; }

mkdir -p "$TMP/extracted" "$TMP/stage/libs" "$TMP/stage/jni" "$TMP/backup" "$TMP/absent"
echo "▶ fetching $URL"
if ! curl -fL --proto '=https' --tlsv1.2 -o "$TMP/ort.aar" "$URL"; then
  echo "✗ failed to download onnxruntime-android-$V.aar" >&2
  exit 1
fi
[[ -s "$TMP/ort.aar" ]] || { echo "✗ downloaded AAR is empty." >&2; exit 1; }
ACTUAL_SHA="$(shasum -a 256 "$TMP/ort.aar" | awk '{print $1}')"
echo "sha256: $ACTUAL_SHA"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "✗ SHA-256 mismatch for onnxruntime-android-$V.aar" >&2
  echo "  expected $EXPECTED_SHA" >&2
  echo "  actual   $ACTUAL_SHA" >&2
  exit 1
fi
echo "✓ sha256 matches reviewed pin"

if ! unzip -tq "$TMP/ort.aar" >/dev/null; then
  echo "✗ pinned AAR failed ZIP integrity verification." >&2
  exit 1
fi
if ! unzip -q "$TMP/ort.aar" -d "$TMP/extracted"; then
  echo "✗ could not extract the verified AAR." >&2
  exit 1
fi
[[ -s "$TMP/extracted/classes.jar" ]] || { echo "✗ verified AAR has no nonempty classes.jar." >&2; exit 1; }
if ! unzip -tq "$TMP/extracted/classes.jar" >/dev/null; then
  echo "✗ classes.jar failed ZIP integrity verification." >&2
  exit 1
fi
cp "$TMP/extracted/classes.jar" "$TMP/stage/libs/onnxruntime-java-$V.jar"

for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  SOURCE_SO="$TMP/extracted/jni/$abi/libonnxruntime4j_jni.so"
  STAGED_DIR="$TMP/stage/jni/$abi"
  [[ -s "$SOURCE_SO" ]] || { echo "✗ verified AAR is missing nonempty $abi/libonnxruntime4j_jni.so." >&2; exit 1; }
  mkdir -p "$STAGED_DIR"
  cp "$SOURCE_SO" "$STAGED_DIR/libonnxruntime4j_jni.so"
  for sym in OrtGetApiBase OrtSessionOptionsAppendExecutionProvider_CPU \
             OrtSessionOptionsAppendExecutionProvider_Nnapi; do
    if ! patchelf --clear-symbol-version "$sym" "$STAGED_DIR/libonnxruntime4j_jni.so"; then
      echo "✗ patchelf failed for $abi symbol $sym; existing vendored files are unchanged." >&2
      exit 1
    fi
  done
  [[ -s "$STAGED_DIR/libonnxruntime4j_jni.so" ]] || { echo "✗ staged $abi bridge became empty." >&2; exit 1; }
done

backup_destination() {
  DESTINATION="$1"
  KEY="$2"
  mkdir -p "$(dirname "$DESTINATION")"
  if [[ -L "$DESTINATION" || ( -e "$DESTINATION" && ! -f "$DESTINATION" ) ]]; then
    echo "✗ refusing to replace unexpected non-regular destination $DESTINATION" >&2
    exit 1
  fi
  if [[ -f "$DESTINATION" ]]; then
    mv "$DESTINATION" "$TMP/backup/$KEY"
  else
    : >"$TMP/absent/$KEY"
  fi
}

backup_destination "android/app/libs/onnxruntime-java-$V.jar" classes.jar
backup_destination "android/app/src/main/jniLibs/arm64-v8a/libonnxruntime4j_jni.so" arm64-v8a
backup_destination "android/app/src/main/jniLibs/armeabi-v7a/libonnxruntime4j_jni.so" armeabi-v7a
backup_destination "android/app/src/main/jniLibs/x86/libonnxruntime4j_jni.so" x86
backup_destination "android/app/src/main/jniLibs/x86_64/libonnxruntime4j_jni.so" x86_64

mv "$TMP/stage/libs/onnxruntime-java-$V.jar" "android/app/libs/onnxruntime-java-$V.jar"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  mv "$TMP/stage/jni/$abi/libonnxruntime4j_jni.so" "android/app/src/main/jniLibs/$abi/libonnxruntime4j_jni.so"
done
COMMITTED=1

echo "▶ vendored verified artifacts:"
shasum -a 256 "android/app/libs/onnxruntime-java-$V.jar"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  shasum -a 256 "android/app/src/main/jniLibs/$abi/libonnxruntime4j_jni.so"
done
echo "Remember to update the jar filename in android/app/build.gradle.kts if the version changed."
