from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

import run_live_benchmark as benchmark  # noqa: E402

RUNNER = TOOLS_DIR / "run_live_benchmark.py"


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

    def test_parse_case_accepts_nemotron(self) -> None:
        case = benchmark.parse_case("streaming-en:nemotron:1.0:3")

        self.assertEqual(case.label, "streaming-en")
        self.assertEqual(case.asr, "nemotron")
        self.assertEqual(case.chunk_duration, 1.0)
        self.assertEqual(case.max_buffered_segments, 3)
        self.assertEqual(case.slug, "streaming-en")

    def test_parse_case_rejects_unknown_asr(self) -> None:
        with self.assertRaisesRegex(
            benchmark.argparse.ArgumentTypeError,
            "asr must be compact, quality, or nemotron",
        ):
            benchmark.parse_case("smoke:whisper:1.0:3")

    def test_quick_preset_is_unchanged(self) -> None:
        self.assertEqual(
            benchmark.default_cases("quick"),
            [
                benchmark.BenchmarkCase("compact-1.0-b3", "compact", 1.0, 3),
                benchmark.BenchmarkCase("quality-1.0-b3", "quality", 1.0, 3),
            ],
        )

    def test_matrix_preset_is_unchanged(self) -> None:
        self.assertEqual(
            benchmark.default_cases("matrix"),
            [
                benchmark.BenchmarkCase("compact-1.0-b3", "compact", 1.0, 3),
                benchmark.BenchmarkCase("compact-1.2-b3", "compact", 1.2, 3),
                benchmark.BenchmarkCase("compact-1.5-b3", "compact", 1.5, 3),
                benchmark.BenchmarkCase("quality-1.0-b3", "quality", 1.0, 3),
                benchmark.BenchmarkCase("quality-1.2-b3", "quality", 1.2, 3),
                benchmark.BenchmarkCase("quality-1.5-b3", "quality", 1.5, 3),
            ],
        )

    def test_asr_preset_has_three_parity_cases(self) -> None:
        cases = benchmark.default_cases("asr")

        self.assertEqual([case.asr for case in cases], ["compact", "quality", "nemotron"])
        self.assertEqual({case.chunk_duration for case in cases}, {1.0})
        self.assertEqual({case.max_buffered_segments for case in cases}, {3})
        self.assertEqual(
            len({case.label for case in cases}),
            3,
            "asr preset labels must be unique",
        )
        self.assertEqual(
            len({case.slug for case in cases}),
            3,
            "asr preset labels must produce unique slugs",
        )
        benchmark.validate_cases(cases)

    def test_benchmark_command_forwards_each_asr_preset(self) -> None:
        for case in benchmark.default_cases("asr"):
            with self.subTest(asr=case.asr):
                command = benchmark.benchmark_command(
                    case,
                    demo_binary=Path("/tmp/flowdeck/HeptapodLiveSpeechDemo"),
                    audio_path=Path("/tmp/input.wav"),
                    uses_system_audio=False,
                    source_language="en",
                    target_language="tr",
                    mt_backend="apple",
                    mt_postedit="none",
                    duration_seconds=10.0,
                    trace_path=Path(f"/tmp/trace-{case.slug}.jsonl"),
                    uses_asr_stabilization=True,
                    uses_punctuation_endpoint=True,
                    uses_speech_output=False,
                    tts_backend="moss",
                    tts_python_executable="python3",
                    tts_device="auto",
                    plays_output=False,
                    speech_output_dir=None,
                )

                self.assertEqual(command[command.index("--asr") + 1], case.asr)
                self.assertEqual(command[command.index("--chunk-duration") + 1], "1")
                self.assertEqual(command[command.index("--max-buffered-segments") + 1], "3")

    @staticmethod
    def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RUNNER), *args],
            cwd=str(TOOLS_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_cli_preset_asr_dry_run_with_skip_build(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            completed = self.run_cli(
                "--audio", "/nonexistent/fixture.wav",
                "--duration", "30",
                "--preset", "asr",
                "--mt", "apple",
                "--mt-postedit", "none",
                "--asr-stabilization",
                "--punctuation-endpoint",
                "--output-dir", tmp,
                "--dry-run",
                "--skip-build",
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        for asr in ("compact", "quality", "nemotron"):
            self.assertIn(f"--asr {asr}", completed.stdout)
        self.assertEqual(completed.stdout.count("--trace "), 3)
        self.assertNotIn("swift build", completed.stdout)
        self.assertNotIn("build_mlx_metallib", completed.stdout)

    def test_cli_case_override_wins_over_preset(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            completed = self.run_cli(
                "--audio", "/nonexistent/fixture.wav",
                "--duration", "30",
                "--preset", "asr",
                "--case", "custom-nemotron:nemotron:1.5:4",
                "--output-dir", tmp,
                "--dry-run",
                "--skip-build",
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.count("--trace "), 1)
        self.assertIn("--asr nemotron", completed.stdout)
        self.assertIn("--chunk-duration 1.5", completed.stdout)
        self.assertIn("--max-buffered-segments 4", completed.stdout)
        self.assertNotIn("--asr compact", completed.stdout)
        self.assertNotIn("--asr quality", completed.stdout)

    def test_cli_rejects_unknown_case_asr(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            completed = self.run_cli(
                "--audio", "/nonexistent/fixture.wav",
                "--case", "bad:whisper:1.0:3",
                "--output-dir", tmp,
                "--dry-run",
                "--skip-build",
            )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("asr must be compact, quality, or nemotron", completed.stderr)


if __name__ == "__main__":
    unittest.main()
