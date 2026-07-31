#!/bin/bash
# Recreate per-file symlinks to the app's vendored MLX sources.
# SwiftPM does not follow directory symlinks, so each .swift file gets its own.
# Re-run after adding/removing files under ios/Runner/{Kokoro,Misaki}Vendored.
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)

for vendor in KokoroVendored MisakiVendored; do
  rm -rf "Sources/harness/$vendor"
  while IFS= read -r f; do
    rel=${f#"$REPO_ROOT/ios/Runner/"}
    mkdir -p "Sources/harness/$(dirname "$rel")"
    ln -s "$f" "Sources/harness/$rel"
  done < <(find "$REPO_ROOT/ios/Runner/$vendor" -name '*.swift' -type f)
done

echo "linked $(find Sources/harness -type l | wc -l | tr -d ' ') files"
