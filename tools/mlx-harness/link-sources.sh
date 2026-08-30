#!/bin/bash
# Recreate per-file symlinks to the app's vendored MLX sources.
# SwiftPM does not follow directory symlinks, so each .swift file gets its own.
# Re-run after adding/removing files under ios/Runner/{Kokoro,Misaki}Vendored.
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"
SOURCE_ROOT="$REPO_ROOT/ios/Runner"
DEST_ROOT="Sources/harness"

mkdir -p "$DEST_ROOT"
WORK="$(mktemp -d "$DEST_ROOT/.link-sources.XXXXXX")"
chmod 700 "$WORK"
COMMITTED=0
ROLLBACK_FAILED=0

restore_vendor() {
  VENDOR="$1"
  DESTINATION="$DEST_ROOT/$VENDOR"
  if [[ -e "$WORK/backup/$VENDOR" || -L "$WORK/backup/$VENDOR" ]]; then
    if ! rm -rf "$DESTINATION"; then
      echo "ERROR: rollback could not remove replacement $DESTINATION" >&2
      ROLLBACK_FAILED=1
      return
    fi
    if ! mv "$WORK/backup/$VENDOR" "$DESTINATION"; then
      echo "ERROR: rollback could not restore $DESTINATION" >&2
      ROLLBACK_FAILED=1
    fi
  elif [[ -f "$WORK/absent/$VENDOR" ]]; then
    if ! rm -rf "$DESTINATION"; then
      echo "ERROR: rollback could not remove newly-created $DESTINATION" >&2
      ROLLBACK_FAILED=1
    fi
  fi
}

cleanup() {
  STATUS=$?
  trap - EXIT INT TERM
  if [[ "$COMMITTED" -ne 1 ]]; then
    restore_vendor KokoroVendored
    restore_vendor MisakiVendored
  fi
  if ! rm -rf "$WORK"; then
    echo "ERROR: could not remove private relink staging directory $WORK" >&2
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

mkdir -p "$WORK/manifests" "$WORK/stage" "$WORK/backup" "$WORK/absent"
for vendor in KokoroVendored MisakiVendored; do
  SOURCE="$SOURCE_ROOT/$vendor"
  MANIFEST="$WORK/manifests/$vendor"
  if [[ ! -d "$SOURCE" || ! -r "$SOURCE" ]]; then
    echo "ERROR: MLX source directory is missing or unreadable: $SOURCE" >&2
    exit 1
  fi
  if ! find "$SOURCE" -type f -name '*.swift' -print >"$MANIFEST"; then
    echo "ERROR: could not enumerate MLX sources under $SOURCE" >&2
    exit 1
  fi
  SOURCE_COUNT="$(awk 'END { print NR+0 }' "$MANIFEST")"
  if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    echo "ERROR: no Swift sources found under $SOURCE" >&2
    exit 1
  fi
done

TOTAL=0
for vendor in KokoroVendored MisakiVendored; do
  SOURCE="$SOURCE_ROOT/$vendor"
  MANIFEST="$WORK/manifests/$vendor"
  STAGED_VENDOR="$WORK/stage/$vendor"
  mkdir -p "$STAGED_VENDOR"
  while IFS= read -r source_file; do
    case "$source_file" in
      "$SOURCE"/*) ;;
      *) echo "ERROR: source escaped validated vendor tree: $source_file" >&2; exit 1 ;;
    esac
    relative_path="${source_file#"$SOURCE/"}"
    mkdir -p "$STAGED_VENDOR/$(dirname "$relative_path")"
    ln -s "$source_file" "$STAGED_VENDOR/$relative_path"
    TOTAL=$((TOTAL + 1))
  done <"$MANIFEST"

done

if [[ "$TOTAL" -eq 0 ]]; then
  echo "ERROR: staged MLX link tree is empty" >&2
  exit 1
fi

for vendor in KokoroVendored MisakiVendored; do
  DESTINATION="$DEST_ROOT/$vendor"
  if [[ -L "$DESTINATION" ]]; then
    echo "ERROR: refusing to replace directory symlink $DESTINATION" >&2
    exit 1
  fi
  if [[ -e "$DESTINATION" ]]; then
    [[ -d "$DESTINATION" ]] || { echo "ERROR: expected directory at $DESTINATION" >&2; exit 1; }
    mv "$DESTINATION" "$WORK/backup/$vendor"
  else
    : >"$WORK/absent/$vendor"
  fi
done

mv "$WORK/stage/KokoroVendored" "$DEST_ROOT/KokoroVendored"
mv "$WORK/stage/MisakiVendored" "$DEST_ROOT/MisakiVendored"
COMMITTED=1

echo "linked $TOTAL files"
