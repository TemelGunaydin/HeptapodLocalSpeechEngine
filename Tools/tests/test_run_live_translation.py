from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


LAUNCHER = Path(__file__).resolve().parents[1] / "run_live_translation.sh"


@unittest.skipUnless(shutil.which("zsh"), "The live launcher requires zsh")
class RunLiveTranslationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="heptapod launcher ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.binary_dir = self.root / ".build/out/Products/Debug"
        self.binary_dir.mkdir(parents=True)
        self.launcher = self.root / "Tools/run_live_translation.sh"
        self.launcher.parent.mkdir()
        # Mock only xcrun in a copied launcher; never invoke a real build.
        self.launcher.write_text(
            LAUNCHER.read_text().replace("/usr/bin/xcrun", '"$TEST_XCRUN"')
        )
        xcrun = self.root / "xcrun"
        self.write_executable(
            xcrun,
            'case "$*" in\n'
            '  "swift build --product HeptapodLiveSpeechDemo") exit "${TEST_BUILD_STATUS:-0}" ;;\n'
            '  "swift build --show-bin-path") printf "%s\\n" "$TEST_BINARY_DIR" ;;\n'
            '  *) exit 99 ;;\n'
            'esac\n',
        )
        self.metal_log = self.root / "metal.log"
        self.write_executable(
            self.root / ".build/checkouts/speech-swift/scripts/build_mlx_metallib.sh",
            'printf "%s\\n" "$BUILD_DIR" "$@" > "$TEST_METAL_LOG"\n'
            'exit "${TEST_METAL_STATUS:-0}"\n',
        )
        self.write_executable(
            self.binary_dir / "HeptapodLiveSpeechDemo",
            'printf "ARG:%s\\n" "$@"\n',
        )
        self.environment = {
            **os.environ,
            "TEST_XCRUN": str(xcrun),
            "TEST_BINARY_DIR": str(self.binary_dir),
            "TEST_METAL_LOG": str(self.metal_log),
            "TEST_BUILD_STATUS": "0",
            "TEST_METAL_STATUS": "0",
            "HEPTAPOD_TRACE_PATH": str(self.root / "trace with spaces.jsonl"),
        }

    def write_executable(self, path: Path, body: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/zsh\nset -eu\n" + body)
        path.chmod(0o755)

    def run_launcher(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["zsh", str(self.launcher), "--help", "--to", "tr"],
            cwd=self.root.parent,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_bundled_library_skips_legacy_build_and_forwards_arguments(self) -> None:
        for resource in ("Contents/Resources/default.metallib", "default.metallib"):
            with self.subTest(resource=resource):
                library = self.binary_dir / "mlx-swift_Cmlx.bundle" / resource
                library.parent.mkdir(parents=True, exist_ok=True)
                library.write_bytes(b"compiled Metal library")
                self.environment["TEST_METAL_STATUS"] = "42"
                result = self.run_launcher()
                library.unlink()

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.metal_log.exists())
                arguments = [
                    line.removeprefix("ARG:")
                    for line in result.stdout.splitlines()
                    if line.startswith("ARG:")
                ]
                self.assertEqual(
                    arguments,
                    [
                        "--real", "--system-audio", "--play-output", "--trace",
                        self.environment["HEPTAPOD_TRACE_PATH"], "--help", "--to", "tr",
                    ],
                )

    def test_missing_bundle_uses_legacy_build(self) -> None:
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.metal_log.read_text().splitlines(),
            [str(self.root / ".build"), "debug"],
        )

    def test_empty_bundled_library_uses_legacy_build(self) -> None:
        library = self.binary_dir / "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        library.parent.mkdir(parents=True)
        library.touch()
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.metal_log.exists())

    def test_legacy_build_failure_stops_launch(self) -> None:
        self.environment["TEST_METAL_STATUS"] = "42"
        result = self.run_launcher()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn("ARG:", result.stdout)

    def test_swift_build_failure_stops_launch(self) -> None:
        self.environment["TEST_BUILD_STATUS"] = "43"
        result = self.run_launcher()
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertFalse(self.metal_log.exists())
        self.assertNotIn("ARG:", result.stdout)


if __name__ == "__main__":
    unittest.main()
