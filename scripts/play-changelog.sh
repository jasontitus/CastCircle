#!/usr/bin/env bash
#
# Write the Play release notes for the CURRENT versionCode.
#
#   ./scripts/play-changelog.sh                  # from CHANGELOG.md's top section
#   ./scripts/play-changelog.sh "Free text"      # explicit notes
#
# Fastlane looks for fastlane/metadata/android/en-US/changelogs/<versionCode>.txt
# and silently ships NO release notes when the file is absent — so
# play-preflight.sh treats a missing file as a failure and this script is
# how you satisfy it.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [release notes]" >&2
  exit 2
fi

if ! VERSION_LINE="$(awk '/^version:/ { count++; line=$0 } END { if (count != 1) exit 1; print line }' pubspec.yaml)"; then
  echo "✗ pubspec.yaml must contain exactly one version: line." >&2
  exit 1
fi
case "$VERSION_LINE" in
  'version: '*) VERSION_VALUE="${VERSION_LINE#version: }" ;;
  *) echo "✗ pubspec.yaml version must use 'version: <name>+<numericCode>'." >&2; exit 1 ;;
esac
case "$VERSION_VALUE" in
  *+*) ;;
  *) echo "✗ pubspec.yaml version '$VERSION_VALUE' has no numeric +versionCode." >&2; exit 1 ;;
esac
VERSION_NAME="${VERSION_VALUE%%+*}"
VERSION_CODE="${VERSION_VALUE#*+}"
case "$VERSION_CODE" in
  ''|*[!0-9]*|*+*) echo "✗ pubspec.yaml versionCode must be one decimal integer (got '$VERSION_CODE')." >&2; exit 1 ;;
esac
if ! printf '%s\n' "$VERSION_NAME" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' >/dev/null; then
  echo "✗ pubspec.yaml version name is malformed (got '$VERSION_NAME')." >&2
  exit 1
fi

OUT_DIR="fastlane/metadata/android/en-US/changelogs"
OUT="$OUT_DIR/${VERSION_CODE}.txt"
mkdir -p "$OUT_DIR"
TMP_NOTES="$(mktemp "$OUT_DIR/.${VERSION_CODE}.XXXXXX")"
trap 'rm -f "$TMP_NOTES"' EXIT

if [[ $# -eq 1 ]]; then
  printf '%s\n' "$1" > "$TMP_NOTES"
else
  if [[ ! -f CHANGELOG.md ]]; then
    echo "✗ No CHANGELOG.md and no text argument." >&2
    exit 1
  fi
  TOP_HEADING="$(awk '/^## [0-9]/ { print; exit }' CHANGELOG.md)"
  EXPECTED_HEADING="## $VERSION_NAME+$VERSION_CODE"
  if [[ "$TOP_HEADING" != "$EXPECTED_HEADING"* ]]; then
    TOP_SUFFIX="invalid"
  else
    TOP_SUFFIX="${TOP_HEADING#"$EXPECTED_HEADING"}"
  fi
  if [[ -n "$TOP_SUFFIX" ]] && ! printf '%s\n' "$TOP_SUFFIX" | grep -E '^ — [0-9]{4}-[0-9]{2}-[0-9]{2}$' >/dev/null; then
    echo "✗ CHANGELOG.md's newest version heading is '${TOP_HEADING:-none}', but expected '$EXPECTED_HEADING' with an optional ISO date." >&2
    echo "  Add a '$EXPECTED_HEADING — YYYY-MM-DD' section, or pass the notes directly:" >&2
    echo "    ./scripts/play-changelog.sh \"What changed in this build\"" >&2
    exit 1
  fi

  if ! python3 - "$VERSION_CODE" > "$TMP_NOTES" <<'PYEOF'
import re
import sys

code = sys.argv[1]
with open("CHANGELOG.md", encoding="utf-8") as changelog:
    lines = changelog.read().splitlines()

out = []
inside = False
for line in lines:
    if line.startswith("## "):
        if inside:
            break
        match = re.fullmatch(r"##\s+[0-9]+(?:\.[0-9]+){2}(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\+(\d+)(?: — \d{4}-\d{2}-\d{2})?", line)
        inside = match is not None and match.group(1) == code
        continue
    if not inside:
        continue
    if line.startswith("### "):
        out.append(line[4:].strip() + ":")
    elif line.startswith("- "):
        out.append("- " + line[2:].strip())
    elif line.strip():
        if out and out[-1].startswith("- "):
            out[-1] += " " + line.strip()
        else:
            out.append(line.strip())

text = "\n".join(out)
text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
text = re.sub(r"`(.+?)`", r"\1", text)
print(text.strip())
PYEOF
  then
    echo "✗ Could not derive release notes from CHANGELOG.md." >&2
    exit 1
  fi
fi

if ! NOTE_STATS="$(python3 - "$TMP_NOTES" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as notes_file:
    text = notes_file.read().strip()

if not text:
    raise SystemExit("release notes are empty")

original_length = len(text)
truncated = False
if original_length > 500:
    truncated = True
    complete_lines = []
    for line in text.splitlines():
        candidate = "\n".join(complete_lines + [line])
        if len(candidate) + 1 > 500:
            break
        complete_lines.append(line)
    if complete_lines:
        text = "\n".join(complete_lines) + "…"
    else:
        text = text[:499] + "…"

if not text or len(text) > 500:
    raise SystemExit("release-note length normalization failed")
with open(path, "w", encoding="utf-8", newline="") as notes_file:
    notes_file.write(text)
print(original_length, len(text), 1 if truncated else 0)
PYEOF
)"; then
  echo "✗ Produced invalid or empty release notes — pass text explicitly:" >&2
  echo "    ./scripts/play-changelog.sh \"What changed in this build\"" >&2
  exit 1
fi
read -r ORIGINAL_CHARS FINAL_CHARS TRUNCATED <<< "$NOTE_STATS"
case "$ORIGINAL_CHARS:$FINAL_CHARS:$TRUNCATED" in
  *[!0-9:]*) echo "✗ Release-note verifier returned malformed counts." >&2; exit 1 ;;
esac
if [[ "$TRUNCATED" -eq 1 ]]; then
  echo "⚠ Notes were $ORIGINAL_CHARS chars; truncated to $FINAL_CHARS for Play's 500-character limit." >&2
fi

mv "$TMP_NOTES" "$OUT"
trap - EXIT

echo "✓ $OUT  (v$VERSION_NAME, code $VERSION_CODE, $FINAL_CHARS chars)"
echo "---"
cat "$OUT"
printf '\n'
