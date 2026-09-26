# Translation / Synthesis Overlap: English to Turkish

Date: 2026-09-26

## Change

The sentence-buffered session previously waited for each segment's complete
TTS output before starting the next translation. It now has separate serial MT
and TTS workers and one prepared-translation slot. MT can prepare the next
segment during current TTS generation, without concurrent calls to the same
model, reordering accepted transcripts, or discarding queued segments.

The trace now records the prepared translation's wait in `synthesis_started`
as `queueWaitSeconds`; `trace_summary.py` reports it as `TTS queue avg`.
Older traces report this field as unavailable, not zero.

## Measurement

- Baseline: commit `91943a0`, combined MT/TTS worker.
- Candidate: local changes adding the prepared-translation slot.
- Source: first 15 seconds of the existing repeated-sentence `stress.wav` fixture.
- Full fixture SHA-256: `e1d4ba094a93a206709ccdafba35e088609c9efb06162a2f1bbb3197ef4deba5`.
- Models: Qwen3 ASR 0.6B 4-bit, Apple Translation with glossary, MOSS-TTS-Nano.
- Timing: balanced preset, 1-second input chunks, three-segment safety flush.
- Execution: XcodeBuildMCP `swift-package run`, cached models, `HF_HUB_OFFLINE=1`.
- Output: WAV sink only. No speaker playback, microphone, or system audio capture.
- One before/after run; model generation, contention, and cold-start variation
  are not controlled. This is a functional smoke comparison, not a speed guarantee.

| Metric | Before | After |
| --- | ---: | ---: |
| Input chunks | 15 | 15 |
| Accepted transcripts / results / WAV files | 5 / 5 / 5 | 5 / 5 / 5 |
| Repeated output indexes | 0 | 0 |
| Average ASR duration | 0.231 s | 0.338 s |
| Average wait before MT | 0.617 s | 0.000 s |
| Average MT duration | 1.079 s | 1.065 s |
| Average first generated audio after accepted transcript | 1.873 s | 1.401 s |
| Average wait from MT completion to TTS start | not recorded | 0.094 s |
| Average TTS generation duration | 1.295 s | 1.588 s |
| Average complete output after accepted transcript | 2.991 s | 2.747 s |
| Run duration after preparation | 16.638 s | 17.073 s |
| Total generated audio duration | 20.320 s | 20.320 s |
| Clean finish | yes | yes |

Both runs produced identical ordered ASR and translation text. All five WAV
files were readable, mono, 48 kHz, with matching frame counts between runs.
This checks segment preservation, not waveform identity or recognition accuracy.

Actual overlap is visible in the candidate trace: segment 7's translation
finished at 7.387 s, before segment 4's complete TTS result at 7.761 s. In the
baseline, segment 7's translation did not start until 8.165 s, after segment 4's
TTS result at 8.165 s. Segment 9 also translated during the preceding synthesis.

First-audio and average output latency improved in this short run, but full run
duration and some model-stage timings worsened. Do not extrapolate a universal
throughput improvement from these two runs.

## Lossless Boundaries

The accepted queue is not shortened or replaced to catch up. Tests cover 128
ordered segments in speech and text-only modes, one-slot translation lookahead,
slow playback with a one-segment playback limit, and cancellation/failure while
both MT and TTS are active. Normal input completion drains both stages.

This is not a claim of error-free ASR/translation, bounded memory during arbitrary
overload, or recovery after process failure. Pending input text and PCM relays
still require a separate end-to-end buffering policy.

The fixture produces 20.32 seconds of target speech from 15 seconds of input.
Even at the current 1.15x playback cap, that is about 17.67 seconds of playback.
Repeated speech with this ratio cannot stay at fixed lag indefinitely without
another intervention. Faster inference alone cannot solve output-duration drift.

## Reproduction

Run the cached local fixture through `HeptapodLiveSpeechDemo` with these arguments,
using XcodeBuildMCP `swift-package run --json` to pass the argument array:

```text
--real --audio /path/to/stress.wav --from en --to tr
--mt apple --tts moss --asr compact --latency balanced
--duration 15 --max-buffered-segments 3
--trace /tmp/run.jsonl --output-dir /tmp/run-audio
```

Summarize the before/after traces:

```bash
python3 Tools/trace_summary.py before=/tmp/before.jsonl after=/tmp/after.jsonl --compare-examples 5
```

Raw local artifacts for this measurement are in
`/private/tmp/heptapod-overlap.YXC41J`; they are not repository fixtures.
