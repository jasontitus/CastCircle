#!/usr/bin/env python3
"""
Generate a test text export of the Pride & Prejudice script
in the format that LineGuide's ScriptExporter.toPlainText() produces.
"""

import json
import sys
import os


def to_plain_text(script_data: list, title: str) -> str:
    """Mirror the Dart ScriptExporter.toPlainText() format."""
    buf = []

    buf.append('=' * 60)
    buf.append(title.upper())
    buf.append('=' * 60)
    buf.append('')

    # Gather character line counts
    char_counts = {}
    for line in script_data:
        if line['line_type'] == 'dialogue' and line['character']:
            char_counts[line['character']] = char_counts.get(line['character'], 0) + 1

    buf.append('CAST OF CHARACTERS')
    buf.append('-' * 40)
    for char, count in sorted(char_counts.items(), key=lambda x: -x[1]):
        buf.append(f'  {char} ({count} lines)')
    buf.append('')
    buf.append('=' * 60)
    buf.append('')

    for line in script_data:
        lt = line['line_type']
        if lt == 'header':
            buf.append('')
            buf.append(f'--- {line["text"]} ---')
            buf.append('')
        elif lt == 'stage_direction':
            text = line['text'].strip()
            if text.startswith('('):
                text = text[1:]
            if text.endswith(')'):
                text = text[:-1]
            buf.append(f'  [{text.strip()}]')
            buf.append('')
        elif lt == 'dialogue':
            direction = ''
            if line.get('stage_direction'):
                direction = f' ({line["stage_direction"]})'
            buf.append(f'{line["character"]}:{direction} {line["text"]}')
            buf.append('')

    return '\n'.join(buf)


def to_character_lines(script_data: list, title: str, character: str) -> str:
    """Mirror ScriptExporter.toCharacterLines()."""
    buf = []
    buf.append('=' * 60)
    buf.append(f'{character.upper()} — {title}')
    buf.append('=' * 60)
    buf.append('')

    char_lines = [l for l in script_data
                  if l['line_type'] == 'dialogue' and l['character'] == character]
    buf.append(f'Total lines: {len(char_lines)}')
    buf.append('')

    current_act = ''
    for line in script_data:
        if line['line_type'] == 'header' and line['act'] != current_act:
            current_act = line['act']
            buf.append(f'--- {line["text"]} ---')
            buf.append('')
            continue

        if line['line_type'] == 'dialogue':
            if line['character'] == character:
                direction = ''
                if line.get('stage_direction'):
                    direction = f' ({line["stage_direction"]})'
                buf.append(f'  >>> YOU:{direction} {line["text"]}')
                buf.append('')
            else:
                text = line['text']
                if len(text) > 80:
                    text = text[:77] + '...'
                buf.append(f'  {line["character"]}: {text}')
        elif line['line_type'] == 'stage_direction':
            text = line['text'].strip()
            if text.startswith('('):
                text = text[1:]
            if text.endswith(')'):
                text = text[:-1]
            buf.append(f'  [{text.strip()}]')

    return '\n'.join(buf)


def to_cue_script(script_data: list, title: str, character: str) -> str:
    """Mirror ScriptExporter.toCueScript()."""
    buf = []
    buf.append(f'CUE SCRIPT: {character.upper()}')
    buf.append(title)
    buf.append('=' * 60)
    buf.append('')

    dialogue_lines = [l for l in script_data if l['line_type'] == 'dialogue']

    for i, line in enumerate(dialogue_lines):
        if line['character'] == character:
            if i > 0:
                cue = dialogue_lines[i - 1]
                words = cue['text'].split()
                last_words = ' '.join(words[-8:]) if len(words) > 8 else cue['text']
                buf.append(f'CUE ({cue["character"]}): ...{last_words}')
            direction = ''
            if line.get('stage_direction'):
                direction = f' ({line["stage_direction"]})'
            buf.append(f'YOU:{direction} {line["text"]}')
            buf.append('')

    return '\n'.join(buf)


if __name__ == '__main__':
    json_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'examples', 'pride_and_prejudice_parsed.json'
    )

    with open(json_path) as f:
        data = json.load(f)

    title = 'Pride and Prejudice'
    export_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'examples', 'exports'
    )
    os.makedirs(export_dir, exist_ok=True)

    # 1. Full script plain text
    full_text = to_plain_text(data, title)
    full_path = os.path.join(export_dir, 'pride_and_prejudice_full.txt')
    with open(full_path, 'w') as f:
        f.write(full_text)
    print(f'Full script export: {full_path}')

    # 2. Elizabeth's lines
    elizabeth_lines = to_character_lines(data, title, 'ELIZABETH')
    elizabeth_path = os.path.join(export_dir, 'pride_and_prejudice_elizabeth.txt')
    with open(elizabeth_path, 'w') as f:
        f.write(elizabeth_lines)
    print(f'Elizabeth lines export: {elizabeth_path}')

    # 3. Darcy's cue script
    darcy_cues = to_cue_script(data, title, 'DARCY')
    darcy_path = os.path.join(export_dir, 'pride_and_prejudice_darcy_cues.txt')
    with open(darcy_path, 'w') as f:
        f.write(darcy_cues)
    print(f'Darcy cue script: {darcy_path}')

    # Stats
    dialogue_count = len([l for l in data if l['line_type'] == 'dialogue'])
    print(f'\nStats: {len(data)} total lines, {dialogue_count} dialogue')
