#!/bin/bash
# Re-vendor the ONNX Runtime Java bindings for PaddleOcrPlugin.kt.
# See the dependencies comment in android/app/build.gradle.kts for WHY the
# Maven AAR can't be used directly (libonnxruntime.so collision with sherpa).
#
# Usage: ./scripts/fetch-ort-java.sh [version]   (default 1.22.0)
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:-1.22.0}
case "$V" in
  1.22.0)
    EXPECTED_SHA="04a4617a9c797cf49225595e45b5546081cb34c86ac817581141577d3b7dbfe2"
    ;;
  *)
    echo "✗ no pinned SHA-256 for onnxruntime-android-$V.aar" >&2
    echo "  Add a reviewed digest to scripts/fetch-ort-java.sh before vendoring it." >&2
    exit 1
    ;;
esac

for tool in curl shasum unzip patchelf; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "✗ required tool not found: $tool" >&2; exit 1; }
done

URL="https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/$V/onnxruntime-android-$V.aar"
TMP=$(mktemp -d)
PENDING_FILES=()
cleanup() {
  rm -rf "$TMP"
  for file in "${PENDING_FILES[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

echo "▶ fetching $URL"
curl -sfL -o "$TMP/ort.aar" "$URL"
ACTUAL_SHA=$(shasum -a 256 "$TMP/ort.aar" | awk '{print $1}')
echo "sha256: $ACTUAL_SHA"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "✗ SHA-256 mismatch for onnxruntime-android-$V.aar" >&2
  echo "  expected $EXPECTED_SHA" >&2
  echo "  actual   $ACTUAL_SHA" >&2
  exit 1
fi
echo "✓ sha256 matches pin"

unzip -q "$TMP/ort.aar" -d "$TMP/unpacked"
[ -f "$TMP/unpacked/classes.jar" ] \
  || { echo "✗ AAR is missing classes.jar" >&2; exit 1; }

mkdir -p "$TMP/out/jni"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  SOURCE="$TMP/unpacked/jni/$abi/libonnxruntime4j_jni.so"
  [ -f "$SOURCE" ] \
    || { echo "✗ AAR is missing jni/$abi/libonnxruntime4j_jni.so" >&2; exit 1; }
  mkdir -p "$TMP/out/jni/$abi"
  cp "$SOURCE" "$TMP/out/jni/$abi/libonnxruntime4j_jni.so"
  # Strip the bridge's versioned symbol bindings (@VERS_x.y.z): sherpa's
  # libonnxruntime.so exports the C API under ITS version tag, and a
  # version-bound reference from a different ORT release fails dlopen with
  # "cannot locate symbol OrtGetApiBase". Unversioned references bind to the
  # default export regardless of version.
  for sym in OrtGetApiBase OrtSessionOptionsAppendExecutionProvider_CPU \
             OrtSessionOptionsAppendExecutionProvider_Nnapi; do
    patchelf --clear-symbol-version "$sym" "$TMP/out/jni/$abi/libonnxruntime4j_jni.so"
  done
done

# Prepare every destination before replacing any existing artifact. The final
# renames are atomic, and missing tools/layout cannot leave a partial update.
JAR_DEST="android/app/libs/onnxruntime-java-$V.jar"
mkdir -p "android/app/libs"
JAR_PENDING="$JAR_DEST.tmp.$$"
PENDING_FILES+=("$JAR_PENDING")
cp "$TMP/unpacked/classes.jar" "$JAR_PENDING"

for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  DEST_DIR="android/app/src/main/jniLibs/$abi"
  mkdir -p "$DEST_DIR"
  PENDING="$DEST_DIR/libonnxruntime4j_jni.so.tmp.$$"
  PENDING_FILES+=("$PENDING")
  cp "$TMP/out/jni/$abi/libonnxruntime4j_jni.so" "$PENDING"
done

mv "$JAR_PENDING" "$JAR_DEST"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  DEST_DIR="android/app/src/main/jniLibs/$abi"
  mv "$DEST_DIR/libonnxruntime4j_jni.so.tmp.$$" "$DEST_DIR/libonnxruntime4j_jni.so"
done

echo "▶ vendored:"
shasum -a 256 "$JAR_DEST" \
  android/app/src/main/jniLibs/arm64-v8a/libonnxruntime4j_jni.so \
  android/app/src/main/jniLibs/armeabi-v7a/libonnxruntime4j_jni.so \
  android/app/src/main/jniLibs/x86/libonnxruntime4j_jni.so \
  android/app/src/main/jniLibs/x86_64/libonnxruntime4j_jni.so
echo "Remember to update the jar filename in android/app/build.gradle.kts if the version changed."
