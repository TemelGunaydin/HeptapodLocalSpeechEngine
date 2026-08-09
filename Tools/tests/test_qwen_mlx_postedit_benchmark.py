from __future__ import annotations

import sys
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

import qwen_mlx_postedit_benchmark as benchmark  # noqa: E402


class QwenPostEditBenchmarkTests(unittest.TestCase):
    def test_prompt_contains_bounded_context_and_current_draft(self) -> None:
        prompt = benchmark.build_user_prompt(
            source="Current source.",
            draft="Mevcut taslak.",
            context=[("Previous source.", "Önceki çeviri.")],
        )

        self.assertIn("Previous source.", prompt)
        self.assertIn("Önceki çeviri.", prompt)
        self.assertIn("Current source.", prompt)
        self.assertIn("Mevcut taslak.", prompt)

    def test_output_normalization_removes_only_known_wrappers(self) -> None:
        self.assertEqual(
            benchmark.normalize_output('"Doğal bir çeviri."'),
            "Doğal bir çeviri.",
        )
        self.assertEqual(
            benchmark.normalize_output("Çeviri: Doğal bir çeviri."),
            "Doğal bir çeviri.",
        )
        self.assertEqual(
            benchmark.normalize_output("Açıklama eklenmemeli."),
            "Açıklama eklenmemeli.",
        )

    def test_percentile_uses_nearest_rank(self) -> None:
        self.assertEqual(benchmark.percentile(list(range(1, 25)), 0.95), 23)


if __name__ == "__main__":
    unittest.main()
