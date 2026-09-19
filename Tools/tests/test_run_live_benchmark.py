from __future__ import annotations

import sys
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

import run_live_benchmark as benchmark  # noqa: E402


class RunLiveBenchmarkTests(unittest.TestCase):
    def test_parse_case_rejects_empty_label(self) -> None:
        with self.assertRaises(benchmark.argparse.ArgumentTypeError):
            benchmark.parse_case(":compact:1.0:4")

    def test_validate_cases_rejects_duplicate_labels(self) -> None:
        cases = [
            benchmark.BenchmarkCase("smoke", "compact", 1.0, 4),
            benchmark.BenchmarkCase("smoke", "quality", 1.0, 4),
        ]

        with self.assertRaisesRegex(ValueError, "duplicate benchmark case label"):
            benchmark.validate_cases(cases)

    def test_validate_cases_rejects_colliding_slugs(self) -> None:
        cases = [
            benchmark.BenchmarkCase("quality smoke", "compact", 1.0, 4),
            benchmark.BenchmarkCase("quality-smoke", "quality", 1.0, 4),
        ]

        with self.assertRaisesRegex(ValueError, "same output slug"):
            benchmark.validate_cases(cases)

    def test_command_uses_selected_binary_and_postedit_mode(self) -> None:
        command = benchmark.benchmark_command(
            benchmark.BenchmarkCase("smoke", "compact", 1.0, 4),
            demo_binary=Path("/tmp/flowdeck/HeptapodLiveSpeechDemo"),
            audio_path=Path("/tmp/input.wav"),
            uses_system_audio=False,
            source_language="en",
            target_language="tr",
            mt_backend="apple",
            mt_postedit="none",
            duration_seconds=10.0,
            trace_path=Path("/tmp/trace.jsonl"),
            uses_asr_stabilization=True,
            uses_punctuation_endpoint=True,
            uses_speech_output=False,
            tts_backend="chatterbox-mlx",
            tts_python_executable="python3",
            tts_device="auto",
            plays_output=False,
            speech_output_dir=None,
        )

        self.assertEqual(command[0], "/tmp/flowdeck/HeptapodLiveSpeechDemo")
        self.assertEqual(command[command.index("--mt-postedit") + 1], "none")
        self.assertIn("--asr-stabilization", command)
        self.assertIn("--punctuation-endpoint", command)


if __name__ == "__main__":
    unittest.main()
