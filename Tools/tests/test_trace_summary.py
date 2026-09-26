#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import trace_summary  # noqa: E402


class TraceSummaryFirstAudioTests(unittest.TestCase):
    def load(self, events: list[dict[str, object]]) -> trace_summary.TraceSummary:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "trace.jsonl"
            path.write_text(
                "".join(json.dumps(event) + "\n" for event in events),
                encoding="utf-8",
            )
            return trace_summary.load_trace(path)

    def test_explicit_first_audio_is_not_averaged_with_playback_start(self) -> None:
        summary = self.load(
            [
                {"event": "tts_first_audio", "firstAudioLatencySeconds": 1.4},
                {"event": "playback_started", "playbackLatencySeconds": 0.01},
            ]
        )

        self.assertEqual(summary.playback_start_latency.count, 1)
        self.assertAlmostEqual(summary.playback_start_latency.average or 0, 1.4)

    def test_prototype_first_audio_field_remains_supported(self) -> None:
        summary = self.load(
            [
                {
                    "event": "playback_started",
                    "firstAudioLatencySeconds": 0.75,
                    "playbackLatencySeconds": 0.02,
                }
            ]
        )

        self.assertAlmostEqual(summary.playback_start_latency.average or 0, 0.75)

    def test_playback_latency_is_used_only_as_legacy_fallback(self) -> None:
        summary = self.load(
            [{"event": "playback_started", "playbackLatencySeconds": 0.2}]
        )

        self.assertAlmostEqual(summary.playback_start_latency.average or 0, 0.2)

    def test_stage_timings_and_queue_backlogs_are_summarized(self) -> None:
        summary = self.load(
            [
                {"event": "output_queued", "backlogSegments": 2},
                {"event": "translation_started", "queueWaitSeconds": 0.3},
                {"event": "translation_completed", "stageDurationSeconds": 0.4},
                {"event": "synthesis_started", "queueWaitSeconds": 0.15},
                {
                    "event": "tts_first_audio",
                    "firstAudioLatencySeconds": 1.1,
                    "stageDurationSeconds": 0.7,
                },
                {"event": "result_ready", "stageDurationSeconds": 1.4},
                {"event": "playback_queued", "backlogSegments": 3},
                {"event": "playback_started", "queueWaitSeconds": 0.2},
            ]
        )

        self.assertAlmostEqual(summary.output_queue_wait_latency.average or 0, 0.3)
        self.assertAlmostEqual(summary.translation_stage_latency.average or 0, 0.4)
        self.assertAlmostEqual(summary.synthesis_queue_wait_latency.average or 0, 0.15)
        self.assertAlmostEqual(summary.synthesis_first_audio_latency.average or 0, 0.7)
        self.assertAlmostEqual(summary.synthesis_stage_latency.average or 0, 1.4)
        self.assertAlmostEqual(summary.playback_queue_wait_latency.average or 0, 0.2)
        self.assertEqual(summary.peak_output_backlog, 2)
        self.assertEqual(summary.peak_playback_backlog, 3)

    def test_legacy_trace_does_not_invent_synthesis_queue_wait(self) -> None:
        summary = self.load([{"event": "synthesis_started"}])

        self.assertEqual(summary.synthesis_queue_wait_latency.count, 0)
        self.assertIsNone(summary.synthesis_queue_wait_latency.average)
        self.assertIn("TTS queue avg", trace_summary.markdown_table([summary]))
        self.assertIsNone(summary.peak_pending_audio_seconds)
        self.assertIsNone(summary.peak_playback_rate)
        self.assertIsNone(summary.completed_audio_seconds)

    def test_playback_audio_metrics_keep_peaks_after_drain(self) -> None:
        summary = self.load(
            [
                {
                    "event": "playback_state",
                    "pendingAudioDurationSeconds": 8.5,
                    "peakPendingAudioDurationSeconds": 10,
                    "peakPlaybackRate": 1.15,
                    "completedAudioDurationSeconds": 3,
                },
                {
                    "event": "playback_state",
                    "pendingAudioDurationSeconds": 0,
                    "peakPendingAudioDurationSeconds": 10,
                    "playbackRate": 1,
                    "peakPlaybackRate": 1.15,
                    "completedAudioDurationSeconds": 20.32,
                },
            ]
        )

        self.assertEqual(summary.peak_pending_audio_seconds, 10)
        self.assertAlmostEqual(summary.peak_playback_rate or 0, 1.15)
        self.assertAlmostEqual(summary.completed_audio_seconds or 0, 20.32)
        table = trace_summary.markdown_table([summary])
        self.assertIn("Pending audio peak", table)
        self.assertIn("1.150x", table)
        self.assertIn("20.320s", table)
        self.assertEqual(len(table.splitlines()[0].split("|")), len(table.splitlines()[2].split("|")))


if __name__ == "__main__":
    unittest.main()
