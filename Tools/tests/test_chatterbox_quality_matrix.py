#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import chatterbox_quality_matrix  # noqa: E402


class ChatterboxQualityMatrixTests(unittest.TestCase):
    def test_matrix_keeps_flat_baseline_and_official_neutral_default(self) -> None:
        variants = chatterbox_quality_matrix.quality_variants()

        self.assertEqual([variant.name for variant in variants], [
            "flat-e010-cfg050",
            "neutral-e050-cfg050",
            "deliberate-e050-cfg030",
            "expressive-e070-cfg030",
        ])
        self.assertEqual(variants[0].exaggeration, 0.1)
        self.assertEqual(variants[1].exaggeration, 0.5)
        self.assertEqual(variants[1].cfg_weight, 0.5)


if __name__ == "__main__":
    unittest.main()
