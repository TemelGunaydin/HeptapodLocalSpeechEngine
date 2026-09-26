#!/usr/bin/env python3
"""Summarize Heptapod live JSONL traces as a Markdown table."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from statistics import mean


OUTPUT_READY_EVENTS = {"translation_ready", "result_ready"}


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
class RepeatedTranslationSegment:
    index: int
    examples: list[TranslationExample]


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
    output_queue_wait_latency: LatencyStats
    translation_stage_latency: LatencyStats
    synthesis_queue_wait_latency: LatencyStats
    synthesis_first_audio_latency: LatencyStats
    synthesis_stage_latency: LatencyStats
    playback_queue_wait_latency: LatencyStats
    playback_start_latency: LatencyStats
    playback_latency: LatencyStats
    peak_output_backlog: int
    peak_playback_backlog: int
    peak_pending_audio_seconds: float | None
    peak_playback_rate: float | None
    completed_audio_seconds: float | None
    audio_rms: LatencyStats
    audio_peak: LatencyStats
    examples: list[TranslationExample]
    repeated_translation_segments: list[RepeatedTranslationSegment]


def load_trace(path: Path, label: str | None = None) -> TraceSummary:
    events: Counter[str] = Counter()
    command: list[str] = []
    elapsed_seconds: float | None = None
    transcript_latencies: list[float] = []
    translation_latencies: list[float] = []
    output_queue_wait_latencies: list[float] = []
    translation_stage_latencies: list[float] = []
    synthesis_queue_wait_latencies: list[float] = []
    synthesis_first_audio_latencies: list[float] = []
    synthesis_stage_latencies: list[float] = []
    playback_queue_wait_latencies: list[float] = []
    first_audio_latencies: list[float] = []
    playback_start_fallback_latencies: list[float] = []
    playback_latencies: list[float] = []
    audio_rms_values: list[float] = []
    audio_peak_values: list[float] = []
    examples: list[TranslationExample] = []
    examples_by_index: dict[int, list[TranslationExample]] = defaultdict(list)
    peak_output_backlog = 0
    peak_playback_backlog = 0
    peak_pending_audio_seconds: float | None = None
    peak_playback_rate: float | None = None
    completed_audio_seconds: float | None = None
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

            if event in OUTPUT_READY_EVENTS:
                raw_output_latency = item.get("outputLatencySeconds")
                if isinstance(raw_output_latency, (int, float)):
                    translation_latencies.append(float(raw_output_latency))
                elif isinstance(raw_latency, (int, float)):
                    translation_latencies.append(float(raw_latency))

            raw_queue_wait = item.get("queueWaitSeconds")
            if isinstance(raw_queue_wait, (int, float)):
                if event == "translation_started":
                    output_queue_wait_latencies.append(float(raw_queue_wait))
                elif event == "synthesis_started":
                    synthesis_queue_wait_latencies.append(float(raw_queue_wait))
                elif event == "playback_started":
                    playback_queue_wait_latencies.append(float(raw_queue_wait))

            raw_stage_duration = item.get("stageDurationSeconds")
            if isinstance(raw_stage_duration, (int, float)):
                if event == "translation_completed":
                    translation_stage_latencies.append(float(raw_stage_duration))
                elif event == "tts_first_audio":
                    synthesis_first_audio_latencies.append(float(raw_stage_duration))
                elif event == "result_ready":
                    synthesis_stage_latencies.append(float(raw_stage_duration))

            raw_backlog = item.get("backlogSegments")
            if isinstance(raw_backlog, int):
                if event == "output_queued":
                    peak_output_backlog = max(peak_output_backlog, raw_backlog)
                elif event == "playback_queued":
                    peak_playback_backlog = max(peak_playback_backlog, raw_backlog)

            if event == "playback_state":
                raw_peak_audio = item.get("peakPendingAudioDurationSeconds")
                raw_peak_rate = item.get("peakPlaybackRate")
                raw_completed_audio = item.get("completedAudioDurationSeconds")
                if isinstance(raw_peak_audio, (int, float)):
                    peak_pending_audio_seconds = max(peak_pending_audio_seconds or 0, float(raw_peak_audio))
                if isinstance(raw_peak_rate, (int, float)):
                    peak_playback_rate = max(peak_playback_rate or 0, float(raw_peak_rate))
                if isinstance(raw_completed_audio, (int, float)):
                    completed_audio_seconds = float(raw_completed_audio)

            raw_playback_latency = item.get("playbackLatencySeconds")
            raw_first_audio_latency = item.get("firstAudioLatencySeconds")
            if event == "tts_first_audio":
                if isinstance(raw_first_audio_latency, (int, float)):
                    first_audio_latencies.append(float(raw_first_audio_latency))
            elif event == "playback_started" and isinstance(raw_first_audio_latency, (int, float)):
                # Compatibility with traces written during the streaming-TTS prototype.
                first_audio_latencies.append(float(raw_first_audio_latency))
            elif event == "playback_started" and isinstance(raw_playback_latency, (int, float)):
                playback_start_fallback_latencies.append(float(raw_playback_latency))
            if event == "playback_completed":
                raw_playback_duration = item.get("playbackDurationSeconds")
                if isinstance(raw_playback_duration, (int, float)):
                    playback_latencies.append(float(raw_playback_duration))
                elif isinstance(raw_playback_latency, (int, float)):
                    playback_latencies.append(float(raw_playback_latency))

            if event == "audio_level":
                raw_rms = item.get("audioRMS")
                raw_peak = item.get("audioPeak")
                if isinstance(raw_rms, (int, float)):
                    audio_rms_values.append(float(raw_rms))
                if isinstance(raw_peak, (int, float)):
                    audio_peak_values.append(float(raw_peak))

            if event in OUTPUT_READY_EVENTS:
                transcript = str(item.get("transcriptText", "")).strip()
                translation = str(item.get("translationText", "")).strip()
                example = TranslationExample(
                    index=item.get("index") if isinstance(item.get("index"), int) else None,
                    transcript=transcript,
                    translation=translation,
                )
                examples.append(example)
                if example.index is not None:
                    examples_by_index[example.index].append(example)

    repeated_translation_segments = [
        RepeatedTranslationSegment(index=index, examples=index_examples)
        for index, index_examples in sorted(examples_by_index.items())
        if len(index_examples) > 1
    ]

    return TraceSummary(
        label=label or path.stem,
        path=path,
        command=command,
        events=events,
        run_finished=run_finished,
        elapsed_seconds=elapsed_seconds,
        transcript_latency=LatencyStats.from_values(transcript_latencies),
        translation_latency=LatencyStats.from_values(translation_latencies),
        output_queue_wait_latency=LatencyStats.from_values(output_queue_wait_latencies),
        translation_stage_latency=LatencyStats.from_values(translation_stage_latencies),
        synthesis_queue_wait_latency=LatencyStats.from_values(synthesis_queue_wait_latencies),
        synthesis_first_audio_latency=LatencyStats.from_values(synthesis_first_audio_latencies),
        synthesis_stage_latency=LatencyStats.from_values(synthesis_stage_latencies),
        playback_queue_wait_latency=LatencyStats.from_values(playback_queue_wait_latencies),
        playback_start_latency=LatencyStats.from_values(
            first_audio_latencies or playback_start_fallback_latencies
        ),
        playback_latency=LatencyStats.from_values(playback_latencies),
        peak_output_backlog=peak_output_backlog,
        peak_playback_backlog=peak_playback_backlog,
        peak_pending_audio_seconds=peak_pending_audio_seconds,
        peak_playback_rate=peak_playback_rate,
        completed_audio_seconds=completed_audio_seconds,
        audio_rms=LatencyStats.from_values(audio_rms_values),
        audio_peak=LatencyStats.from_values(audio_peak_values),
        examples=examples,
        repeated_translation_segments=repeated_translation_segments,
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


def format_level(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:.4f}"


def format_repeated_translation_count(summary: TraceSummary) -> str:
    repeated_segments = len(summary.repeated_translation_segments)
    if repeated_segments == 0:
        return "0"
    repeated_events = sum(len(segment.examples) for segment in summary.repeated_translation_segments)
    return f"{repeated_segments} seg / {repeated_events} MT"


def first_command_arg(command: list[str], option: str) -> str:
    for index, part in enumerate(command):
        if part == option and index + 1 < len(command):
            return command[index + 1]
    return ""


def markdown_table(summaries: list[TraceSummary]) -> str:
    rows = [
        "| Trace | ASR | Chunk | Buffer | Segments | Audio RMS | Audio Peak | Transcripts | Outputs | Repeated MT | ASR avg | Output queue avg | MT avg | Output avg | Playbacks | First audio avg | TTS queue avg | TTS first avg | TTS full avg | Playback queue avg | Peak queues | Pending audio peak | Rate peak | Played PCM | Duration avg | Finished |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- |",
    ]
    for summary in summaries:
        command = summary.command
        asr = first_command_arg(command, "--asr") or "default"
        chunk = first_command_arg(command, "--chunk-duration") or "n/a"
        buffer = first_command_arg(command, "--max-buffered-segments") or "n/a"
        rows.append(
            "| {label} | {asr} | {chunk} | {buffer} | {segments} | {audio_rms} | "
                "{audio_peak} | {transcripts} | {translations} | {repeated_translations} | "
                "{asr_avg} | {output_queue_avg} | {translation_stage_avg} | {mt_avg} | "
                "{playbacks} | {playback_start_avg} | {synthesis_queue_avg} | {synthesis_first_avg} | {synthesis_avg} | "
                "{playback_queue_avg} | "
                "{peak_queues} | {pending_audio_peak} | {rate_peak} | {played_pcm} | {playback_avg} | {finished} |".format(
                label=summary.label,
                asr=asr,
                chunk=chunk,
                buffer=buffer,
                segments=summary.events["segment_started"],
                audio_rms=format_level(summary.audio_rms.average),
                audio_peak=format_level(summary.audio_peak.maximum),
                transcripts=summary.events["transcript_ready"],
                translations=sum(summary.events[event] for event in OUTPUT_READY_EVENTS),
                repeated_translations=format_repeated_translation_count(summary),
                asr_avg=format_seconds(summary.transcript_latency.average),
                output_queue_avg=format_seconds(summary.output_queue_wait_latency.average),
                translation_stage_avg=format_seconds(summary.translation_stage_latency.average),
                mt_avg=format_seconds(summary.translation_latency.average),
                playbacks=summary.events["playback_completed"],
                playback_start_avg=format_seconds(summary.playback_start_latency.average),
                synthesis_queue_avg=format_seconds(summary.synthesis_queue_wait_latency.average),
                synthesis_first_avg=format_seconds(summary.synthesis_first_audio_latency.average),
                synthesis_avg=format_seconds(summary.synthesis_stage_latency.average),
                playback_queue_avg=format_seconds(summary.playback_queue_wait_latency.average),
                peak_queues=f"{summary.peak_output_backlog}/{summary.peak_playback_backlog}",
                pending_audio_peak=format_seconds(summary.peak_pending_audio_seconds),
                rate_peak=f"{summary.peak_playback_rate:.3f}x" if summary.peak_playback_rate is not None else "n/a",
                played_pcm=format_seconds(summary.completed_audio_seconds),
                playback_avg=format_seconds(summary.playback_latency.average),
                finished="yes" if summary.run_finished else "no",
            )
        )
    return "\n".join(rows)


def markdown_examples(summary: TraceSummary, limit: int, *, from_end: bool = False) -> str:
    if limit <= 0 or not summary.examples:
        return ""
    selected = summary.examples[-limit:] if from_end else summary.examples[:limit]
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


def markdown_cell(value: object) -> str:
    return str(value).replace("\n", " ").replace("|", r"\|").strip()


def markdown_side_by_side_examples(summaries: list[TraceSummary], limit: int) -> str:
    if limit <= 0:
        return ""

    example_count = min(limit, max((len(summary.examples) for summary in summaries), default=0))
    if example_count == 0:
        return ""

    sections: list[str] = []
    for example_index in range(example_count):
        sections.extend(
            [
                f"### Translation {example_index + 1}",
                "",
                "| Trace | Segment | ASR | MT |",
                "| --- | ---: | --- | --- |",
            ]
        )
        for summary in summaries:
            if example_index >= len(summary.examples):
                sections.append(f"| {markdown_cell(summary.label)} | n/a | n/a | n/a |")
                continue

            example = summary.examples[example_index]
            segment = example.index if example.index is not None else "?"
            sections.append(
                "| {label} | {segment} | {transcript} | {translation} |".format(
                    label=markdown_cell(summary.label),
                    segment=segment,
                    transcript=markdown_cell(example.transcript),
                    translation=markdown_cell(example.translation),
                )
            )
        sections.append("")

    return "\n".join(sections).rstrip()


def markdown_repeated_translation_segments(summaries: list[TraceSummary], limit: int) -> str:
    if limit <= 0:
        return ""

    rows: list[str] = [
        "| Trace | Segment | Count | First MT | Last MT |",
        "| --- | ---: | ---: | --- | --- |",
    ]
    remaining = limit
    for summary in summaries:
        for segment in summary.repeated_translation_segments:
            if remaining <= 0:
                break
            rows.append(
                "| {label} | {segment} | {count} | {first_translation} | {last_translation} |".format(
                    label=markdown_cell(summary.label),
                    segment=segment.index,
                    count=len(segment.examples),
                    first_translation=markdown_cell(segment.examples[0].translation),
                    last_translation=markdown_cell(segment.examples[-1].translation),
                )
            )
            remaining -= 1
        if remaining <= 0:
            break

    if len(rows) == 2:
        return ""
    return "\n".join(rows)


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
    parser.add_argument(
        "--compare-examples",
        type=int,
        default=0,
        help="Include the first N translation examples side by side across traces.",
    )
    parser.add_argument(
        "--last-examples",
        type=int,
        default=0,
        help="Include the last N translation examples per trace.",
    )
    parser.add_argument(
        "--repeated-segments",
        type=int,
        default=0,
        help="Include up to N segment indexes that emitted translation more than once.",
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

    if args.compare_examples > 0:
        rendered = markdown_side_by_side_examples(summaries, args.compare_examples)
        if rendered:
            print()
            print("## Side-By-Side Examples")
            print()
            print(rendered)

    if args.last_examples > 0:
        print()
        print("## Last Examples")
        for summary in summaries:
            rendered = markdown_examples(summary, args.last_examples, from_end=True)
            if rendered:
                print()
                print(rendered)

    if args.repeated_segments > 0:
        rendered = markdown_repeated_translation_segments(summaries, args.repeated_segments)
        if rendered:
            print()
            print("## Repeated Segment Translations")
            print()
            print(rendered)


if __name__ == "__main__":
    main()
