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

VERSION_LINE="$(grep '^version:' pubspec.yaml)"
VERSION_CODE="${VERSION_LINE##*+}"
VERSION_NAME="${VERSION_LINE#version: }"; VERSION_NAME="${VERSION_NAME%%+*}"
OUT="fastlane/metadata/android/en-US/changelogs/${VERSION_CODE}.txt"
mkdir -p "$(dirname "$OUT")"

if [[ $# -ge 1 ]]; then
  printf '%s\n' "$1" > "$OUT"
else
  if [[ ! -f CHANGELOG.md ]]; then
    echo "✗ No CHANGELOG.md and no text argument." >&2
    exit 1
  fi
  # Refuse to derive notes from a STALE changelog: shipping the previous
  # release's text as this release's notes is worse than shipping none.
  TOP_CODE="$(grep -m1 -oE '^## [0-9.]+\+[0-9]+' CHANGELOG.md | sed 's/.*+//')"
  if [[ "$TOP_CODE" != "$VERSION_CODE" ]]; then
    echo "✗ CHANGELOG.md's newest entry is build ${TOP_CODE:-none}, but this is build $VERSION_CODE." >&2
    echo "  Add a '## $VERSION_NAME+$VERSION_CODE' section, or pass the notes directly:" >&2
    echo "    ./scripts/play-changelog.sh \"What changed in this build\"" >&2
    exit 1
  fi
  # Extract the newest "## version" section and flatten its markdown into
  # the plain text Play shows. (An earlier awk version matched the file's
  # H1 first and shipped the changelog's preamble as release notes.)
  python3 - "$VERSION_CODE" > "$OUT" <<'PYEOF'
import re, sys
code = sys.argv[1]
lines = open('CHANGELOG.md').read().split('\n')
out, inside = [], False
for ln in lines:
    if ln.startswith('## '):
        if inside:
            break
        m = re.match(r'##\s+[0-9.]+\+(\d+)', ln)
        inside = bool(m) and m.group(1) == code
        continue
    if not inside:
        continue
    if ln.startswith('### '):          # section head -> its own line
        out.append(ln[4:].strip() + ':')
    elif ln.startswith('- '):          # bullet -> bullet
        out.append('- ' + ln[2:].strip())
    elif ln.strip():                   # continuation of the previous bullet
        if out and out[-1].startswith('- '):
            out[-1] += ' ' + ln.strip()
        else:
            out.append(ln.strip())
text = '\n'.join(out)
text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)   # drop bold markers
text = re.sub(r'`(.+?)`', r'\1', text)          # drop code ticks
print(text.strip())
PYEOF
fi

# Play caps release notes at 500 characters per language.
CHARS=$(wc -c < "$OUT" | tr -d ' ')
if (( CHARS > 500 )); then
  echo "⚠ Notes were $CHARS chars; truncating to Play's 500-char limit." >&2
  # Trim at a line boundary so the result never ends mid-sentence.
  awk -v limit=497 '{ if (total + length($0) + 1 > limit) exit; print; total += length($0) + 1 }' \
    "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
fi

if [[ ! -s "$OUT" ]]; then
  echo "✗ Produced empty release notes — pass text explicitly:" >&2
  echo "    ./scripts/play-changelog.sh \"What changed in this build\"" >&2
  exit 1
fi

echo "✓ $OUT  (v$VERSION_NAME, code $VERSION_CODE, $(wc -c < "$OUT" | tr -d ' ') chars)"
echo "---"
cat "$OUT"
