#!/usr/bin/env python3
"""Run repeatable Heptapod live translation benchmark matrices."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
from urllib.parse import urlencode
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEMO_PRODUCT = "HeptapodLiveSpeechDemo"
DEMO_BINARY = REPO_ROOT / ".build" / "debug" / DEMO_PRODUCT
TRACE_SUMMARY = REPO_ROOT / "Tools" / "trace_summary.py"
COMMAND_LINE_TOOLS = Path("/Library/Developer/CommandLineTools")
COMMAND_LINE_TOOLS_SDKS = COMMAND_LINE_TOOLS / "SDKs"
MLX_METALLIB_SCRIPT = REPO_ROOT / ".build" / "checkouts" / "speech-swift" / "scripts" / "build_mlx_metallib.sh"
BROWSER_PLAYBACK_PAGE = REPO_ROOT / "Tools" / "system_audio_browser_playback.html"
GOOGLE_CHROME_BINARY = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
KOKORO_LANGUAGE_CODES = {"en", "fr", "es", "ja", "zh", "hi", "pt", "it"}


@dataclass(frozen=True)
class BenchmarkCase:
    label: str
    asr: str
    chunk_duration: float
    max_buffered_segments: int

    @property
    def slug(self) -> str:
        return safe_slug(self.label)


@dataclass(frozen=True)
class RunResult:
    case: BenchmarkCase
    trace_path: Path
    log_path: Path
    return_code: int

    @property
    def succeeded(self) -> bool:
        return self.return_code == 0


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip())
    return slug.strip("-") or "case"


def default_cases(preset: str) -> list[BenchmarkCase]:
    if preset == "quick":
        return [
            BenchmarkCase("compact-1.0-b3", "compact", 1.0, 3),
            BenchmarkCase("quality-1.0-b3", "quality", 1.0, 3),
        ]
    return [
        BenchmarkCase("compact-1.0-b3", "compact", 1.0, 3),
        BenchmarkCase("compact-1.2-b3", "compact", 1.2, 3),
        BenchmarkCase("compact-1.5-b3", "compact", 1.5, 3),
        BenchmarkCase("quality-1.0-b3", "quality", 1.0, 3),
        BenchmarkCase("quality-1.2-b3", "quality", 1.2, 3),
        BenchmarkCase("quality-1.5-b3", "quality", 1.5, 3),
    ]


def parse_case(value: str) -> BenchmarkCase:
    parts = value.split(":")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(
            "case must be label:asr:chunk_duration:max_buffered_segments"
        )

    label, asr, raw_chunk, raw_buffer = parts
    asr = asr.lower()
    if asr not in {"compact", "quality"}:
        raise argparse.ArgumentTypeError("asr must be compact or quality")

    try:
        chunk_duration = float(raw_chunk)
    except ValueError as error:
        raise argparse.ArgumentTypeError("chunk_duration must be a number") from error

    try:
        max_buffered_segments = int(raw_buffer)
    except ValueError as error:
        raise argparse.ArgumentTypeError("max_buffered_segments must be an integer") from error

    if chunk_duration <= 0:
        raise argparse.ArgumentTypeError("chunk_duration must be positive")
    if max_buffered_segments <= 0:
        raise argparse.ArgumentTypeError("max_buffered_segments must be positive")

    return BenchmarkCase(label, asr, chunk_duration, max_buffered_segments)


def run_command(
    command: list[str],
    *,
    log_path: Path | None = None,
    dry_run: bool = False,
    env: dict[str, str] | None = None,
    playback_audio_path: Path | None = None,
    playback_delay_seconds: float = 0.0,
    playback_browser: str | None = None,
    playback_browser_profile_dir: Path | None = None,
) -> int:
    printable = printable_command(command, env=env)
    if dry_run:
        if playback_audio_path is not None:
            print("# playback starts after the demo reports that system-audio capture began")
            print(
                printable_playback_command(
                    playback_audio_path,
                    playback_delay_seconds,
                    browser=playback_browser,
                    browser_profile_dir=playback_browser_profile_dir,
                )
            )
        print(printable)
        return 0

    if playback_audio_path is not None:
        if log_path is None:
            raise ValueError("playback monitoring requires a log file")
        return run_logged_command_with_capture_playback(
            command,
            log_path=log_path,
            env=env,
            playback_audio_path=playback_audio_path,
            playback_delay_seconds=playback_delay_seconds,
            playback_browser=playback_browser,
            playback_browser_profile_dir=playback_browser_profile_dir,
        )

    if log_path is None:
        completed = subprocess.run(command, cwd=REPO_ROOT, env=env, check=False)
        return completed.returncode

    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as handle:
        handle.write(f"$ {printable}\n\n")
        handle.flush()
        completed = subprocess.run(
            command,
            cwd=REPO_ROOT,
            env=env,
            stdout=handle,
            stderr=subprocess.STDOUT,
            check=False,
        )
        handle.write(f"\nexit_code={completed.returncode}\n")
        return completed.returncode


def run_logged_command_with_capture_playback(
    command: list[str],
    *,
    log_path: Path,
    env: dict[str, str] | None,
    playback_audio_path: Path,
    playback_delay_seconds: float,
    playback_browser: str | None,
    playback_browser_profile_dir: Path | None,
) -> int:
    printable = printable_command(command, env=env)
    playback_command = printable_playback_command(
        playback_audio_path,
        playback_delay_seconds,
        browser=playback_browser,
        browser_profile_dir=playback_browser_profile_dir,
    )
    playback_process: subprocess.Popen[str] | None = None

    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as handle:
        handle.write("$ # playback starts after the demo reports that system-audio capture began\n")
        handle.write(f"$ {playback_command}\n")
        handle.write(f"$ {printable}\n\n")
        handle.flush()

        process = subprocess.Popen(
            command,
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None

        try:
            for line in process.stdout:
                handle.write(line)
                handle.flush()
                if playback_process is None and "Capturing macOS system audio" in line:
                    playback_process = start_delayed_playback(
                        playback_audio_path,
                        playback_delay_seconds,
                        stdout=handle,
                        stderr=subprocess.STDOUT,
                        browser=playback_browser,
                        browser_profile_dir=playback_browser_profile_dir,
                    )
            return_code = process.wait()
        finally:
            stop_playback(playback_process, uses_browser=playback_browser is not None)

        handle.write(f"\nexit_code={return_code}\n")
        return return_code


def printable_playback_command(
    audio_path: Path,
    delay_seconds: float,
    *,
    browser: str | None = None,
    browser_profile_dir: Path | None = None,
) -> str:
    target = playback_target_command(
        audio_path,
        browser=browser,
        browser_profile_dir=browser_profile_dir,
    )
    return "( sleep {delay}; {target} ) &".format(
        delay=format_number(delay_seconds),
        target=shlex.join(target),
    )


def start_delayed_playback(
    audio_path: Path | None,
    delay_seconds: float,
    *,
    stdout,
    stderr,
    browser: str | None = None,
    browser_profile_dir: Path | None = None,
) -> subprocess.Popen[str] | None:
    if audio_path is None:
        return None
    target = playback_target_command(
        audio_path,
        browser=browser,
        browser_profile_dir=browser_profile_dir,
    )
    return subprocess.Popen(
        [
            "/bin/sh",
            "-c",
            "sleep \"$1\"; shift; exec \"$@\"",
            "heptapod-playback",
            format_number(delay_seconds),
            *target,
        ],
        cwd=REPO_ROOT,
        stdout=stdout,
        stderr=stderr,
        text=True,
        start_new_session=browser is not None,
    )


def playback_target_command(
    audio_path: Path,
    *,
    browser: str | None,
    browser_profile_dir: Path | None,
) -> list[str]:
    if browser is None:
        return ["afplay", str(audio_path)]
    if browser != "chrome":
        raise ValueError(f"unsupported playback browser: {browser}")
    if browser_profile_dir is None:
        raise ValueError("browser playback requires a profile directory")

    browser_url = BROWSER_PLAYBACK_PAGE.as_uri() + "?" + urlencode({"audio": audio_path.as_uri()})
    return [
        str(GOOGLE_CHROME_BINARY),
        f"--user-data-dir={browser_profile_dir}",
        "--no-first-run",
        "--no-default-browser-check",
        "--autoplay-policy=no-user-gesture-required",
        "--allow-file-access-from-files",
        f"--app={browser_url}",
    ]


def stop_playback(process: subprocess.Popen[str] | None, *, uses_browser: bool) -> None:
    if process is None or process.poll() is not None:
        return
    if uses_browser:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
    else:
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        if uses_browser:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                return
        else:
            process.kill()
        process.wait(timeout=3)


def printable_command(command: list[str], *, env: dict[str, str] | None = None) -> str:
    prefix = []
    if env is not None:
        for key in ("SDKROOT", "DEVELOPER_DIR", "BUILD_DIR", "HF_DOWNLOAD_STALL_TIMEOUT"):
            value = env.get(key)
            if value and value != os.environ.get(key):
                prefix.append(f"{key}={value}")
    return " ".join([*prefix, *command])


def swift_build_environment() -> dict[str, str] | None:
    env = os.environ.copy()
    changed = False

    if not env.get("SDKROOT"):
        sdk_root = compatible_macos_sdk_root()
        if sdk_root is not None:
            env["SDKROOT"] = str(sdk_root)
            changed = True

    if not env.get("DEVELOPER_DIR") and COMMAND_LINE_TOOLS.exists():
        env["DEVELOPER_DIR"] = str(COMMAND_LINE_TOOLS)
        changed = True

    return env if changed else None


def model_runtime_environment() -> dict[str, str] | None:
    env = os.environ.copy()
    if env.get("HF_DOWNLOAD_STALL_TIMEOUT"):
        return None
    env["HF_DOWNLOAD_STALL_TIMEOUT"] = "600"
    return env


def mlx_metallib_environment() -> dict[str, str]:
    env = os.environ.copy()
    env["BUILD_DIR"] = str(REPO_ROOT / ".build")
    return env


def build_mlx_metallib(*, dry_run: bool) -> int:
    if not MLX_METALLIB_SCRIPT.exists():
        return 0
    return run_command(
        [str(MLX_METALLIB_SCRIPT), "debug"],
        dry_run=dry_run,
        env=mlx_metallib_environment(),
    )


def compatible_macos_sdk_root() -> Path | None:
    if not COMMAND_LINE_TOOLS_SDKS.exists():
        return None

    candidates: list[tuple[float, Path]] = []
    for sdk in COMMAND_LINE_TOOLS_SDKS.glob("MacOSX*.sdk"):
        match = re.fullmatch(r"MacOSX(\d+(?:\.\d+)?)\.sdk", sdk.name)
        if not match:
            continue
        try:
            version = float(match.group(1))
        except ValueError:
            continue
        candidates.append((version, sdk))

    if not candidates:
        return None

    pre_beta_sdks = [(version, sdk) for version, sdk in candidates if version < 27]
    selected = max(pre_beta_sdks or candidates, key=lambda item: item[0])
    return selected[1]


def benchmark_command(
    case: BenchmarkCase,
    *,
    audio_path: Path | None,
    uses_system_audio: bool,
    source_language: str,
    target_language: str,
    mt_backend: str,
    duration_seconds: float,
    trace_path: Path,
    uses_asr_stabilization: bool,
    uses_punctuation_endpoint: bool,
    uses_speech_output: bool,
    tts_backend: str,
    tts_python_executable: str,
    tts_device: str,
    plays_output: bool,
    speech_output_dir: Path | None,
) -> list[str]:
    command = [
        str(DEMO_BINARY),
        "--real",
    ]
    if uses_system_audio:
        command.append("--system-audio")
    else:
        if audio_path is None:
            raise ValueError("audio_path is required for file-backed benchmarks")
        command.extend(["--audio", str(audio_path)])
    command.extend(
        [
            "--from",
            source_language,
            "--to",
            target_language,
            "--mt",
            mt_backend,
            "--asr",
            case.asr,
            "--latency",
            "balanced",
            "--chunk-duration",
            format_number(case.chunk_duration),
            "--max-buffered-segments",
            str(case.max_buffered_segments),
            "--duration",
            format_number(duration_seconds),
            "--trace",
            str(trace_path),
        ]
    )
    if uses_speech_output:
        command.extend(["--tts", tts_backend])
        if speech_output_dir is not None:
            command.extend(["--output-dir", str(speech_output_dir)])
        if plays_output:
            command.append("--play-output")
        if tts_backend in {"moss", "chatterbox", "chatterbox-mlx"}:
            script_name = {
                "moss": "moss_tts_nano_bridge.py",
                "chatterbox": "chatterbox_tts.py",
                "chatterbox-mlx": "chatterbox_mlx_tts.py",
            }[tts_backend]
            command.extend(
                [
                    "--tts-script",
                    str(REPO_ROOT / "Tools" / script_name),
                    "--tts-python",
                    tts_python_executable,
                ]
            )
            if tts_backend in {"chatterbox", "chatterbox-mlx"}:
                command.extend(
                    [
                        "--tts-device",
                        "mps" if tts_backend == "chatterbox-mlx" else tts_device,
                    ]
                )
    else:
        command.append("--text-only")
    if uses_asr_stabilization:
        command.append("--asr-stabilization")
    if uses_punctuation_endpoint:
        command.append("--punctuation-endpoint")
    return command


def format_number(value: float) -> str:
    if value.is_integer():
        return str(int(value))
    return f"{value:.3f}".rstrip("0").rstrip(".")


def make_report(
    *,
    output_dir: Path,
    audio_path: Path | None,
    uses_system_audio: bool,
    playback_audio_path: Path | None,
    playback_delay_seconds: float,
    playback_browser: str | None,
    playback_browser_profile_dir: Path | None,
    source_language: str,
    target_language: str,
    mt_backend: str,
    duration_seconds: float,
    cases: list[BenchmarkCase],
    results: list[RunResult],
    examples: int,
    compare_examples: int,
    last_examples: int,
    repeated_segments: int,
    uses_asr_stabilization: bool,
    uses_punctuation_endpoint: bool,
    uses_speech_output: bool,
    tts_backend: str,
    tts_python_executable: str,
    tts_device: str,
    plays_output: bool,
    minimum_outputs: int,
) -> Path:
    report_path = output_dir / "report.md"
    summary = ""
    summarizable = [result for result in results if result.trace_path.exists()]
    if summarizable:
        summary_command = [
            sys.executable,
            str(TRACE_SUMMARY),
            *[f"{result.case.label}={result.trace_path}" for result in summarizable],
            "--examples",
            str(examples),
            "--compare-examples",
            str(compare_examples),
            "--last-examples",
            str(last_examples),
            "--repeated-segments",
            str(repeated_segments),
        ]
        completed = subprocess.run(
            summary_command,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if completed.returncode == 0:
            summary = completed.stdout.strip()
        else:
            summary = "Trace summary failed.\n\n```text\n" + completed.stderr.strip() + "\n```"

    lines = [
        "# Live Translation Benchmark Run",
        "",
        f"Date: {datetime.now().isoformat(timespec='seconds')}",
        f"Commit: {git_commit()}",
        f"Source: `{source_description(audio_path, uses_system_audio)}`",
        f"Source language: `{source_language}`",
        f"Target language: `{target_language}`",
        f"Translation: `{mt_backend}`",
        f"Output mode: `{'speech' if uses_speech_output else 'text'}`",
        f"Duration: `{format_number(duration_seconds)}s`",
        f"Output directory: `{output_dir}`",
    ]
    if uses_speech_output:
        lines.extend(
            [
                f"TTS: `{tts_backend}`",
                f"Speaker playback: `{'on' if plays_output else 'off'}`",
            ]
        )
    if playback_audio_path is not None:
        lines.extend(
            [
                f"Playback audio: `{playback_audio_path}`",
                f"Playback delay: `{format_number(playback_delay_seconds)}s`",
            ]
        )
        if playback_browser is not None:
            lines.append(f"Playback browser: `{playback_browser}`")
    if minimum_outputs > 0:
        lines.append(f"Minimum outputs: `{minimum_outputs}`")
    lines.append(f"Punctuation endpoint: `{'on' if uses_punctuation_endpoint else 'off'}`")
    lines.extend(
        [
            "",
            "## Cases",
            "",
            "| Label | ASR | Chunk | Buffer | Status | Trace | Log |",
            "| --- | --- | ---: | ---: | --- | --- | --- |",
        ]
    )

    result_by_label = {result.case.label: result for result in results}
    for case in cases:
        result = result_by_label.get(case.label)
        if result is None:
            status = "not run"
            trace = ""
            log = ""
        else:
            status = "ok" if result.succeeded else f"failed ({result.return_code})"
            trace = f"`{result.trace_path}`"
            log = f"`{result.log_path}`"
        lines.append(
            "| {label} | {asr} | {chunk} | {buffer} | {status} | {trace} | {log} |".format(
                label=case.label,
                asr=case.asr,
                chunk=format_number(case.chunk_duration),
                buffer=case.max_buffered_segments,
                status=status,
                trace=trace,
                log=log,
            )
        )

    if summary:
        lines.extend(["", "## Summary", "", summary])

    lines.extend(
        [
            "",
            "## Commands",
            "",
        ]
    )
    for result in results:
        lines.extend(
            [
                f"### {result.case.label}",
                "",
                "```bash",
                *playback_command_lines(
                    playback_audio_path,
                    playback_delay_seconds,
                    browser=playback_browser,
                    browser_profile_dir=playback_browser_profile_dir,
                ),
                " ".join(
                    benchmark_command(
                        result.case,
                        audio_path=audio_path,
                        uses_system_audio=uses_system_audio,
                        source_language=source_language,
                        target_language=target_language,
                        mt_backend=mt_backend,
                        duration_seconds=duration_seconds,
                        trace_path=result.trace_path,
                        uses_asr_stabilization=uses_asr_stabilization,
                        uses_punctuation_endpoint=uses_punctuation_endpoint,
                        uses_speech_output=uses_speech_output,
                        tts_backend=tts_backend,
                        tts_python_executable=tts_python_executable,
                        tts_device=tts_device,
                        plays_output=plays_output,
                        speech_output_dir=(output_dir / "audio" / result.case.slug)
                        if uses_speech_output
                        else None,
                    )
                ),
                "```",
                "",
            ]
        )

    report_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return report_path


def source_description(audio_path: Path | None, uses_system_audio: bool) -> str:
    if uses_system_audio:
        return "macOS system audio"
    return str(audio_path) if audio_path is not None else "audio file"


def playback_command_lines(
    audio_path: Path | None,
    delay_seconds: float,
    *,
    browser: str | None,
    browser_profile_dir: Path | None,
) -> list[str]:
    if audio_path is None:
        return []
    return [
        "# playback starts after the demo reports that system-audio capture began",
        printable_playback_command(
            audio_path,
            delay_seconds,
            browser=browser,
            browser_profile_dir=browser_profile_dir,
        ),
    ]


def count_trace_events(path: Path, event_name: str) -> int:
    count = 0
    if not path.exists():
        return count
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                item = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if item.get("event") == event_name:
                count += 1
    return count


def validate_trace_expectations(
    trace_path: Path,
    *,
    log_path: Path,
    output_event_name: str,
    minimum_outputs: int,
    requires_playback: bool,
) -> int:
    if minimum_outputs <= 0:
        return 0

    output_count = count_trace_events(trace_path, output_event_name)
    if output_count < minimum_outputs:
        message = (
            "validation failed: expected at least "
            f"{minimum_outputs} {output_event_name} event(s), found {output_count}"
        )
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(f"\n{message}\n")
        return 90

    if requires_playback:
        playback_count = count_trace_events(trace_path, "playback_completed")
        if playback_count < minimum_outputs:
            message = (
                "validation failed: expected at least "
                f"{minimum_outputs} playback_completed event(s), found {playback_count}"
            )
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write(f"\n{message}\n")
            return 91

    return 0


def git_commit() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return "unknown"
    return completed.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run repeatable local Heptapod live translation benchmarks."
    )
    parser.add_argument(
        "--audio",
        type=Path,
        help="Input audio file for file-backed benchmarks. WAV, M4A, MP3, or CAF are expected.",
    )
    parser.add_argument(
        "--system-audio",
        action="store_true",
        help="Capture macOS system audio instead of streaming --audio directly.",
    )
    parser.add_argument(
        "--playback-audio",
        type=Path,
        help="Optional local audio file to play during --system-audio benchmarks.",
    )
    parser.add_argument(
        "--playback-browser",
        choices=["chrome"],
        help="Play --playback-audio from a visible browser instead of afplay.",
    )
    parser.add_argument(
        "--playback-delay",
        type=float,
        default=3.0,
        help="Seconds to wait before starting --playback-audio after capture begins.",
    )
    parser.add_argument("--from", dest="source_language", default="en", help="Source language code.")
    parser.add_argument("--to", default="tr", help="Target language code.")
    parser.add_argument(
        "--mt",
        choices=["madlad", "apple"],
        default="madlad",
        help="Translation backend. Apple requires installed system language assets.",
    )
    parser.add_argument("--duration", type=float, default=60.0, help="Seconds to process.")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("/tmp/heptapod-live-benchmarks") / datetime.now().strftime("%Y%m%d-%H%M%S"),
        help="Directory for traces, logs, and report.md.",
    )
    parser.add_argument(
        "--preset",
        choices=["quick", "matrix"],
        default="quick",
        help="Built-in benchmark case set. Ignored when --case is provided.",
    )
    parser.add_argument(
        "--case",
        action="append",
        type=parse_case,
        dest="cases",
        help="Custom case: label:asr:chunk_duration:max_buffered_segments.",
    )
    parser.add_argument("--examples", type=int, default=2, help="Examples per trace in report.")
    parser.add_argument(
        "--compare-examples",
        type=int,
        default=3,
        help="Side-by-side examples across traces in report.",
    )
    parser.add_argument(
        "--last-examples",
        type=int,
        default=2,
        help="Final translation examples per trace in report.",
    )
    parser.add_argument(
        "--repeated-segments",
        type=int,
        default=5,
        help="Repeated translation segment rows in report.",
    )
    parser.add_argument(
        "--asr-stabilization",
        action="store_true",
        help="Force sliding-window stable-prefix ASR buffering.",
    )
    parser.add_argument(
        "--punctuation-endpoint",
        action="store_true",
        help="Flush buffered speech as soon as ASR emits terminal punctuation.",
    )
    parser.add_argument(
        "--speech-output",
        action="store_true",
        help="Run MT plus TTS and write synthesized WAV segments instead of text-only output.",
    )
    parser.add_argument(
        "--tts",
        choices=["moss", "chatterbox-mlx", "apple", "kokoro", "chatterbox"],
        default="moss",
        help="TTS backend used with --speech-output. Defaults to streaming MOSS-TTS-Nano.",
    )
    parser.add_argument(
        "--tts-python",
        default=None,
        help="Python executable for a Python TTS backend. Defaults to its repository venv.",
    )
    parser.add_argument(
        "--tts-device",
        choices=["auto", "cpu", "mps", "cuda"],
        default="auto",
        help="Torch device used by Chatterbox.",
    )
    parser.add_argument(
        "--play-output",
        action="store_true",
        help="Play synthesized speech through the default audio output; requires --speech-output.",
    )
    parser.add_argument(
        "--min-outputs",
        "--min-translations",
        dest="min_outputs",
        type=int,
        default=None,
        help="Fail a case unless its trace contains at least this many output events. Defaults to 1 when --playback-audio is used, otherwise 0.",
    )
    parser.add_argument("--skip-build", action="store_true", help="Do not run swift build first.")
    parser.add_argument("--keep-going", action="store_true", help="Run remaining cases after a failure.")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without running them.")
    args = parser.parse_args()

    audio_path = args.audio.expanduser().resolve() if args.audio else None
    playback_audio_path = args.playback_audio.expanduser().resolve() if args.playback_audio else None
    output_dir = args.output_dir.expanduser().resolve()
    playback_browser_profile_dir = output_dir / "playback-browser-profile" if args.playback_browser else None
    tts_python_value = args.tts_python or {
        "moss": ".venv-moss-tts-nano/bin/python",
        "chatterbox-mlx": ".venv-chatterbox-mlx/bin/python",
        "chatterbox": ".venv-chatterbox311/bin/python",
    }.get(args.tts, "python3")
    tts_python_path = Path(tts_python_value).expanduser()
    tts_python_executable = (
        str(tts_python_path)
        if tts_python_path.is_absolute()
        else str((REPO_ROOT / tts_python_path).absolute())
        if tts_python_path.parent != Path(".")
        else tts_python_value
    )
    cases = args.cases or default_cases(args.preset)

    if args.duration <= 0:
        parser.error("--duration must be positive")
    if args.playback_delay < 0:
        parser.error("--playback-delay cannot be negative")
    if args.min_outputs is not None and args.min_outputs < 0:
        parser.error("--min-outputs cannot be negative")
    if args.play_output and not args.speech_output:
        parser.error("--play-output requires --speech-output")

    target_language = args.to.strip().lower().replace("_", "-").split("-", maxsplit=1)[0]
    if args.speech_output and args.tts == "kokoro" and target_language not in KOKORO_LANGUAGE_CODES:
        parser.error(
            f"Kokoro does not support target language '{args.to}'; use --tts moss or --tts chatterbox-mlx"
        )

    if args.system_audio:
        if audio_path is not None:
            parser.error("--audio is for file-backed benchmarks; use --playback-audio with --system-audio")
    elif audio_path is None:
        parser.error("--audio is required unless --system-audio is used")
    elif playback_audio_path is not None:
        parser.error("--playback-audio requires --system-audio")
    if args.playback_browser and playback_audio_path is None:
        parser.error("--playback-browser requires --playback-audio")

    minimum_outputs = (
        args.min_outputs
        if args.min_outputs is not None
        else (1 if playback_audio_path is not None else 0)
    )

    if not args.dry_run and audio_path is not None and not audio_path.exists():
        parser.error(f"audio file does not exist: {audio_path}")
    if not args.dry_run and playback_audio_path is not None and not playback_audio_path.exists():
        parser.error(f"playback audio file does not exist: {playback_audio_path}")
    if not args.dry_run and args.playback_browser == "chrome" and not GOOGLE_CHROME_BINARY.exists():
        parser.error(f"Google Chrome is required for --playback-browser chrome: {GOOGLE_CHROME_BINARY}")
    if not args.dry_run and args.playback_browser == "chrome" and not BROWSER_PLAYBACK_PAGE.exists():
        parser.error(f"browser playback page is missing: {BROWSER_PLAYBACK_PAGE}")
    if not args.dry_run and playback_audio_path is not None and args.playback_browser is None and shutil.which("afplay") is None:
        parser.error("afplay is required for --playback-audio")
    if not args.dry_run and args.speech_output and args.tts in {"moss", "chatterbox", "chatterbox-mlx"}:
        script_name = {
            "moss": "moss_tts_nano_bridge.py",
            "chatterbox": "chatterbox_tts.py",
            "chatterbox-mlx": "chatterbox_mlx_tts.py",
        }[args.tts]
        if not (REPO_ROOT / "Tools" / script_name).exists():
            parser.error(f"Tools/{script_name} is required for {args.tts}")
        if Path(tts_python_executable).is_absolute():
            if not Path(tts_python_executable).is_file():
                parser.error(f"TTS Python executable does not exist: {tts_python_executable}")
        elif shutil.which(tts_python_executable) is None:
            parser.error(f"TTS Python executable was not found: {tts_python_executable}")

    if not args.skip_build:
        build_command = ["swift", "build", "--product", DEMO_PRODUCT]
        build_status = run_command(
            build_command,
            dry_run=args.dry_run,
            env=swift_build_environment(),
        )
        if build_status != 0:
            return build_status
        metallib_status = build_mlx_metallib(dry_run=args.dry_run)
        if metallib_status != 0:
            return metallib_status

    results: list[RunResult] = []
    for case in cases:
        trace_path = output_dir / "traces" / f"{case.slug}.jsonl"
        log_path = output_dir / "logs" / f"{case.slug}.log"
        speech_output_dir = output_dir / "audio" / case.slug if args.speech_output else None
        command = benchmark_command(
            case,
            audio_path=audio_path,
            uses_system_audio=args.system_audio,
            source_language=args.source_language,
            target_language=args.to,
            mt_backend=args.mt,
            duration_seconds=args.duration,
            trace_path=trace_path,
            uses_asr_stabilization=args.asr_stabilization,
            uses_punctuation_endpoint=args.punctuation_endpoint,
            uses_speech_output=args.speech_output,
            tts_backend=args.tts,
            tts_python_executable=tts_python_executable,
            tts_device=args.tts_device,
            plays_output=args.play_output,
            speech_output_dir=speech_output_dir,
        )
        status = run_command(
            command,
            log_path=log_path,
            dry_run=args.dry_run,
            env=model_runtime_environment(),
            playback_audio_path=playback_audio_path,
            playback_delay_seconds=args.playback_delay,
            playback_browser=args.playback_browser,
            playback_browser_profile_dir=playback_browser_profile_dir,
        )
        if not args.dry_run and status == 0:
            status = validate_trace_expectations(
                trace_path,
                log_path=log_path,
                output_event_name="result_ready" if args.speech_output else "translation_ready",
                minimum_outputs=minimum_outputs,
                requires_playback=args.play_output,
            )
        results.append(RunResult(case, trace_path, log_path, status))
        if status != 0 and not args.keep_going:
            break

    if args.dry_run:
        return 0

    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = make_report(
        output_dir=output_dir,
        audio_path=audio_path,
        uses_system_audio=args.system_audio,
        playback_audio_path=playback_audio_path,
        playback_delay_seconds=args.playback_delay,
        playback_browser=args.playback_browser,
        playback_browser_profile_dir=playback_browser_profile_dir,
        source_language=args.source_language,
        target_language=args.to,
        mt_backend=args.mt,
        duration_seconds=args.duration,
        cases=cases,
        results=results,
        examples=args.examples,
        compare_examples=args.compare_examples,
        last_examples=args.last_examples,
        repeated_segments=args.repeated_segments,
        uses_asr_stabilization=args.asr_stabilization,
        uses_punctuation_endpoint=args.punctuation_endpoint,
        uses_speech_output=args.speech_output,
        tts_backend=args.tts,
        tts_python_executable=tts_python_executable,
        tts_device=args.tts_device,
        plays_output=args.play_output,
        minimum_outputs=minimum_outputs,
    )
    print(report_path)

    return 0 if all(result.succeeded for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
