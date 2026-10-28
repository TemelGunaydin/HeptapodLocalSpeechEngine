from __future__ import annotations

import importlib.util
import io
import json
import struct
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("pocket_bridge", Path(__file__).resolve().parents[1] / "pocket_turkish_tts.py")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def pcm(samples):
    return struct.pack(f"<{len(samples)}h", *samples)


class TrailingSilenceTests(unittest.TestCase):
    def filtered(self, samples, splits):
        buffer = bridge.TrailingSilenceBuffer(1000)
        data = pcm(samples)
        result = b""
        previous = 0
        for end in [*splits, len(samples)]:
            result += buffer.push(data[previous * 2:end * 2])
            self.assertLessEqual(len(buffer.pending), 1000)
            previous = end
        return result + buffer.finish()

    def test_only_quiet_tail_is_shortened_with_word_ending_guard(self):
        samples = [1200, -900, 9, -9] + [8, -8] * 200
        expected = pcm(samples[:4 + 150])
        self.assertEqual(self.filtered(samples, [1, 3, 73, 180]), expected)

    def test_internal_and_leading_pauses_are_byte_identical(self):
        samples = [0] * 220 + [1200] * 20 + [3] * 1500 + [-1200] * 30 + [0] * 80
        self.assertEqual(self.filtered(samples, [220, 250, 600, 1200, 1600, 1770]), pcm(samples))

    def test_quiet_or_no_tail_is_preserved(self):
        for samples in ([0] * 2000, [1200] * 400, [1200] * 20 + [0] * 150, []):
            with self.subTest(samples=len(samples)):
                self.assertEqual(self.filtered(samples, []), pcm(samples))

    def test_a_late_soft_sound_releases_preceding_silence(self):
        samples = [1200] * 20 + [0] * 400 + [9, -9] + [1] * 300
        self.assertEqual(self.filtered(samples, [20, 100, 420, 422, 500]), pcm(samples[:422 + 150]))

    def test_chunk_boundaries_do_not_change_output(self):
        samples = [1200] * 80 + [0] * 90 + [-1200] * 80 + [2] * 400
        expected = self.filtered(samples, [])
        for width in (1, 17, 80, 160):
            with self.subTest(width=width):
                self.assertEqual(self.filtered(samples, list(range(width, len(samples), width))), expected)

    def test_first_speech_is_released_immediately(self):
        buffer = bridge.TrailingSilenceBuffer(1000)
        first = pcm([1200] * 80)
        self.assertEqual(buffer.push(first), first)


class PocketBridgeTests(unittest.TestCase):
    def test_turkish_locale_and_both_accepted_voices(self):
        bridge.validate_request("Merhaba.", "tr-TR", "female_2")
        bridge.validate_request("Merhaba.", "TR_tr", "male_1")
        for text, language, voice in [("", "tr", "female_2"), ("Hello", "en", "male_1"), ("Merhaba", "tr", "Ava")]:
            with self.subTest(text=text, language=language, voice=voice), self.assertRaises(ValueError):
                bridge.validate_request(text, language, voice)

    def test_malformed_request_does_not_kill_resident_worker(self):
        requests = '[]\nnot json\n' + json.dumps({"id": "next", "text": "Merhaba."}) + '\n'
        output = io.StringIO()
        events = [{"id": "next", "event": "audio", "pcm16": "AQACAA==", "sample_rate": 24000},
                  {"id": "next", "event": "done"}]
        with patch.object(bridge.sys, "stdin", io.StringIO(requests)), patch.object(bridge.sys, "stdout", output), \
                patch.object(bridge, "stream_request", return_value=iter(events)):
            bridge.serve(SimpleNamespace(sample_rate=24000), voice="female_2")
        results = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertTrue(results[0]["ready"])
        self.assertEqual([r["event"] for r in results[1:]], ["error", "error", "audio", "done"])
        self.assertEqual(results[-1]["id"], "next")

    def test_generation_error_retains_correlation_id(self):
        output = io.StringIO()
        with patch.object(bridge.sys, "stdin", io.StringIO('{"id":"failed","text":"Hi"}\n')), \
                patch.object(bridge.sys, "stdout", output), \
                patch.object(bridge, "stream_request", side_effect=ValueError("unsupported language")):
            bridge.serve(SimpleNamespace(sample_rate=24000), voice="male_1")
        error = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(error, {"id": "failed", "event": "error", "error": "unsupported language"})


if __name__ == "__main__":
    unittest.main()
