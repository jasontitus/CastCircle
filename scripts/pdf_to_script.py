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

from collections import Counter
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



def _is_stage_direction(text: str) -> bool:
    """Check if text uses a narrow, direction-specific lexical form."""
    for starter in _STAGE_DIR_STARTERS:
        if text.startswith(starter):
            return True
    if re.match(
        r'^(?:He|She|It) (?:exits?|enters?|falls?|is led)(?:[.,]|$)',
        text,
    ):
        return True
    if re.match(
        r'^They (?:exit|enter|fall|are led)(?:[.,]|$)',
        text,
    ):
        return True
    if re.match(
        r"^[A-Z][A-Za-z’'-]*(?: and [A-Z][A-Za-z’'-]*)* exits?\.$",
        text,
    ):
        return True
    if re.match(
        r'^(?:A bell|Drum |Knock|Music|Sound|Wind|Storm|Rain|Lightning|A sennet)',
        text,
    ):
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

def _iter_layout_lines(page_dict: dict):
    """Yield nonempty (text, x, y) lines from one cached page dictionary."""
    for block in page_dict["blocks"]:
        if "lines" not in block:
            continue
        for line_obj in block["lines"]:
            text = "".join(span["text"] for span in line_obj["spans"]).strip()
            if text:
                yield text, line_obj["bbox"][0], line_obj["bbox"][1]


def _detect_running_headers(page_dicts: list[dict]) -> set[str]:
    """Find short centered top-of-page strings repeated across the document."""
    counts: Counter[str] = Counter()
    for page_dict in page_dicts:
        candidates = {
            text
            for text, x, y in _iter_layout_lines(page_dict)
            if y < 90
            and 150 < x < 350
            and len(text) <= 80
            and not re.match(r'^(?:ACT|SCENE|FTLN)\b', text, re.IGNORECASE)
        }
        counts.update(candidates)

    minimum_repetitions = 3 if len(page_dicts) >= 3 else 2
    return {
        text
        for text, count in counts.items()
        if count >= minimum_repetitions
    }


def _find_play_start(page_dicts: list[dict]) -> int:
    """Locate Act 1 using generic Folger layout and content evidence."""
    for page_index, page_dict in enumerate(page_dicts):
        lines = list(_iter_layout_lines(page_dict))
        has_act_one = any(
            x > 200 and re.fullmatch(r'ACT\s+(?:1|I)', text, re.IGNORECASE)
            for text, x, _ in lines
        )
        if not has_act_one:
            continue

        has_scene_one = any(
            x > 200 and re.fullmatch(r'SCENE\s+(?:1|I)\.?', text, re.IGNORECASE)
            for text, x, _ in lines
        )
        has_play_content = any(
            re.match(r'^FTLN\s+\d+', text)
            or (80 <= x <= 95 and text.isupper())
            or (x > 120 and _is_stage_direction(text))
            for text, x, _ in lines
        )
        if has_scene_one and has_play_content:
            return page_index

    raise ValueError(
        "could not locate the first act in this Folger PDF; "
        "refusing to include front matter"
    )


def _detect_characters_from_pdf(page_dicts: list[dict]) -> set[str]:
    """Auto-detect character names from cached Folger margin labels."""
    chars = set()
    for page_dict in page_dicts:
        for text, x0, _ in _iter_layout_lines(page_dict):
            # Character labels are at x≈88-90 in Folger PDFs.
            if 80 <= x0 <= 95 and text.isupper() and 2 <= len(text) <= 30:
                if not re.match(r'^(ACT|SCENE|FTLN|SETTING|NOTE)\b', text):
                    chars.add(text)
    return chars


def _extract_folger(doc: pymupdf.Document) -> str:
    """Extract text from a Folger Shakespeare PDF using position-based parsing."""
    # Layout extraction is the expensive operation. Cache it once for character
    # detection, boundary/header detection, and the main extraction pass.
    page_dicts = [
        doc[page_index].get_text("dict")
        for page_index in range(doc.page_count)
    ]
    detected_chars = _detect_characters_from_pdf(page_dicts)
    all_chars = KNOWN_CHARACTERS | detected_chars
    running_headers = _detect_running_headers(page_dicts)

    output: list[str] = []
    current_char = ''
    play_start_page = _find_play_start(page_dicts)

    for pg_idx in range(play_start_page, doc.page_count):
        blocks = page_dicts[pg_idx]["blocks"]

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
                # Skip dynamically detected repeated centered running headers.
                if text in running_headers and y < 90 and 150 < x < 350:
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
                elif re.match(r'^ACT\s+(?:\d+|[IVX]+)$', text, re.IGNORECASE) and x > 200:
                    act_header = text
                # Scene header
                elif re.match(r'^Scene\s+(?:\d+|[IVX]+)\.?$', text, re.IGNORECASE) and x > 200:
                    scene_header = text
                # Stage direction (centered, high x)
                elif x > 120 and _is_stage_direction(text):
                    stage_dir = text
                # A direction split into multiple spans on the same visual line.
                elif x > 120 and text.startswith(', ') and stage_dir is not None:
                    stage_dir = f'{stage_dir}{text}'
                # Dialogue text (x >= 95)
                elif x >= 95:
                    dialogue_parts.append(text)

            # Emit structured lines
            if act_header:
                act_number = act_header.split()[-1].upper()
                if act_number.isdigit():
                    act_number = _roman(int(act_number))
                output.append(f'\n\nACT {act_number}\n')
                current_char = ''

            if scene_header:
                scene_number = scene_header.rstrip('.').split()[-1].upper()
                output.append(f'\nSCENE {scene_number}.\n')
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
                if not current_char:
                    print(
                        f"Warning: discarded orphan dialogue on PDF page {pg_idx + 1}: "
                        f"{' '.join(dialogue_parts)[:80]}",
                        file=sys.stderr,
                    )
                    continue
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
    try:
        if _is_folger_pdf(doc):
            print(f"Detected Folger Shakespeare format ({doc.page_count} pages)")
            text = _extract_folger(doc)
        else:
            print(f"Detected standard text PDF ({doc.page_count} pages)")
            text = _extract_standard(doc)
    finally:
        # A corrupt/encrypted PDF raising mid-extract used to leak the doc
        # handle (and keep the file locked on Windows).
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

    try:
        result = convert_pdf_to_script(pdf_path)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    if len(sys.argv) >= 3:
        output_path = sys.argv[2]
    else:
        output_path = str(Path(pdf_path).with_suffix('.converted.txt'))

    Path(output_path).write_text(result, encoding='utf-8')
    print(f"Written {len(result)} chars to {output_path}")

    # Quick stats
    lines = result.splitlines()
    char_cues = [l for l in lines if re.match(r'^[A-Z][A-Z. ]+\.\s*$', l)]
    print(f"Character cues found: {len(char_cues)}")
    char_names = set(l.rstrip('.').strip() for l in char_cues)
    print(f"Unique characters: {len(char_names)}")
    if char_names:
        print(f"Characters: {', '.join(sorted(char_names))}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
