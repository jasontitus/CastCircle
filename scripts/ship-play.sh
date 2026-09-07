#!/usr/bin/env bash
#
# Ship CastCircle to Google Play. Mirrors scripts/ship-testflight.sh for iOS.
# See docs/RELEASING.md for the full recipe + first-upload caveat.
#
#   ./scripts/ship-play.sh             # build signed AAB + upload to the internal track
#   ./scripts/ship-play.sh --closed    # upload to CLOSED testing (alpha) as a draft release
#   ./scripts/ship-play.sh --closed --live   # ...and roll it out to testers immediately
#   ./scripts/ship-play.sh --validate  # dry run: Google validates the upload, nothing ships
#   ./scripts/ship-play.sh --build     # build the signed AAB only (no upload)
#
# Prereqs (set up once, both git-ignored / local-only):
#   - android/key.properties + android/app/castcircle-upload.jks  (release signing)
#   - ~/.google-play/play-store-key.json                          (Play service account, upload only)
#
# NOTE: the app must already exist in Play Console (the API can't create the
# listing). The first *upload* does NOT have to be manual, despite the older
# guidance saying so — build 150 went up through this script on 2026-08-14 as
# the app's first bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

# Which track, and whether the release goes live or waits in Play Console.
LANE=beta            # fastlane lane 'beta' = internal track
LANE_ARGS=""
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --closed)   LANE=closed_beta ;;
    --live)     LANE_ARGS="status:completed" ;;
    --validate) LANE_ARGS="${LANE_ARGS} validate:true" ;;
    --build)    BUILD_ONLY=1 ;;
    *) echo "✗ unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [[ "$LANE" == "beta" && -n "$LANE_ARGS" ]]; then
  echo "✗ --live/--validate only apply to --closed (the internal lane has no such options)." >&2
  exit 2
fi

# 1. Release signing must exist and be fully parseable. Gradle consumes these
#    same four Java-properties values; ambiguous or incomplete input is fatal.
KEY_PROPERTIES="android/key.properties"
if [[ ! -f "$KEY_PROPERTIES" ]]; then
  echo "✗ android/key.properties missing — release build would be debug-signed." >&2
  echo "  See docs/RELEASING.md → Android → Signing." >&2
  exit 1
fi

read_key_property() {
  awk -v wanted="$1" '
    /^[[:space:]]*[#!]/ { next }
    $0 ~ ("^[[:space:]]*" wanted "([[:space:]]|=|:)") {
      occurrences++
    }
    index($0, wanted "=") == 1 {
      canonical++
      value = substr($0, length(wanted) + 2)
    }
    END {
      if (occurrences != 1 || canonical != 1 || value == "") exit 1
      print value
    }
  ' "$KEY_PROPERTIES"
}

if ! STORE_FILE="$(read_key_property storeFile)"; then
  echo "✗ key.properties must contain exactly one nonempty storeFile= value." >&2
  exit 1
fi
if ! STORE_PASSWORD="$(read_key_property storePassword)"; then
  echo "✗ key.properties must contain exactly one nonempty storePassword= value." >&2
  exit 1
fi
if ! KEY_ALIAS="$(read_key_property keyAlias)"; then
  echo "✗ key.properties must contain exactly one nonempty keyAlias= value." >&2
  exit 1
fi
if ! KEY_PASSWORD="$(read_key_property keyPassword)"; then
  echo "✗ key.properties must contain exactly one nonempty keyPassword= value." >&2
  exit 1
fi
case "$STORE_FILE" in
  /*|..|../*|*/../*|*/..)
    echo "✗ storeFile must be a relative path inside android/app (got '$STORE_FILE')." >&2
    exit 1
    ;;
esac
KEYSTORE="android/app/$STORE_FILE"
[[ -f "$KEYSTORE" ]] || { echo "✗ configured upload keystore not found at $KEYSTORE" >&2; exit 1; }
echo "▶ Building signed release AAB..."
flutter build appbundle --release
AAB="build/app/outputs/bundle/release/app-release.aab"
[[ -f "$AAB" ]] || { echo "✗ AAB not produced at $AAB" >&2; exit 1; }

# Positively compare the bundle signer to the configured upload-key
# certificate. Fingerprints are hashes of DER certificates, so this does not
# depend on localized keytool labels such as "Owner" or "SHA256".
CERT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/castcircle-signing.XXXXXX")"
chmod 700 "$CERT_WORK"
trap 'rm -rf "$CERT_WORK"' EXIT

KT="keytool"
if JAVA_HOME_PATH="$(/usr/libexec/java_home 2>/dev/null)"; then
  if [[ -x "$JAVA_HOME_PATH/bin/keytool" ]]; then
    KT="$JAVA_HOME_PATH/bin/keytool"
  fi
fi
command -v "$KT" >/dev/null 2>&1 || { echo "✗ keytool is required to verify AAB signing." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "✗ openssl is required to verify AAB signing." >&2; exit 1; }

if ! CASTCIRCLE_STORE_PASSWORD="$STORE_PASSWORD" CASTCIRCLE_KEY_PASSWORD="$KEY_PASSWORD" \
  "$KT" -exportcert -keystore "$KEYSTORE" -alias "$KEY_ALIAS" \
    -storepass:env CASTCIRCLE_STORE_PASSWORD -keypass:env CASTCIRCLE_KEY_PASSWORD \
    >"$CERT_WORK/expected.der" 2>"$CERT_WORK/keystore.err"; then
  echo "✗ Could not export the configured upload certificate:" >&2
  cat "$CERT_WORK/keystore.err" >&2
  exit 1
fi
[[ -s "$CERT_WORK/expected.der" ]] || { echo "✗ Configured upload certificate is empty." >&2; exit 1; }
EXPECTED_FINGERPRINT="$(shasum -a 256 "$CERT_WORK/expected.der" | awk '{print $1}')"

if ! unzip -Z1 "$AAB" 'META-INF/*' >"$CERT_WORK/zip-entries" 2>"$CERT_WORK/unzip.err"; then
  echo "✗ Could not enumerate AAB signature entries:" >&2
  cat "$CERT_WORK/unzip.err" >&2
  exit 1
fi
if grep -E '^META-INF/[^/]+\.(RSA|DSA|EC)$' "$CERT_WORK/zip-entries" >"$CERT_WORK/signatures"; then
  :
else
  GREP_STATUS=$?
  if [[ "$GREP_STATUS" -ne 1 ]]; then
    echo "✗ Could not parse AAB signature entries (grep status $GREP_STATUS)." >&2
    exit 1
  fi
  : >"$CERT_WORK/signatures"
fi
SIG_COUNT="$(awk 'NF { count++ } END { print count+0 }' "$CERT_WORK/signatures")"
if [[ "$SIG_COUNT" -ne 1 ]]; then
  echo "✗ Expected exactly one AAB signature block, found $SIG_COUNT." >&2
  exit 1
fi
IFS= read -r SIG_ENTRY <"$CERT_WORK/signatures"

if ! unzip -p "$AAB" "$SIG_ENTRY" >"$CERT_WORK/signature-block" 2>"$CERT_WORK/unzip-signature.err"; then
  echo "✗ Could not extract AAB signature block $SIG_ENTRY:" >&2
  cat "$CERT_WORK/unzip-signature.err" >&2
  exit 1
fi
if ! "$KT" -printcert -rfc -file "$CERT_WORK/signature-block" \
    >"$CERT_WORK/signer.pem" 2>"$CERT_WORK/signer.err"; then
  echo "✗ Could not decode the AAB signer certificate:" >&2
  cat "$CERT_WORK/signer.err" >&2
  exit 1
fi
CERT_COUNT="$(awk '/^-----BEGIN CERTIFICATE-----$/ { count++ } END { print count+0 }' "$CERT_WORK/signer.pem")"
if [[ "$CERT_COUNT" -ne 1 ]]; then
  echo "✗ Expected exactly one signer certificate, decoded $CERT_COUNT." >&2
  exit 1
fi
if ! openssl x509 -in "$CERT_WORK/signer.pem" -outform DER \
    >"$CERT_WORK/signer.der" 2>"$CERT_WORK/openssl.err"; then
  echo "✗ Could not normalize the AAB signer certificate:" >&2
  cat "$CERT_WORK/openssl.err" >&2
  exit 1
fi
[[ -s "$CERT_WORK/signer.der" ]] || { echo "✗ AAB signer certificate is empty." >&2; exit 1; }
ACTUAL_FINGERPRINT="$(shasum -a 256 "$CERT_WORK/signer.der" | awk '{print $1}')"
if [[ "$ACTUAL_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]]; then
  echo "✗ AAB signer does not match the configured upload key." >&2
  echo "  expected SHA-256: $EXPECTED_FINGERPRINT" >&2
  echo "  actual   SHA-256: $ACTUAL_FINGERPRINT" >&2
  exit 1
fi
echo "✓ AAB built ($(du -h "$AAB" | cut -f1)), upload-key SHA-256: $ACTUAL_FINGERPRINT"

# 3. Everything Play will reject us for, checked here in seconds instead of
#    days later in review (metadata limits, release notes for THIS build,
#    store graphics, screenshot aspect ratios, signing). This runs AFTER the
#    build: preflight's staleness check compares the AAB against the source
#    tree, so running it first always judged the PREVIOUS build.
echo "▶ Preflight..."
if ! ./scripts/play-preflight.sh; then
  echo "✗ Preflight failed — not uploading." >&2
  exit 1
fi

if (( BUILD_ONLY )); then
  echo "▶ --build: skipping upload. AAB at $AAB"
  exit 0
fi

# 2. Upload needs the Play service account.
if [[ ! -f "$HOME/.google-play/play-store-key.json" ]]; then
  echo "✗ ~/.google-play/play-store-key.json missing — can't upload via fastlane." >&2
  echo "  Either add it, or upload $AAB manually in Play Console (required for the FIRST upload)." >&2
  exit 1
fi

if [[ "$LANE" == "closed_beta" ]]; then
  echo "▶ Uploading to Play CLOSED testing (alpha) via fastlane... ${LANE_ARGS:-(draft release)}"
else
  echo "▶ Uploading to Play internal track via fastlane..."
fi
# shellcheck disable=SC2086  # LANE_ARGS is intentionally word-split into fastlane options
( cd fastlane && fastlane android "$LANE" $LANE_ARGS )
echo "✓ shipped to Play ($LANE)"
