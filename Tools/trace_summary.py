#!/usr/bin/env python3
"""Summarize Heptapod live JSONL traces as a Markdown table."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from statistics import mean


@dataclass(frozen=True)
class LatencyStats:
    count: int
    average: float | None
    minimum: float | None
    maximum: float | None

    @classmethod
    def from_values(cls, values: list[float]) -> "LatencyStats":
        if not values:
            return cls(count=0, average=None, minimum=None, maximum=None)
        return cls(
            count=len(values),
            average=mean(values),
            minimum=min(values),
            maximum=max(values),
        )


@dataclass(frozen=True)
class TranslationExample:
    index: int | None
    transcript: str
    translation: str


@dataclass(frozen=True)
class TraceSummary:
    label: str
    path: Path
    command: list[str]
    events: Counter[str]
    run_finished: bool
    elapsed_seconds: float | None
    transcript_latency: LatencyStats
    translation_latency: LatencyStats
    examples: list[TranslationExample]


def load_trace(path: Path, label: str | None = None) -> TraceSummary:
    events: Counter[str] = Counter()
    command: list[str] = []
    elapsed_seconds: float | None = None
    transcript_latencies: list[float] = []
    translation_latencies: list[float] = []
    examples: list[TranslationExample] = []
    run_finished = False

    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                item = json.loads(stripped)
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {error}") from error

            event = item.get("event")
            if not isinstance(event, str):
                continue

            events[event] += 1
            if event == "run_started":
                raw_command = item.get("command")
                if isinstance(raw_command, list):
                    command = [str(part) for part in raw_command]
            if event == "run_finished":
                run_finished = True
            raw_elapsed = item.get("elapsedSeconds")
            if isinstance(raw_elapsed, (int, float)):
                elapsed_seconds = float(raw_elapsed)

            raw_latency = item.get("resultLatencySeconds")
            if isinstance(raw_latency, (int, float)):
                if event == "transcript_ready":
                    transcript_latencies.append(float(raw_latency))
                elif event == "translation_ready":
                    translation_latencies.append(float(raw_latency))

            if event == "translation_ready":
                transcript = str(item.get("transcriptText", "")).strip()
                translation = str(item.get("translationText", "")).strip()
                examples.append(
                    TranslationExample(
                        index=item.get("index") if isinstance(item.get("index"), int) else None,
                        transcript=transcript,
                        translation=translation,
                    )
                )

    return TraceSummary(
        label=label or path.stem,
        path=path,
        command=command,
        events=events,
        run_finished=run_finished,
        elapsed_seconds=elapsed_seconds,
        transcript_latency=LatencyStats.from_values(transcript_latencies),
        translation_latency=LatencyStats.from_values(translation_latencies),
        examples=examples,
    )


def parse_trace_arg(value: str) -> tuple[str | None, Path]:
    if "=" not in value:
        return None, Path(value)
    label, path = value.split("=", 1)
    label = label.strip()
    if not label:
        raise argparse.ArgumentTypeError("trace label cannot be empty")
    return label, Path(path)


def format_seconds(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:.3f}s"


def first_command_arg(command: list[str], option: str) -> str:
    for index, part in enumerate(command):
        if part == option and index + 1 < len(command):
            return command[index + 1]
    return ""


def markdown_table(summaries: list[TraceSummary]) -> str:
    rows = [
        "| Trace | ASR | Chunk | Buffer | Segments | Transcripts | Translations | ASR avg | MT avg | Finished |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for summary in summaries:
        command = summary.command
        asr = first_command_arg(command, "--asr") or "default"
        chunk = first_command_arg(command, "--chunk-duration") or "n/a"
        buffer = first_command_arg(command, "--max-buffered-segments") or "n/a"
        rows.append(
            "| {label} | {asr} | {chunk} | {buffer} | {segments} | {transcripts} | "
            "{translations} | {asr_avg} | {mt_avg} | {finished} |".format(
                label=summary.label,
                asr=asr,
                chunk=chunk,
                buffer=buffer,
                segments=summary.events["segment_started"],
                transcripts=summary.events["transcript_ready"],
                translations=summary.events["translation_ready"],
                asr_avg=format_seconds(summary.transcript_latency.average),
                mt_avg=format_seconds(summary.translation_latency.average),
                finished="yes" if summary.run_finished else "no",
            )
        )
    return "\n".join(rows)


def markdown_examples(summary: TraceSummary, limit: int) -> str:
    if limit <= 0 or not summary.examples:
        return ""
    selected = summary.examples[:limit]
    lines = [f"### {summary.label}", ""]
    for example in selected:
        index = f"SEG {example.index}" if example.index is not None else "SEG ?"
        lines.extend(
            [
                f"{index}",
                "",
                "```text",
                f"ASR: {example.transcript}",
                f"MT:  {example.translation}",
                "```",
                "",
            ]
        )
    return "\n".join(lines).rstrip()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Summarize Heptapod JSONL trace files as Markdown."
    )
    parser.add_argument(
        "traces",
        nargs="+",
        type=parse_trace_arg,
        help="Trace file path or label=path.",
    )
    parser.add_argument(
        "--examples",
        type=int,
        default=0,
        help="Include the first N translation examples per trace.",
    )
    args = parser.parse_args()

    summaries = [load_trace(path, label=label) for label, path in args.traces]
    print(markdown_table(summaries))

    if args.examples > 0:
        print()
        print("## Examples")
        for summary in summaries:
            rendered = markdown_examples(summary, args.examples)
            if rendered:
                print()
                print(rendered)


if __name__ == "__main__":
    main()
