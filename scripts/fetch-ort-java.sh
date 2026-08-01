#!/bin/bash
# Re-vendor the ONNX Runtime Java bindings for PaddleOcrPlugin.kt.
# See the dependencies comment in android/app/build.gradle.kts for WHY the
# Maven AAR can't be used directly (libonnxruntime.so collision with sherpa).
#
# Usage: ./scripts/fetch-ort-java.sh [version]   (default 1.22.0)
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:-1.22.0}
URL="https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/$V/onnxruntime-android-$V.aar"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "▶ fetching $URL"
curl -sfL -o "$TMP/ort.aar" "$URL"
shasum -a 256 "$TMP/ort.aar"
(cd "$TMP" && unzip -q ort.aar)
cp "$TMP/classes.jar" "android/app/libs/onnxruntime-java-$V.jar"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  mkdir -p "android/app/src/main/jniLibs/$abi"
  cp "$TMP/jni/$abi/libonnxruntime4j_jni.so" "android/app/src/main/jniLibs/$abi/"
  # Strip the bridge's versioned symbol bindings (@VERS_x.y.z): sherpa's
  # libonnxruntime.so exports the C API under ITS version tag, and a
  # version-bound reference from a different ORT release fails dlopen with
  # "cannot locate symbol OrtGetApiBase". Unversioned references bind to the
  # default export regardless of version.
  for sym in OrtGetApiBase OrtSessionOptionsAppendExecutionProvider_CPU \
             OrtSessionOptionsAppendExecutionProvider_Nnapi; do
    patchelf --clear-symbol-version "$sym" "android/app/src/main/jniLibs/$abi/libonnxruntime4j_jni.so"
  done
done
echo "▶ vendored:"
shasum -a 256 "android/app/libs/onnxruntime-java-$V.jar" android/app/src/main/jniLibs/*/libonnxruntime4j_jni.so
echo "Remember to update the jar filename in android/app/build.gradle.kts if the version changed."
