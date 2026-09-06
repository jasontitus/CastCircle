#!/bin/bash
# Recreate per-file symlinks to the app's vendored MLX sources.
# SwiftPM does not follow directory symlinks, so each .swift file gets its own.
# Re-run after adding/removing files under ios/Runner/{Kokoro,Misaki}Vendored.
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mlx-harness-links.XXXXXX")
STAGE=$(mktemp -d "Sources/harness/.link-sources.XXXXXX")
cleanup() {
  rm -rf "$WORK" "$STAGE"
}
trap cleanup EXIT

# Validate and enumerate every source tree before touching existing links.
for vendor in KokoroVendored MisakiVendored; do
  SOURCE_DIR="$REPO_ROOT/ios/Runner/$vendor"
  [ -d "$SOURCE_DIR" ] && [ -r "$SOURCE_DIR" ] \
    || { echo "ERROR: vendor source directory is missing or unreadable: $SOURCE_DIR" >&2; exit 1; }
  if ! find "$SOURCE_DIR" -type f -name '*.swift' >"$WORK/$vendor.files"; then
    echo "ERROR: failed to enumerate Swift sources under $SOURCE_DIR" >&2
    exit 1
  fi
  [ -s "$WORK/$vendor.files" ] \
    || { echo "ERROR: no Swift sources found under $SOURCE_DIR" >&2; exit 1; }
done

# Build the complete replacement trees while the current links remain intact.
for vendor in KokoroVendored MisakiVendored; do
  mkdir -p "$STAGE/$vendor"
  while IFS= read -r f; do
    rel=${f#"$REPO_ROOT/ios/Runner/"}
    mkdir -p "$STAGE/$(dirname "$rel")"
    ln -s "$f" "$STAGE/$rel"
  done <"$WORK/$vendor.files"
done

for vendor in KokoroVendored MisakiVendored; do
  rm -rf "Sources/harness/$vendor"
  mv "$STAGE/$vendor" "Sources/harness/$vendor"
done

echo "linked $(find Sources/harness -type l | wc -l | tr -d ' ') files"
