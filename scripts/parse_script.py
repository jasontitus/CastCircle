#!/usr/bin/env python3
"""
Script parser for LineGuide.

Parses OCR'd play text into a structured markdown format.
This serves as both:
  1. A working parser for the Pride & Prejudice script
  2. A reference implementation for the Flutter app's on-device parser

Format: Standard American play format
  - CHARACTER NAME. Dialogue text
  - (Stage directions in parentheses)
  - ACT / SCENE headers
  - Page numbers and headers as noise
"""

import re
import sys
import json
from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Optional


class LineType(str, Enum):
    DIALOGUE = "dialogue"
    STAGE_DIRECTION = "stage_direction"
    HEADER = "header"


@dataclass
class ScriptLine:
    act: str
    scene: str
    line_number: int  # sequential within scene
    order_index: int  # global ordering
    character: str  # empty for stage directions and headers
    text: str
    line_type: LineType
    stage_direction: str = ""  # inline direction like "(Smiling:)"


# Known characters for this script (extracted from cast list on page 1).
# In the app, these would be auto-detected then confirmed by the organizer.
KNOWN_CHARACTERS = [
    "MR. BENNET",
    "MRS. BENNET",
    "ELIZABETH",
    "JANE",
    "MARY",
    "KITTY",
    "LYDIA",
    "MR. DARCY",
    "DARCY",
    "MR. BINGLEY",
    "BINGLEY",
    "MISS BINGLEY",
    "CHARLOTTE",
    "COLLINS",
    "MR. COLLINS",
    "SIR WILLIAM LUCAS",
    "MR. LUCAS",
    "LADY CATHERINE",
    "MRS. GARDINER",
    "MR. GARDINER",
    "WICKHAM",
    "GEORGE WICKHAM",
    "FITZWILLIAM",
    "COLONEL FITZWILLIAM",
    "HOUSEKEEPER",
    "OFFICER",
    "SERVANT",
]
# Longest-first so "MR. BENNET" matches before "MR."; compiled once.
_SORTED_CUE_PATTERNS = [
    (char, re.compile(re.escape(char) + r"\.\s+"))
    for char in sorted(KNOWN_CHARACTERS, key=len, reverse=True)
]


# Normalize character name variants to canonical names
CHARACTER_ALIASES = {
    "MR. DARCY": "DARCY",
    "MR. BINGLEY": "BINGLEY",
    "MR. COLLINS": "COLLINS",
    "MR. LUCAS": "SIR WILLIAM LUCAS",
    "GEORGE WICKHAM": "WICKHAM",
    "COLONEL FITZWILLIAM": "FITZWILLIAM",
}


def _cue_key(name: str) -> str:
    """Normalize cue punctuation and spacing for exact speaker lookup."""
    return re.sub(r"[^A-Z0-9]", "", name.upper())


_CHARACTER_BY_CUE_KEY = {
    _cue_key(name): CHARACTER_ALIASES.get(name, name)
    for name in KNOWN_CHARACTERS
}

# Page headers/footers and noise patterns to strip
NOISE_PATTERNS = [
    r"^\d+\s+Jon Jory$",                    # "12 Jon Jory"
    r"^Jon Jory\s+\d+$",                    # "Jon Jory 12"
    r"^Pride and Prejudice\s+\d+$",          # "Pride and Prejudice 17"
    r"^\d+$",                                 # bare page numbers
    r"^[|}]\s*$",                             # OCR artifacts
    r"^\$[A-Za-z\s]+$",                       # OCR noise like "$i ice"
    r"^[a-z]{2,}\s+[a-z]{2,}\s+[a-z]{2,}$",  # lowercase OCR gibberish
]

# Patterns that look like OCR margin noise (handwritten annotations picked up)
MARGIN_NOISE = re.compile(
    r"(?:Kep\s*lace|annouyn|dhe\s*Aan|Ruynoy\s*Claims|"
    r"sinqu\s*Our|moor\s*sous|wow\s*Wane|ent\s*ine|"
    r"ave\s*We\s*Wee|Urs\s*Huts|ISS\s*Anny|"
    r"JT\.\s*@m|Sale\s*And|BERR\s*OIN|"
    r"[A-Z]{2,}\s+[a-z]{2,}\s+[A-Z]{2,})"
)


def is_noise(line: str) -> bool:
    """Check if a line is page header/footer noise."""
    stripped = line.strip()
    if not stripped:
        return True
    for pattern in NOISE_PATTERNS:
        if re.match(pattern, stripped):
            return True
    return False


def clean_line(text: str) -> str:
    """Remove OCR artifacts and margin noise from a line."""
    # Remove margin annotations (handwritten notes picked up by OCR)
    text = MARGIN_NOISE.sub("", text)
    # Remove stray pipes, tildes, and other OCR artifacts
    text = re.sub(r"[|~°]", "", text)
    # Remove trailing artifacts
    text = re.sub(r"\s+[/\\]\s*$", "", text)
    # Clean up multiple spaces
    text = re.sub(r"  +", " ", text)
    return text.strip()


def detect_character_cue(line: str) -> Optional[tuple[str, str]]:
    """
    Detect if a line starts with a character name followed by dialogue.
    Returns (character_name, dialogue_text) or None.

    Pattern: CHARACTER NAME. Dialogue text here
             CHARACTER NAME. (Direction:) Dialogue text
             MARY, KITTY, LYDIA. (To the audience:) Text
    """
    # Precompiled, longest-first (module scope): this runs once per input
    # line, and re-sorting + re-escaping ~27 patterns per line was ~130k
    # regex builds on a full-length play.
    for char, pattern in _SORTED_CUE_PATTERNS:
        match = pattern.match(line)
        if match:
            dialogue = line[match.end():]
            return (char, dialogue)

    # Try each possible cue terminator so periods in titles such as "MR."
    # cannot truncate a valid multi-character cue.
    for terminator in re.finditer(r"\.\s+", line):
        names_text = line[:terminator.start()]
        dialogue = line[terminator.end():]
        if "," not in names_text or not dialogue:
            continue
        raw_names = names_text.split(",")
        if any(not name.strip() for name in raw_names):
            continue
        resolved_names = [
            _CHARACTER_BY_CUE_KEY.get(_cue_key(name))
            for name in raw_names
        ]
        if all(resolved_names):
            return (
                ", ".join(name for name in resolved_names if name is not None),
                dialogue,
            )

    return None


def is_stage_direction(text: str) -> bool:
    """Check if text is a standalone stage direction (fully in parens)."""
    stripped = text.strip()
    return stripped.startswith("(") and stripped.endswith(")")


def extract_inline_direction(text: str) -> tuple[str, str]:
    """
    Extract inline stage direction from start of dialogue.
    e.g., "(Smiling:) Hello there" -> ("Smiling", "Hello there")
    """
    match = re.match(r"^\(([^)]+?):\)\s*(.*)", text)
    if match:
        return (match.group(1), match.group(2))
    return ("", text)


def normalize_character(name: str) -> str:
    """Normalize character name to canonical form."""
    name = name.strip()
    return CHARACTER_ALIASES.get(name, name)


def parse_script(raw_text: str) -> list[ScriptLine]:
    """Parse raw OCR text into structured ScriptLine records."""
    lines = raw_text.split("\n")
    result: list[ScriptLine] = []

    current_act = "ACT I"
    current_scene = ""
    current_character = ""
    current_dialogue_parts: list[str] = []
    scene_line_num = 0
    order_index = 0

    def flush_dialogue():
        nonlocal order_index, scene_line_num
        if current_character and current_dialogue_parts:
            full_text = " ".join(current_dialogue_parts)
            full_text = clean_line(full_text)
            if not full_text:
                return

            direction, dialogue = extract_inline_direction(full_text)

            char_name = normalize_character(current_character)
            scene_line_num += 1
            order_index += 1
            result.append(ScriptLine(
                act=current_act,
                scene=current_scene,
                line_number=scene_line_num,
                order_index=order_index,
                character=char_name,
                text=dialogue if dialogue else full_text,
                line_type=LineType.DIALOGUE,
                stage_direction=direction,
            ))

    def add_stage_direction(text: str):
        nonlocal order_index, scene_line_num
        text = clean_line(text)
        if not text or len(text) < 3:
            return
        scene_line_num += 1
        order_index += 1
        result.append(ScriptLine(
            act=current_act,
            scene=current_scene,
            line_number=scene_line_num,
            order_index=order_index,
            character="",
            text=text,
            line_type=LineType.STAGE_DIRECTION,
        ))

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i += 1

        # Skip noise
        if is_noise(line):
            continue

        act_match = re.fullmatch(r"ACT\s+(?:[IVX]+|\d+)\.?", line)
        if act_match:
            flush_dialogue()
            current_act = line.strip()
            current_scene = ""
            scene_line_num = 0
            current_character = ""
            current_dialogue_parts = []
            order_index += 1
            result.append(ScriptLine(
                act=current_act,
                scene="",
                line_number=0,
                order_index=order_index,
                character="",
                text=current_act,
                line_type=LineType.HEADER,
            ))
            continue

        # Supported scene headers use a numeral, then an optional period and
        # short title. Scoped case-folding keeps lowercase dialogue after the
        # numeral from becoming a title.
        scene_match = re.fullmatch(
            r"(?i:SCENE)\s+(?:\d+|[IVX]+)"
            r"(?:\.\s*(?:[A-Z][A-Za-z0-9’'., -]{0,119})?)?",
            line,
        )
        if scene_match:
            flush_dialogue()
            current_scene = line.strip()
            scene_line_num = 0
            current_character = ""
            current_dialogue_parts = []
            continue

        # Clean the line
        line = clean_line(line)
        if not line:
            continue

        # Check for character cue
        cue = detect_character_cue(line)
        if cue:
            flush_dialogue()
            current_character = cue[0]
            current_dialogue_parts = [cue[1]]
            continue

        # Standalone stage direction
        if is_stage_direction(line):
            flush_dialogue()
            current_character = ""
            current_dialogue_parts = []
            add_stage_direction(line)
            continue

        # Continuation of current dialogue (wrapped line)
        if current_character and current_dialogue_parts:
            # Check it's not just noise
            if len(line) > 2 and not re.match(r"^[^a-zA-Z]*$", line):
                current_dialogue_parts.append(line)
            continue

        # Standalone stage direction without parens but looks like one
        # (starts with lowercase after a flush)
        if not current_character and line.startswith("("):
            add_stage_direction(line)
            continue

    # Flush any remaining dialogue
    flush_dialogue()

    return result


def to_markdown(script_lines: list[ScriptLine]) -> str:
    """Convert parsed script lines to a readable markdown format."""
    md_parts = []
    current_act = ""

    for sl in script_lines:
        if sl.line_type == LineType.HEADER:
            current_act = sl.text
            md_parts.append(f"\n# {sl.text}\n")
            continue

        if sl.line_type == LineType.STAGE_DIRECTION:
            md_parts.append(f"*{sl.text}*\n")
            continue

        if sl.line_type == LineType.DIALOGUE:
            direction_prefix = f" *({sl.stage_direction})* " if sl.stage_direction else " "
            md_parts.append(f"**{sl.character}.**{direction_prefix}{sl.text}\n")

    return "\n".join(md_parts)


def to_json(script_lines: list[ScriptLine]) -> str:
    """Convert to JSON for app consumption."""
    return json.dumps([asdict(sl) for sl in script_lines], indent=2)


def print_stats(script_lines: list[ScriptLine]):
    """Print parsing statistics."""
    dialogues = [sl for sl in script_lines if sl.line_type == LineType.DIALOGUE]
    directions = [sl for sl in script_lines if sl.line_type == LineType.STAGE_DIRECTION]

    print(f"Total lines: {len(script_lines)}")
    print(f"  Dialogue lines: {len(dialogues)}")
    print(f"  Stage directions: {len(directions)}")
    print(f"  Headers: {len(script_lines) - len(dialogues) - len(directions)}")
    print()

    # Character line counts
    char_counts: dict[str, int] = {}
    for sl in dialogues:
        char_counts[sl.character] = char_counts.get(sl.character, 0) + 1

    print("Character line counts:")
    for char, count in sorted(char_counts.items(), key=lambda x: -x[1]):
        print(f"  {char}: {count}")


if __name__ == "__main__":
    input_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pride_full_ocr.txt"

    with open(input_file, "r", encoding="utf-8") as f:
        raw_text = f.read()

    script_lines = parse_script(raw_text)
    print_stats(script_lines)

    # Write markdown
    md_output = to_markdown(script_lines)
    md_path = input_file.replace(".txt", "_parsed.md")
    if md_path == input_file:
        md_path = input_file + "_parsed.md"

    # Write to the repo as the example (repo root derived from this file's
    # location — the old hardcoded /home/user/Lineguide-/ path failed on
    # every machine but one long-gone checkout).
    import os
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    examples_dir = os.path.join(repo_root, "examples")
    repo_md_path = os.path.join(examples_dir, "pride_and_prejudice_parsed.md")
    repo_json_path = os.path.join(examples_dir, "pride_and_prejudice_parsed.json")

    os.makedirs(examples_dir, exist_ok=True)

    with open(repo_md_path, "w", encoding="utf-8") as f:
        f.write(md_output)
    print(f"\nMarkdown written to: {repo_md_path}")

    # Write JSON
    json_output = to_json(script_lines)
    with open(repo_json_path, "w", encoding="utf-8") as f:
        f.write(json_output)
    print(f"JSON written to: {repo_json_path}")
