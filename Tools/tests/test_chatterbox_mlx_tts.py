#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import chatterbox_mlx_tts  # noqa: E402


class ChatterboxBoundaryTrimTests(unittest.TestCase):
    def test_trims_boundaries_and_retains_requested_padding(self) -> None:
        samples = [0.0] * 100 + [0.5] * 200 + [0.0] * 300

        trim_range = chatterbox_mlx_tts.boundary_trim_range(
            samples,
            1_000,
            threshold_db=-45,
            leading_padding_ms=40,
            trailing_padding_ms=120,
        )

        self.assertEqual(trim_range, (60, 420))

    def test_preserves_internal_silence(self) -> None:
        samples = (
            [0.0] * 100
            + [0.5] * 100
            + [0.0] * 200
            + [0.5] * 100
            + [0.0] * 300
        )

        trim_range = chatterbox_mlx_tts.boundary_trim_range(samples, 1_000)

        self.assertEqual(trim_range, (60, 620))

    def test_keeps_all_silence_when_no_speech_is_detected(self) -> None:
        samples = [0.0] * 500

        trim_range = chatterbox_mlx_tts.boundary_trim_range(samples, 1_000)

        self.assertEqual(trim_range, (0, 500))

    def test_boundary_fade_reaches_zero_at_both_edges(self) -> None:
        samples = [1.0] * 10

        fade_sample_count = chatterbox_mlx_tts.apply_boundary_fade(samples, 1_000, fade_ms=3)

        self.assertEqual(fade_sample_count, 3)
        self.assertEqual(samples, [0.0, 0.5, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.5, 0.0])


if __name__ == "__main__":
    unittest.main()
