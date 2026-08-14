#!/usr/bin/env python3
"""Build the bundled demo script from the Project Gutenberg Hamlet.

    python3 scripts/make-demo-script.py

Reads  assets/test_scripts/hamlet.txt   (Gutenberg #1524, public domain)
Writes assets/demo/hamlet_demo.txt

Why a generated excerpt rather than the whole play: the demo exists to show
someone the rehearsal loop in a minute. The full text parses to ~1400 lines
and 35 characters, which greets a first-time user with "35 characters need
actors". Two scenes give a short cue-heavy opener and the famous soliloquy,
with a handful of parts — enough to cast, rehearse, and understand.

The extraction is scripted rather than hand-pasted so the demo text is
verifiably the real thing and can be rebuilt if the scene choice changes.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'assets/test_scripts/hamlet.txt')
DST = os.path.join(ROOT, 'assets/demo/hamlet_demo.txt')

# (act heading, scene heading, first line index, last line index) — indexes are
# resolved from the scene headings below, not hard-coded line numbers.
WANTED = [
    ('ACT I', 'SCENE I. Elsinore. A platform before the Castle.', None),
    # The soliloquy scene, cut after "Get thee to a nunnery" exchange so the
    # demo stays short. `stop_before` is matched against a line's text.
    ('ACT III', 'SCENE I. A room in the Castle.', 'Enter King and Polonius.'),
]


def scene_bounds(lines):
    """Map every body scene heading to (start, end) line indexes."""
    marks = [(i, l.strip()) for i, l in enumerate(lines)
             if re.match(r'^(ACT [IVX]+|SCENE [IVX]+\.)', l.strip())]
    body = [m for m in marks if m[0] > 100]        # skip the table of contents
    bounds = {}
    for i, (idx, txt) in enumerate(body):
        end = body[i + 1][0] if i + 1 < len(body) else len(lines)
        bounds.setdefault(txt, (idx, end))
    return bounds


def main():
    if not os.path.exists(SRC):
        sys.exit(f'✗ source not found: {SRC}')
    lines = open(SRC, encoding='utf-8').read().split('\n')
    bounds = scene_bounds(lines)

    out = []
    for act, scene, stop_before in WANTED:
        if scene not in bounds:
            sys.exit(f'✗ scene heading not found in source: {scene!r}')
        start, end = bounds[scene]
        block = lines[start:end]
        if stop_before:
            for i, l in enumerate(block):
                if stop_before in l:
                    block = block[:i]
                    break
            else:
                sys.exit(f'✗ stop marker not found in {scene!r}: {stop_before!r}')
        # Trim trailing blank lines so scenes butt up cleanly.
        while block and not block[-1].strip():
            block.pop()
        out.append(act)
        out.append('')
        out.extend(block)
        out.append('')
        out.append('')

    text = '\n'.join(out).rstrip() + '\n'
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, 'w', encoding='utf-8') as fh:
        fh.write(text)

    speakers = sorted({m.group(1) for m in
                       re.finditer(r'^([A-Z][A-Z\' ]+)\.$', text, re.M)})
    print(f'✓ {os.path.relpath(DST, ROOT)}')
    print(f'  {len(text.splitlines())} lines, {len(speakers)} speakers: '
          f'{", ".join(speakers)}')


if __name__ == '__main__':
    main()
