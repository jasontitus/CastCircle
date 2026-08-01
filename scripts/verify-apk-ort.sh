#!/bin/bash
# Assert the APK packages SHERPA's libonnxruntime.so version (not the ORT
# Java AAR's), plus the vendored Java JNI bridge. Wrong C-runtime version =
# sherpa's JNI (needs C-API v27) dies at runtime — see the dependencies
# comment in android/app/build.gradle.kts.
#
# Compares VERSION STRINGS, not hashes: AGP rewrites native libs during
# packaging, so byte-comparison against the source .so is meaningless.
set -euo pipefail
cd "$(dirname "$0")/.."
APK=${1:-build/app/outputs/flutter-apk/app-release.apk}
SHERPA_SO=$(find ~/.pub-cache/hosted/pub.dev -path "*sherpa_onnx_android_arm64*/jniLibs/arm64-v8a/libonnxruntime.so" | head -1)
[ -n "$SHERPA_SO" ] || { echo "FAIL: sherpa libonnxruntime.so not found in pub-cache"; exit 1; }
WANT=$(strings "$SHERPA_SO" | grep -E "^VERS_[0-9.]+$" | head -1)
GOT=$(unzip -p "$APK" lib/arm64-v8a/libonnxruntime.so | strings | grep -E "^VERS_[0-9.]+$" | head -1)
if [ "$GOT" != "$WANT" ]; then
  echo "FAIL: packaged libonnxruntime.so is $GOT, want sherpa's $WANT"
  exit 1
fi
# grep WITHOUT -q: under pipefail, -q's early exit SIGPIPEs unzip and fails
# the pipeline even on a match.
unzip -l "$APK" | grep "lib/arm64-v8a/libonnxruntime4j_jni.so" > /dev/null \
  || { echo "FAIL: libonnxruntime4j_jni.so (ORT Java bridge) missing from APK"; exit 1; }
echo "OK: APK packages sherpa's libonnxruntime.so ($WANT) + the ORT Java bridge"
