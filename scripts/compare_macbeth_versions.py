#!/usr/bin/env python3
"""
Compare Macbeth Folger PDF extraction vs Gutenberg TXT.

Validates that the Folger PDF conversion produces output that the
CastCircle parser will handle correctly, and reports differences
between the two editions.

Usage:
    python3 scripts/compare_macbeth_versions.py
"""

import difflib
import re
import sys
import subprocess
import tempfile
from pathlib import Path

SAMPLE_DIR = Path(__file__).parent.parent / 'sample-scripts'

CUE_RE = re.compile(r'^([A-Z][A-Z. ]+)\.\s*$')
STRUCTURAL_RE = re.compile(r'^(?:ACT|SCENE)\s+(?:\d+|[IVX]+)\.?\s*$', re.IGNORECASE)
MIN_CUES_PER_VERSION = 50
MIN_CHARACTER_OVERLAP = 0.70
MIN_SCENE_DIALOGUE_BLOCKS = 5
MIN_SCENE_CHARACTER_MATCH = 0.50
MIN_SCENE_TEXT_SIMILARITY = 0.40
CONVERTER_TIMEOUT_SECONDS = 120


def _match_cue(line: str) -> re.Match[str] | None:
    """Match a character cue while excluding act and scene headings."""
    if STRUCTURAL_RE.match(line.strip()):
        return None
    return CUE_RE.match(line)


def _first_scene(text: str) -> str:
    """Return the first scene section that contains character cues."""
    lines = text.splitlines()
    scene_re = re.compile(r'^SCENE\s+(?:1|I)\b', re.IGNORECASE)
    boundary_re = re.compile(r'^(?:ACT|SCENE)\s+(?:\d+|[IVX]+)\b', re.IGNORECASE)
    for start, line in enumerate(lines):
        if not scene_re.match(line.strip()):
            continue
        end = start + 1
        while end < len(lines) and not boundary_re.match(lines[end].strip()):
            end += 1
        section = '\n'.join(lines[start:end])
        if any(_match_cue(candidate) for candidate in lines[start:end]):
            return section
    return ''


def get_characters(text: str) -> dict[str, int]:
    """Extract character names and their cue counts."""
    counts: dict[str, int] = {}
    for line in text.splitlines():
        match = _match_cue(line)
        if match:
            name = match.group(1).strip()
            counts[name] = counts.get(name, 0) + 1
    return counts


def get_dialogue_blocks(text: str) -> list[tuple[str, str]]:
    """Extract each character cue and its full following speech."""
    blocks = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        match = _match_cue(line)
        if not match:
            continue

        dialogue_parts = []
        candidate_index = i + 1
        while candidate_index < len(lines):
            candidate = lines[candidate_index].strip()
            if _match_cue(candidate) or STRUCTURAL_RE.match(candidate):
                break
            if candidate:
                dialogue_parts.append(candidate)
            candidate_index += 1

        if dialogue_parts:
            blocks.append((match.group(1).strip(), ' '.join(dialogue_parts)))
    return blocks

def _normalized_dialogue(blocks: list[tuple[str, str]], limit: int) -> str:
    """Join comparable dialogue text with case and punctuation normalized."""
    dialogue = ' '.join(text for _, text in blocks[:limit]).casefold()
    return re.sub(r'[^a-z0-9]+', ' ', dialogue).strip()


def main():
    # Load Gutenberg TXT
    gut_path = SAMPLE_DIR / 'macbeth-pg1533-images-3.txt'
    if not gut_path.exists():
        print(f"Error: {gut_path} not found")
        sys.exit(1)
    gutenberg = gut_path.read_text(encoding='utf-8')

    # Always compare against the current converter implementation. A temporary
    # destination avoids both stale checked-in output and fixture mutation.
    pdf_path = SAMPLE_DIR / 'macbeth_PDF_FolgerShakespeare.pdf'
    if not pdf_path.exists():
        print(f"Error: {pdf_path} not found", file=sys.stderr)
        return 1
    print("Running current Folger converter...")
    with tempfile.TemporaryDirectory() as temp_dir:
        fol_path = Path(temp_dir) / 'macbeth_folger_converted.txt'
        try:
            result = subprocess.run([
                sys.executable,
                str(Path(__file__).parent / 'pdf_to_script.py'),
                str(pdf_path),
                str(fol_path),
            ], timeout=CONVERTER_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            print(
                f"Error: converter exceeded {CONVERTER_TIMEOUT_SECONDS} seconds",
                file=sys.stderr,
            )
            return 1
        if result.returncode != 0:
            print(f"Error: converter exited with status {result.returncode}", file=sys.stderr)
            return 1
        folger = fol_path.read_text(encoding='utf-8')

    # Compare characters
    gut_chars = get_characters(gutenberg)
    fol_chars = get_characters(folger)

    print("=" * 60)
    print("MACBETH: Folger PDF vs Gutenberg TXT Comparison")
    print("=" * 60)

    print(f"\n--- Character Cues ---")
    print(f"Gutenberg: {sum(gut_chars.values())} cues, {len(gut_chars)} characters")
    print(f"Folger:    {sum(fol_chars.values())} cues, {len(fol_chars)} characters")

    # Common characters
    common = set(gut_chars) & set(fol_chars)
    only_gut = set(gut_chars) - set(fol_chars)
    only_fol = set(fol_chars) - set(gut_chars)

    print(f"\nShared characters ({len(common)}):")
    for c in sorted(common):
        g = gut_chars[c]
        f = fol_chars[c]
        diff = "" if g == f else f"  (Gut: {g}, Fol: {f})"
        print(f"  {c}: {g} cues{diff}")

    if only_gut:
        # Filter out Gutenberg license noise
        real_gut = {c for c in only_gut
                    if not any(w in c for w in ['WARRANTY', 'LIMITED', 'DAMAGE'])}
        noise_gut = only_gut - real_gut
        if real_gut:
            print(f"\nOnly in Gutenberg ({len(real_gut)}):")
            for c in sorted(real_gut):
                print(f"  {c}: {gut_chars[c]} cues")
        if noise_gut:
            print(f"\n  (Gutenberg license noise filtered: {sorted(noise_gut)})")

    if only_fol:
        print(f"\nOnly in Folger ({len(only_fol)}):")
        for c in sorted(only_fol):
            print(f"  {c}: {fol_chars[c]} cues")

    # Compare dialogue attribution within the first actual scene, excluding
    # front matter and tables of contents.
    print(f"\n--- Scene 1 Dialogue Comparison ---")
    gut_blocks = get_dialogue_blocks(_first_scene(gutenberg))
    fol_blocks = get_dialogue_blocks(_first_scene(folger))

    print(f"\n{'#':>3}  {'Gutenberg':30s}  {'Folger':30s}  Match")
    print(f"{'─'*3}  {'─'*30}  {'─'*30}  {'─'*5}")
    for i in range(min(12, len(gut_blocks), len(fol_blocks))):
        gc, gt = gut_blocks[i]
        fc, ft = fol_blocks[i]
        char_match = "✓" if gc == fc else "≠"
        text_sim = "~" if gt[:20] == ft[:20] else "≠"
        print(f"{i+1:3d}  {gc + ': ' + gt[:20]:30s}  {fc + ': ' + ft[:20]:30s}  {char_match}{text_sim}")

    # Summary and compatibility checks. These deliberately test broad parser
    # invariants rather than requiring the two editions to have identical
    # editorial choices.
    max_characters = max(len(gut_chars), len(fol_chars), 1)
    overlap_ratio = len(common) / max_characters
    compared_blocks = min(12, len(gut_blocks), len(fol_blocks))
    matching_characters = sum(
        gut_blocks[i][0] == fol_blocks[i][0]
        for i in range(compared_blocks)
    )
    dialogue_match_ratio = (
        matching_characters / compared_blocks if compared_blocks else 0.0
    )
    normalized_gutenberg = _normalized_dialogue(gut_blocks, compared_blocks)
    normalized_folger = _normalized_dialogue(fol_blocks, compared_blocks)
    text_similarity = difflib.SequenceMatcher(
        None,
        normalized_gutenberg,
        normalized_folger,
        autojunk=False,
    ).ratio()

    failures = []
    for label, cues in (
        ("Gutenberg", sum(gut_chars.values())),
        ("Folger", sum(fol_chars.values())),
    ):
        if cues < MIN_CUES_PER_VERSION:
            failures.append(
                f"{label} has {cues} cues; expected at least {MIN_CUES_PER_VERSION}"
            )
    if overlap_ratio < MIN_CHARACTER_OVERLAP:
        failures.append(
            f"character overlap is {overlap_ratio:.0%}; "
            f"expected at least {MIN_CHARACTER_OVERLAP:.0%}"
        )
    if compared_blocks < MIN_SCENE_DIALOGUE_BLOCKS:
        failures.append(
            f"only {compared_blocks} comparable Scene 1 dialogue blocks; "
            f"expected at least {MIN_SCENE_DIALOGUE_BLOCKS}"
        )
    elif dialogue_match_ratio < MIN_SCENE_CHARACTER_MATCH:
        failures.append(
            f"Scene 1 character attribution matches {dialogue_match_ratio:.0%}; "
            f"expected at least {MIN_SCENE_CHARACTER_MATCH:.0%}"
        )
    if text_similarity < MIN_SCENE_TEXT_SIMILARITY:
        failures.append(
            f"normalized Scene 1 dialogue similarity is {text_similarity:.0%}; "
            f"expected at least {MIN_SCENE_TEXT_SIMILARITY:.0%}"
        )

    print(f"\n--- Summary ---")
    print(
        "Name-on-own-line cue threshold: "
        f"{'✓' if all(sum(chars.values()) >= MIN_CUES_PER_VERSION for chars in (gut_chars, fol_chars)) else 'FAILED'}"
    )
    print(
        f"Character set overlap: {len(common)}/{max_characters} "
        f"({overlap_ratio:.0%}, minimum {MIN_CHARACTER_OVERLAP:.0%})"
    )
    print(
        f"Scene 1 character attribution: {matching_characters}/{compared_blocks} "
        f"({dialogue_match_ratio:.0%}, minimum {MIN_SCENE_CHARACTER_MATCH:.0%})"
    )
    print(
        f"Scene 1 normalized dialogue similarity: {text_similarity:.0%} "
        f"(minimum {MIN_SCENE_TEXT_SIMILARITY:.0%})"
    )

    # Known editorial differences
    print(f"\n--- Expected Editorial Differences ---")
    print(f"  'SOLDIER' (Gutenberg) = 'CAPTAIN' (Folger)")
    print(f"  'APPARITION' (Gutenberg) = 'FIRST/SECOND/THIRD APPARITION' (Folger)")
    print(f"  'BOTH MURDERERS' (Gutenberg) = 'MURDERERS' (Folger)")
    print(f"  Minor spelling: 'hurlyburly' vs 'hurly-burly', etc.")
    print(f"  Stage direction style: '[_Exeunt._]' vs '[They exit.]'")

    if failures:
        print("\nParser compatibility checks failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(f"\nBoth versions passed parser-compatibility thresholds.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
