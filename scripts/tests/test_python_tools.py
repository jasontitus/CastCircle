#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
FIXTURES_DIR = Path(__file__).parent / "fixtures"


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS_DIR / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


parse_script_module = load_script("castcircle_parse_script", "parse_script.py")
compare_module = load_script(
    "castcircle_compare_macbeth_versions",
    "compare_macbeth_versions.py",
)
try:
    import pymupdf  # noqa: F401
except ModuleNotFoundError:
    pymupdf_stub = types.ModuleType("pymupdf")
    pymupdf_stub.Document = object
    sys.modules["pymupdf"] = pymupdf_stub

pdf_module = load_script("castcircle_pdf_to_script", "pdf_to_script.py")


class CharacterCueTests(unittest.TestCase):
    def test_multi_speaker_cues_require_every_exact_known_name(self):
        detect = parse_script_module.detect_character_cue

        self.assertEqual(
            detect("MARY, KITTY, LYDIA. We all agree."),
            ("MARY, KITTY, LYDIA", "We all agree."),
        )
        self.assertEqual(
            detect("MR DARCY, MR. BINGLEY. We should leave."),
            ("DARCY, BINGLEY", "We should leave."),
        )
        self.assertIsNone(detect("MARY, STRANGER. We all agree."))
        self.assertIsNone(detect("MARYLAND, KITTY. This is not a cue."))
        self.assertIsNone(detect("MARY, KITTY, GET DOWN. NOW."))

    def test_only_full_headers_transition_and_dialogue_prefixes_survive(self):
        raw_text = (FIXTURES_DIR / "parser_headers.txt").read_text(encoding="utf-8")
        parsed = parse_script_module.parse_script(raw_text)
        dialogue = [
            line for line in parsed
            if line.line_type == parse_script_module.LineType.DIALOGUE
        ]

        self.assertEqual([line.character for line in dialogue], ["MARY", "KITTY"])
        self.assertEqual(
            dialogue[0].text,
            "Opening line. ACT I must remain part of Mary's speech. "
            "Scene 2 begins in the same speech.",
        )
        self.assertEqual(dialogue[0].scene, "")
        self.assertEqual(dialogue[1].scene, "SCENE II. The drawing room.")
        self.assertEqual(
            dialogue[1].text,
            "After the scene header. ACT 3 days have passed. "
            "Scene 2: don't leave me.",
        )


class AlignmentTests(unittest.TestCase):
    def fixture_blocks(self, name: str):
        text = (FIXTURES_DIR / name).read_text(encoding="utf-8")
        return compare_module.get_dialogue_blocks(text)

    def test_insertion_and_rename_do_not_shift_later_matches(self):
        aligned = compare_module.align_dialogue_blocks(
            self.fixture_blocks("dialogue_left.txt"),
            self.fixture_blocks("dialogue_right.txt"),
        )

        self.assertEqual(
            [status for status, _, _ in aligned],
            ["match", "insert", "match", "replace", "match"],
        )
        self.assertEqual(aligned[2][1][0], "BOB")
        self.assertEqual(aligned[2][2][0], "BOB")
        self.assertEqual(aligned[-1][1][0], "DAN")
        self.assertEqual(aligned[-1][2][0], "DAN")

    def test_deletion_is_explicit_and_subsequent_blocks_realign(self):
        left = self.fixture_blocks("dialogue_left.txt")
        right = [left[0], *left[2:]]
        aligned = compare_module.align_dialogue_blocks(left, right)

        self.assertEqual(
            [status for status, _, _ in aligned],
            ["match", "delete", "match", "match"],
        )
        self.assertEqual(aligned[-1][1], aligned[-1][2])


class FakePage:
    def __init__(self, page_fixture):
        self.plain_text = page_fixture["plain_text"]
        self.lines = page_fixture["lines"]

    def get_text(self, output_type=None):
        if output_type != "dict":
            return self.plain_text
        line_objects = [
            {
                "bbox": [line["x"], line["y"], line["x"] + 10, line["y"] + 5],
                "spans": [{"text": line["text"]}],
            }
            for line in self.lines
        ]
        return {"blocks": [{"lines": line_objects}]}


class FakeDocument:
    def __init__(self, fixture):
        self.pages = [FakePage(page) for page in fixture["pages"]]
        self.page_count = len(self.pages)

    def __getitem__(self, index):
        return self.pages[index]


class PdfConversionTests(unittest.TestCase):
    def test_folger_orphans_are_reported_but_page_continuations_survive(self):
        fixture = json.loads(
            (FIXTURES_DIR / "folger_visual_lines.json").read_text(encoding="utf-8")
        )
        diagnostics = io.StringIO()
        with contextlib.redirect_stderr(diagnostics):
            output = pdf_module._extract_folger(FakeDocument(fixture))

        self.assertNotIn("Front matter must not become dialogue.", output)
        self.assertNotIn("Isolated text after a header is an orphan.", output)
        self.assertNotIn("Unattributed isolated text is skipped.", output)
        self.assertIn("A dagger—there’s the cue.", output)
        self.assertIn("This normal continuation remains.", output)
        self.assertIn("This new-page continuation remains.", output)
        self.assertIn("An explicit stage-adjacent continuation remains.", output)
        self.assertIn("Skipped 2 orphan dialogue line(s)", diagnostics.getvalue())
        self.assertIn("page 2:", diagnostics.getvalue())
        self.assertIn("page 3:", diagnostics.getvalue())

    def test_cli_writes_generated_unicode_as_utf8(self):
        generated = "MACBETH. Curly quote: ’; em dash: —; IPA: ð.\n"
        with tempfile.TemporaryDirectory() as temp_directory:
            output_path = Path(temp_directory) / "converted.txt"
            input_path = Path(temp_directory) / "fixture.pdf"
            input_path.write_bytes(b"")
            with mock.patch.object(
                pdf_module,
                "convert_pdf_to_script",
                return_value=generated,
            ), mock.patch.object(
                sys,
                "argv",
                ["pdf_to_script.py", str(input_path), str(output_path)],
            ), contextlib.redirect_stdout(io.StringIO()):
                pdf_module.main()

            self.assertEqual(output_path.read_bytes(), generated.encode("utf-8"))
            self.assertEqual(output_path.read_text(encoding="utf-8"), generated)


if __name__ == "__main__":
    unittest.main()
