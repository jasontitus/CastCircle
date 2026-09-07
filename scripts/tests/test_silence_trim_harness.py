#!/usr/bin/env python3

import hashlib
import http.server
import math
import os
import re
import shutil
import struct
import subprocess
import tempfile
import threading
import unittest
import wave
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "test_silence_trim.swift"


def write_speech_fixture(path: Path, sample_rate: int, frequency: float) -> None:
    """Write 0.5s silence, 1.0s tone, then 0.5s silence."""
    frame_count = sample_rate * 2
    frames = bytearray()
    for frame in range(frame_count):
        if sample_rate // 2 <= frame < sample_rate * 3 // 2:
            sample = int(12_000 * math.sin(2 * math.pi * frequency * frame / sample_rate))
        else:
            sample = 0
        frames.extend(struct.pack("<h", sample))

    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(frames)


def run_harness(*arguments: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["swift", str(SCRIPT_PATH), *arguments],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


@unittest.skipUnless(
    shutil.which("swift") and os.uname().sysname == "Darwin",
    "requires the macOS Swift AVFoundation runtime",
)
class SilenceTrimHarnessTests(unittest.TestCase):
    def test_44100_and_48000_hz_fixtures_agree_and_concurrent_outputs_are_isolated(self):
        with tempfile.TemporaryDirectory() as temp_directory:
            root = Path(temp_directory)
            input_44100 = root / "tone-44100.wav"
            input_48000 = root / "tone-48000.wav"
            output_44100 = root / "trimmed-44100.m4a"
            output_48000 = root / "trimmed-48000.m4a"
            write_speech_fixture(input_44100, 44_100, 440.0)
            write_speech_fixture(input_48000, 48_000, 880.0)

            processes = [
                subprocess.Popen(
                    [
                        "swift",
                        str(SCRIPT_PATH),
                        str(input_path),
                        "--keep-output",
                        str(output_path),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for input_path, output_path in (
                    (input_44100, output_44100),
                    (input_48000, output_48000),
                )
            ]
            results = [process.communicate(timeout=90) for process in processes]

            detected_ranges = []
            for process, (stdout, stderr), sample_rate in zip(
                processes,
                results,
                (44_100, 48_000),
            ):
                self.assertEqual(process.returncode, 0, stderr)
                self.assertIn(f"Decoded format: {sample_rate} Hz", stdout)
                match = re.search(
                    r"Would trim to: ([0-9.]+)s - ([0-9.]+)s",
                    stdout,
                )
                self.assertIsNotNone(match, stdout)
                detected_ranges.append(tuple(map(float, match.groups())))

            self.assertLessEqual(
                abs(detected_ranges[0][0] - detected_ranges[1][0]),
                0.05,
            )
            self.assertLessEqual(
                abs(detected_ranges[0][1] - detected_ranges[1][1]),
                0.05,
            )
            self.assertTrue(output_44100.is_file())
            self.assertTrue(output_48000.is_file())
            self.assertNotEqual(
                hashlib.sha256(output_44100.read_bytes()).digest(),
                hashlib.sha256(output_48000.read_bytes()).digest(),
            )

    def test_malformed_remote_url_reports_error_without_swift_trap(self):
        result = run_harness("http:::/malformed")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR: validate remote input", result.stderr)
        self.assertNotIn("Fatal error", result.stderr)
        self.assertNotIn("unexpectedly found nil", result.stderr)

    def test_http_failure_reports_status_and_nonzero_exit(self):
        class FailureHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(503)
                self.end_headers()

            def log_message(self, format, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FailureHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = run_harness(
                f"http://127.0.0.1:{server.server_port}/audio.m4a"
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("download returned HTTP 503", result.stderr)
        self.assertNotIn("Fatal error", result.stderr)

    def test_interrupted_download_reports_error_without_partial_input(self):
        class InterruptedHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", "10000")
                self.end_headers()
                self.wfile.write(b"partial")
                self.wfile.flush()
                self.connection.shutdown(1)

            def log_message(self, format, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), InterruptedHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = run_harness(
                f"http://127.0.0.1:{server.server_port}/audio.m4a"
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR: download", result.stderr)
        self.assertNotIn("Fatal error", result.stderr)


if __name__ == "__main__":
    unittest.main()
