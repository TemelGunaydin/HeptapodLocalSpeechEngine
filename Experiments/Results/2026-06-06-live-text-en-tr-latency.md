# Live Text EN->TR Latency and Segmentation Benchmark

Date: 2026-06-06

## Environment

- Device: local Apple Silicon Mac
- Runtime: SwiftPM debug build
- Mode: text-only live translation
- Source language: English
- Target language: Turkish
- Trace files: local `/tmp/heptapod-*.jsonl` files, not committed

## Models

| Stage | Model |
| --- | --- |
| VAD | `aufklarer/Silero-VAD-v5-CoreML` |
| ASR | `aufklarer/Qwen3-ASR-0.6B-MLX-4bit`, `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` |
| Translation | `aufklarer/MADLAD400-3B-MT-MLX` |
| TTS | off |

## Baseline Command

```bash
swift run HeptapodLiveSpeechDemo -- \
  --real \
  --system-audio \
  --to tr \
  --latency balanced \
  --chunk-duration 1.0 \
  --max-buffered-segments 3 \
  --text-only \
  --duration 60 \
  --trace /tmp/heptapod-system-text-v8.jsonl
```

## Trace Summary

| Trace | Source | Chunk | Buffer | Segments | Transcripts | Translations | ASR avg | MT avg | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `v4` | system audio | 1.0s | 3 | 60 | 59 | 20 | 0.104s | 0.692s | Best early baseline after disabling text-only ASR stabilization. |
| `v6` | system audio | 1.2s | 2 | 50 | 48 | 24 | 0.114s | 0.631s | More frequent MT, but less context and worse translation quality. |
| `v7` | system audio | 1.2s | 3 | 50 | 50 | 17 | 0.109s | 0.785s | More context, but fewer translations and no clear quality gain. |
| `v8` | system audio | 1.0s | 3 | 60 | 59 | 19 | 0.088s | 0.701s | Best current system-audio balance after incomplete-tail carry. |
| `v9` | system audio | 1.0s | 3 | 60 | 59 | 18 | 0.101s | 0.801s | Exposed more continuation-tail edge cases. |
| `audio-test-1` | WAV file | 1.0s | 3 | 512 | 507 | 105 | 0.151s | 19.163s | Broken file test: `--duration` was ignored and chunks were not throttled. |
| `audio-test-2` | WAV file | 1.0s | 3 | 60 | 59 | 20 | 0.105s | 0.640s | Fixed file test: duration limit and real-time file chunk pacing. |

## ASR and Chunk Matrix

The same `/Users/temelgunaydin/Downloads/output.wav` file was then run through
the new `--asr compact|quality` CLI switch.

Summary tables can be regenerated with:

```bash
Tools/trace_summary.py \
  compact=/tmp/heptapod-audio-compact-v10.jsonl \
  compact12=/tmp/heptapod-audio-compact-chunk12-v1.jsonl \
  compact15=/tmp/heptapod-audio-compact-chunk15-v1.jsonl \
  quality=/tmp/heptapod-audio-quality-v1.jsonl \
  quality12=/tmp/heptapod-audio-quality-chunk12-v1.jsonl \
  quality15=/tmp/heptapod-audio-quality-chunk15-v1.jsonl \
  --compare-examples 3
```

| Trace | ASR | Chunk | Buffer | Segments | Transcripts | Translations | ASR avg | MT avg | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `audio-compact-v10` | Qwen3 0.6B 4-bit | 1.0s | 3 | 60 | 59 | 20 | 0.097s | 0.611s | Best compact baseline. |
| `audio-compact-chunk12-v1` | Qwen3 0.6B 4-bit | 1.2s | 3 | 50 | 50 | 17 | 0.103s | 0.716s | Some ASR fixes, but fewer translations and new merge errors. |
| `audio-compact-chunk15-v1` | Qwen3 0.6B 4-bit | 1.5s | 3 | 40 | 40 | 13 | 0.115s | 0.890s | Too few updates; incorrect long merges increased. |
| `audio-quality-v1` | Qwen3 1.7B 8-bit | 1.0s | 3 | 60 | 59 | 20 | 0.105s | 0.592s | Best overall ASR quality/latency balance so far. |
| `audio-quality-chunk12-v1` | Qwen3 1.7B 8-bit | 1.2s | 3 | 50 | 50 | 17 | 0.114s | 0.674s | Better than compact 1.2s, but cadence drops. |
| `audio-quality-chunk15-v1` | Qwen3 1.7B 8-bit | 1.5s | 3 | 40 | 40 | 13 | 0.126s | 0.732s | Less frequent output; some phrase merges improve, others degrade. |

## Automated Runner Verification

`Tools/run_live_benchmark.py` was added so the compact/quality comparison can be
rerun without manually launching each command. A 60 second quick run on the same
WAV file produced:

| Trace | ASR | Chunk | Buffer | Segments | Transcripts | Translations | ASR avg | MT avg | Finished |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `compact-1.0-b3` | compact | 1.0s | 3 | 60 | 59 | 21 | 0.086s | 0.644s | yes |
| `quality-1.0-b3` | quality | 1.0s | 3 | 60 | 59 | 21 | 0.111s | 0.626s | yes |

Runner output was written to a timestamped `/tmp/heptapod-live-benchmarks/...`
directory and can be regenerated with:

```bash
Tools/run_live_benchmark.py \
  --audio /Users/temelgunaydin/Downloads/output.wav \
  --duration 60 \
  --preset quick \
  --examples 3 \
  --compare-examples 3
```

## Findings

- Text-only mode should emit ASR immediately and translate only buffered stable text.
- Text-only ASR stabilization increased missing-output risk for this chunked Qwen ASR path, so text-only now defaults stabilization off.
- `1.0s` chunks with `3` buffered ASR segments is the best current latency/quality balance.
- `1.2s` chunks did not improve quality enough to justify the lower translation cadence.
- Qwen3 ASR 1.7B 8-bit improved important transcript errors with only a small per-chunk latency increase on this Mac.
- `max-buffered-segments=2` lowered MT latency but sent too little context into translation.
- Carrying incomplete English tails avoids poor partial translations such as `is just to`, `as`, `when`, and `keep`.
- Retaining live ASR fragments such as `A peaceful`, `I feel like`, and `hold` preserves phrases that MADLAD otherwise drops when they are translated alone.
- Stream-end flush now forces the remaining retained tail through translation so the final phrase is not silently lost.
- Joining duplicate boundary words avoids ASR chunk artifacts such as `Where we learn. Learn English.`.
- WAV file tests must be duration-limited and paced like live audio; otherwise ASR can outrun MT and create a large translation backlog.

## Quality Notes

The pipeline is now stable and low-latency, but transcript quality is the main remaining bottleneck. Examples from the WAV file test:

```text
Sleep podcast
Sociations
Into the T.J.
You had a really, peace. Full day.
```

The larger ASR model improved several of these:

```text
Podcast from speech
When was the last time?
You had a really peaceful. Full day.
```

It still missed domain-specific or ambiguous audio in places:

```text
Sleep podcast
Life conversation. stations.
Into the T J.
```

These are ASR errors before translation, so switching translation models before improving ASR would be misleading.

After adding live-fragment tail retention, the quality ASR path improved this
sequence:

```text
A peaceful. Day.
I feel like. Like I should lower my. Voice and hold. A cup of tea.
```

into translation inputs closer to natural English:

```text
A peaceful day.
I feel like I should lower my voice and hold a cup of tea.
```

Duplicate-boundary joining also improved the compact ASR path:

```text
Where we learn. Learn English.
```

to:

```text
Where we learn English.
```

## Current Recommended Command

```bash
swift run HeptapodLiveSpeechDemo -- \
  --real \
  --audio ../../Downloads/output.wav \
  --to tr \
  --asr quality \
  --latency balanced \
  --chunk-duration 1.0 \
  --max-buffered-segments 3 \
  --text-only \
  --duration 60 \
  --trace /tmp/heptapod-audio-quality-v1.jsonl
```

## Next Benchmarks

1. Use `Tools/run_live_benchmark.py` to regenerate the compact/quality matrix from one WAV file.
2. Try a true streaming ASR backend after the Qwen quality path is stable.
3. Only after ASR improves further, compare MADLAD with another MT option.
4. Treat SeamlessM4T as an offline quality reference, not the immediate live low-latency path.
