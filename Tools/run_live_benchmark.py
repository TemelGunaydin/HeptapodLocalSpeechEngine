#!/usr/bin/env python3
"""Run repeatable Heptapod live translation benchmark matrices."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
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
) -> int:
    printable = printable_command(command, env=env)
    if dry_run:
        print(printable)
        return 0

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
    audio_path: Path,
    target_language: str,
    duration_seconds: float,
    trace_path: Path,
    uses_asr_stabilization: bool,
) -> list[str]:
    command = [
        str(DEMO_BINARY),
        "--real",
        "--audio",
        str(audio_path),
        "--to",
        target_language,
        "--asr",
        case.asr,
        "--latency",
        "balanced",
        "--chunk-duration",
        format_number(case.chunk_duration),
        "--max-buffered-segments",
        str(case.max_buffered_segments),
        "--text-only",
        "--duration",
        format_number(duration_seconds),
        "--trace",
        str(trace_path),
    ]
    if uses_asr_stabilization:
        command.append("--asr-stabilization")
    return command


def format_number(value: float) -> str:
    if value.is_integer():
        return str(int(value))
    return f"{value:.3f}".rstrip("0").rstrip(".")


def make_report(
    *,
    output_dir: Path,
    audio_path: Path,
    target_language: str,
    duration_seconds: float,
    cases: list[BenchmarkCase],
    results: list[RunResult],
    examples: int,
    compare_examples: int,
    last_examples: int,
    repeated_segments: int,
    uses_asr_stabilization: bool,
) -> Path:
    report_path = output_dir / "report.md"
    summary = ""
    successful = [result for result in results if result.succeeded and result.trace_path.exists()]
    if successful:
        summary_command = [
            sys.executable,
            str(TRACE_SUMMARY),
            *[f"{result.case.label}={result.trace_path}" for result in successful],
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
        f"Audio: `{audio_path}`",
        f"Target language: `{target_language}`",
        f"Duration: `{format_number(duration_seconds)}s`",
        f"Output directory: `{output_dir}`",
        "",
        "## Cases",
        "",
        "| Label | ASR | Chunk | Buffer | Status | Trace | Log |",
        "| --- | --- | ---: | ---: | --- | --- | --- |",
    ]

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
                " ".join(
                    benchmark_command(
                        result.case,
                        audio_path=audio_path,
                        target_language=target_language,
                        duration_seconds=duration_seconds,
                        trace_path=result.trace_path,
                        uses_asr_stabilization=uses_asr_stabilization,
                    )
                ),
                "```",
                "",
            ]
        )

    report_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return report_path


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
        required=True,
        type=Path,
        help="Input audio file readable by the local audio runtime, such as WAV, M4A, MP3, or CAF.",
    )
    parser.add_argument("--to", default="tr", help="Target language code.")
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
        help="Force sliding-window stable-prefix ASR buffering in text-only benchmark runs.",
    )
    parser.add_argument("--skip-build", action="store_true", help="Do not run swift build first.")
    parser.add_argument("--keep-going", action="store_true", help="Run remaining cases after a failure.")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without running them.")
    args = parser.parse_args()

    audio_path = args.audio.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    cases = args.cases or default_cases(args.preset)

    if args.duration <= 0:
        parser.error("--duration must be positive")

    if not args.dry_run and not audio_path.exists():
        parser.error(f"audio file does not exist: {audio_path}")

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
        command = benchmark_command(
            case,
            audio_path=audio_path,
            target_language=args.to,
            duration_seconds=args.duration,
            trace_path=trace_path,
            uses_asr_stabilization=args.asr_stabilization,
        )
        status = run_command(
            command,
            log_path=log_path,
            dry_run=args.dry_run,
            env=model_runtime_environment(),
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
        target_language=args.to,
        duration_seconds=args.duration,
        cases=cases,
        results=results,
        examples=args.examples,
        compare_examples=args.compare_examples,
        last_examples=args.last_examples,
        repeated_segments=args.repeated_segments,
        uses_asr_stabilization=args.asr_stabilization,
    )
    print(report_path)

    return 0 if all(result.succeeded for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
