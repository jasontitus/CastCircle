#!/usr/bin/env python3
"""
PDF to Script Text Converter for CastCircle.

Extracts text from play-script PDFs and converts to the "name-on-own-line"
format that the CastCircle parser expects:

    MACBETH.
    Is this a dagger which I see before me,
    The handle toward my hand?

Supports two PDF types:
1. Text-based PDFs (e.g., Project Gutenberg) — direct text extraction
2. Folger Shakespeare Library PDFs — position-based extraction with
   character name labels in the left margin

Usage:
    python3 scripts/pdf_to_script.py <input.pdf> [output.txt]
"""

import re
import sys
from pathlib import Path

try:
    import pymupdf
except ImportError:
    print("Error: pymupdf is required. Install with: pip install pymupdf")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Character name database (shared with Dart parser)
# ---------------------------------------------------------------------------

# Shakespeare characters that appear as margin labels in Folger PDFs.
# Extend this set for other plays as needed.
KNOWN_CHARACTERS: set[str] = {
    # Macbeth
    'DUNCAN', 'MALCOLM', 'DONALBAIN', 'MACBETH', 'LADY MACBETH',
    'BANQUO', 'MACDUFF', 'LADY MACDUFF', 'LENNOX', 'ROSS', 'ANGUS',
    'MENTEITH', 'CAITHNESS', 'FLEANCE', 'SIWARD', 'YOUNG SIWARD',
    'SEYTON', 'HECATE', 'FIRST WITCH', 'SECOND WITCH', 'THIRD WITCH',
    'CAPTAIN', 'PORTER', 'OLD MAN', 'DOCTOR', 'GENTLEWOMAN',
    'FIRST MURDERER', 'SECOND MURDERER', 'THIRD MURDERER',
    'FIRST APPARITION', 'SECOND APPARITION', 'THIRD APPARITION',
    'MESSENGER', 'SERVANT', 'LORD', 'SOLDIER', 'ALL', 'SON',
    'LORDS', 'BOTH', 'WITCHES',
    # Hamlet
    'HAMLET', 'CLAUDIUS', 'GERTRUDE', 'HORATIO', 'LAERTES', 'OPHELIA',
    'POLONIUS', 'GHOST', 'ROSENCRANTZ', 'GUILDENSTERN', 'FORTINBRAS',
    'OSRIC', 'PLAYER KING', 'PLAYER QUEEN', 'LUCIANUS', 'PROLOGUE',
    'GRAVEDIGGER', 'OTHER', 'PRIEST', 'FRANCISCO', 'BARNARDO',
    'MARCELLUS', 'REYNALDO', 'VOLTIMAND', 'CORNELIUS',
    'FIRST PLAYER', 'SECOND PLAYER',
    # Generic
    'KING', 'QUEEN', 'PRINCE', 'PRINCESS', 'NURSE',
    'FIRST GENTLEMAN', 'SECOND GENTLEMAN',
    'FIRST SENATOR', 'SECOND SENATOR',
    'FIRST CITIZEN', 'SECOND CITIZEN', 'THIRD CITIZEN',
    'A MESSENGER', 'A SERVANT', 'A LORD', 'A SOLDIER',
    'ATTENDANT', 'GUARD', 'OFFICER', 'PAGE',
}

# Stage direction starters.
_STAGE_DIR_STARTERS = (
    'Enter ', 'Exit', 'Exeunt', 'Alarum', 'Thunder', 'Flourish',
    'Sennet', 'Hautboys', 'Trumpets', 'Cornets', 'Retreat',
    'Re-enter',
)

_STAGE_DIR_ENDERS = (
    ' exit.', ' exits.', ' exit', ' exits',
)


def _is_stage_direction(text: str) -> bool:
    """Check if text looks like a stage direction."""
    for s in _STAGE_DIR_STARTERS:
        if text.startswith(s):
            return True
    for s in _STAGE_DIR_ENDERS:
        if text.endswith(s):
            return True
    if text in ('They exit.', 'They exit'):
        return True
    if re.match(r'^(He |She |They |It |The .+ (exit|is led|are led|enters?|falls?))', text):
        return True
    if re.match(r'^(A bell|Drum |Knock|Music|Sound|Wind|Storm|Rain|Lightning|A sennet)', text):
        return True
    return False


def _roman(n: int) -> str:
    """Convert integer to Roman numeral."""
    vals = [(10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I')]
    result = ''
    for v, r in vals:
        while n >= v:
            result += r
            n -= v
    return result


# ---------------------------------------------------------------------------
# Detection: is this a Folger-style PDF?
# ---------------------------------------------------------------------------

def _is_folger_pdf(doc: pymupdf.Document) -> bool:
    """Detect if a PDF uses Folger Shakespeare Library formatting."""
    # Check first 15 pages for Folger signatures
    for pg_idx in range(min(15, doc.page_count)):
        page = doc[pg_idx]
        text = page.get_text()
        if 'Folger Shakespeare' in text or 'FTLN' in text:
            return True
    return False


# ---------------------------------------------------------------------------
# Folger PDF extraction
# ---------------------------------------------------------------------------

def _detect_characters_from_pdf(doc: pymupdf.Document) -> set[str]:
    """Auto-detect character names from a Folger PDF by scanning margin labels."""
    chars = set()
    for pg_idx in range(doc.page_count):
        page = doc[pg_idx]
        blocks = page.get_text("dict")["blocks"]
        for block in blocks:
            if "lines" not in block:
                continue
            for line_obj in block["lines"]:
                text = "".join(span["text"] for span in line_obj["spans"]).strip()
                x0 = line_obj["bbox"][0]
                # Character labels are at x≈88-90 in Folger PDFs
                if 80 <= x0 <= 95 and text.isupper() and 2 <= len(text) <= 30:
                    if not re.match(r'^(ACT|SCENE|FTLN|SETTING|NOTE)\b', text):
                        chars.add(text)
    return chars


def _extract_folger(doc: pymupdf.Document) -> str:
    """Extract text from a Folger Shakespeare PDF using position-based parsing."""
    # Auto-detect characters from margin labels
    detected_chars = _detect_characters_from_pdf(doc)
    all_chars = KNOWN_CHARACTERS | detected_chars

    output: list[str] = []
    in_play = False
    current_char = ''
    play_start_page = -1

    # Find the page where ACT 1 appears as a centered header (not TOC)
    for pg_idx in range(doc.page_count):
        page = doc[pg_idx]
        blocks = page.get_text("dict")["blocks"]
        for block in blocks:
            if "lines" not in block:
                continue
            for line_obj in block["lines"]:
                text = "".join(span["text"] for span in line_obj["spans"]).strip()
                x0 = line_obj["bbox"][0]
                # ACT 1 as a centered header (x > 200) on a page that also has
                # Scene 1 and stage directions
                if text == 'ACT 1' and x0 > 200:
                    # Verify this page has actual play content (stage dirs or dialogue)
                    page_text = page.get_text()
                    if ('Enter ' in page_text or 'FTLN' in page_text or
                            any(c in page_text for c in ['WITCH', 'DUNCAN', 'MACBETH'])):
                        play_start_page = pg_idx
                        break
        if play_start_page >= 0:
            break

    if play_start_page < 0:
        play_start_page = 0  # fallback

    for pg_idx in range(play_start_page, doc.page_count):
        page = doc[pg_idx]
        blocks = page.get_text("dict")["blocks"]

        # Collect all text elements with position
        elements: list[tuple[float, float, str]] = []
        for block in blocks:
            if "lines" not in block:
                continue
            for line_obj in block["lines"]:
                text = "".join(span["text"] for span in line_obj["spans"]).strip()
                if not text:
                    continue
                x0 = line_obj["bbox"][0]
                y0 = line_obj["bbox"][1]
                elements.append((y0, x0, text))

        elements.sort(key=lambda e: (e[0], e[1]))

        # Group elements into visual lines (within 5 y-units)
        visual_lines: list[list[tuple[float, float, str]]] = []
        current_group: list[tuple[float, float, str]] = []
        current_y = -100.0

        for y, x, text in elements:
            if abs(y - current_y) > 5:
                if current_group:
                    visual_lines.append(current_group)
                current_group = [(y, x, text)]
                current_y = y
            else:
                current_group.append((y, x, text))
        if current_group:
            visual_lines.append(current_group)

        for group in visual_lines:
            char_name = None
            dialogue_parts: list[str] = []
            act_header = None
            scene_header = None
            stage_dir = None

            for y, x, text in sorted(group, key=lambda e: e[1]):
                # Skip FTLN markers
                if re.match(r'^FTLN \d+', text):
                    continue
                # Skip right-margin line numbers
                if x > 400 and re.match(r'^\d+$', text):
                    continue
                # Skip running header "Macbeth" (centered)
                if text == 'Macbeth' and 200 < x < 280:
                    continue
                # Skip running "ACT X. SC. Y" header
                if x > 350 and re.match(r'^ACT \d+\. SC\. \d+', text):
                    continue
                # Skip page number at top left
                if re.match(r'^\d{1,3}$', text) and 90 < x < 100:
                    continue
                # Skip margin line numbers
                if re.match(r'^\d{1,3}$', text) and x < 50:
                    continue

                # Character name at x≈88.8
                if text in all_chars and 80 <= x <= 95:
                    char_name = text
                # ACT header (centered)
                elif re.match(r'^ACT \d+$', text) and x > 200:
                    act_header = text
                # Scene header
                elif re.match(r'^Scene \d+$', text) and x > 200:
                    scene_header = text
                # Stage direction (centered, high x)
                elif x > 120 and _is_stage_direction(text):
                    stage_dir = text
                # Stage direction continuation (starts with comma from prev)
                elif x > 120 and text.startswith(', ') and not char_name:
                    stage_dir = text
                # Dialogue text (x >= 95)
                elif x >= 95:
                    dialogue_parts.append(text)

            # Emit structured lines
            if act_header:
                if not in_play:
                    in_play = True
                num = int(re.search(r'\d+', act_header).group())
                output.append(f'\n\nACT {_roman(num)}\n')
                current_char = ''

            if scene_header:
                num = scene_header.split()[-1]
                output.append(f'\nSCENE {num}.\n')
                current_char = ''

            if stage_dir:
                if current_char:
                    output.append('')  # blank line to end current speech
                output.append(f'\n [{stage_dir}]\n')
                # Don't clear current_char — dialogue may continue after
                # inline stage directions (e.g., "He draws his dagger.")

            if char_name:
                if current_char and current_char != char_name:
                    output.append('')  # blank line between speakers
                output.append(f'{char_name}.')
                current_char = char_name
                if dialogue_parts:
                    output.append(' '.join(dialogue_parts))
            elif dialogue_parts:
                if not current_char and not stage_dir:
                    # Orphan dialogue — could be continuation from prev page
                    pass
                output.append(' '.join(dialogue_parts))

    return '\n'.join(output)


# ---------------------------------------------------------------------------
# Standard (Gutenberg-style) PDF extraction
# ---------------------------------------------------------------------------

def _extract_standard(doc: pymupdf.Document) -> str:
    """Extract text from a standard text-based PDF (e.g., Project Gutenberg)."""
    text_parts: list[str] = []
    for page in doc:
        text_parts.append(page.get_text())
    return '\n'.join(text_parts)


# ---------------------------------------------------------------------------
# Post-processing
# ---------------------------------------------------------------------------

def _clean_output(text: str) -> str:
    """Clean up common artifacts in extracted text."""
    # Remove bare page numbers on their own line
    text = re.sub(r'^\d{1,3}\s*$', '', text, flags=re.MULTILINE)
    # Collapse 3+ consecutive blank lines to 2
    text = re.sub(r'\n{4,}', '\n\n\n', text)
    # Remove trailing whitespace
    text = re.sub(r' +$', '', text, flags=re.MULTILINE)
    # Clean double spaces within lines
    text = re.sub(r'  +', ' ', text)
    return text.strip() + '\n'


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def convert_pdf_to_script(pdf_path: str) -> str:
    """Convert a play-script PDF to parser-ready text format."""
    doc = pymupdf.open(pdf_path)

    if _is_folger_pdf(doc):
        print(f"Detected Folger Shakespeare format ({doc.page_count} pages)")
        text = _extract_folger(doc)
    else:
        print(f"Detected standard text PDF ({doc.page_count} pages)")
        text = _extract_standard(doc)

    doc.close()
    return _clean_output(text)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.pdf> [output.txt]")
        sys.exit(1)

    pdf_path = sys.argv[1]
    if not Path(pdf_path).exists():
        print(f"Error: File not found: {pdf_path}")
        sys.exit(1)

    result = convert_pdf_to_script(pdf_path)

    if len(sys.argv) >= 3:
        output_path = sys.argv[2]
    else:
        output_path = str(Path(pdf_path).with_suffix('.converted.txt'))

    Path(output_path).write_text(result)
    print(f"Written {len(result)} chars to {output_path}")

    # Quick stats
    lines = result.splitlines()
    char_cues = [l for l in lines if re.match(r'^[A-Z][A-Z. ]+\.\s*$', l)]
    print(f"Character cues found: {len(char_cues)}")
    char_names = set(l.rstrip('.').strip() for l in char_cues)
    print(f"Unique characters: {len(char_names)}")
    if char_names:
        print(f"Characters: {', '.join(sorted(char_names))}")


if __name__ == '__main__':
    main()
