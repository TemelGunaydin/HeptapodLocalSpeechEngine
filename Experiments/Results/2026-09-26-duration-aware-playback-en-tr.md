# Duration-Aware Playback: English to Turkish

Date: 2026-09-26

## Change

The old speed controller used queued segment count. With the default two-segment
playback limit, it could request only 1.05x, even if those segments held many
seconds of speech. Short and long segments had the same weight.

The producer now announces each PCM chunk's original-rate duration before it
enters the playback relay. The AVAudio sink subtracts processed playback
completions and uses the remaining duration to adjust speed. Two seconds of
headroom and a twenty-second recovery horizon avoid reacting to every small
burst. Rate changes are limited by elapsed time. The default ceiling stays at
1.15x; `--max-playback-rate` accepts 1.0...1.5, with 1.0 disabling acceleration.
The pitch setting is unchanged.

Long batch-TTS waveforms are scheduled in at most 200 ms buffers. Their PCM
bytes remain in order, while completion callbacks provide regular pacing and
cancellation points. This does not add extra ASR or translation boundaries.

## Measurement

- Baseline: `91943a0` plus the preceding MT/TTS lookahead changes, before pacing.
- Candidate: duration-aware pacing and 200 ms scheduling buffers.
- Input: first 15 seconds of the existing repeated-sentence `stress.wav` fixture.
- Fixture SHA-256: `e1d4ba094a93a206709ccdafba35e088609c9efb06162a2f1bbb3197ef4deba5`.
- Models: Qwen3 ASR 0.6B 4-bit, Apple Translation with glossary, MOSS-TTS-Nano.
- Settings: balanced preset, 1-second input chunks, three-segment safety flush.
- Output: AVAudioEngine speaker playback plus original-rate WAV archive.
- Models were cached, with `HF_HUB_OFFLINE=1`. No microphone/system capture.

| Metric | Before | Default 1.15x Ceiling | Optional 1.35x Ceiling |
| --- | ---: | ---: | ---: |
| Transcripts / results / completed playbacks | 5 / 5 / 5 | 5 / 5 / 5 | 5 / 5 / 5 |
| Total generated PCM duration | 20.320 s | 20.320 s | 20.320 s |
| Sum of playback-stage durations | 20.313 s | 19.487 s | 20.212 s |
| Average wait for playback | 2.821 s | 2.057 s | 2.241 s |
| Average ASR duration | 0.327 s | 0.236 s | 0.244 s |
| Average MT duration | 0.962 s | 0.563 s | 0.565 s |
| Average first audio after accepted transcript | 1.930 s | 0.859 s | 0.961 s |
| Run duration after preparation | 26.392 s | 23.954 s | 24.554 s |
| Peak accounted pending PCM | not recorded | 7.840 s | 8.160 s |
| Peak requested playback rate | not recorded | 1.150x | 1.193x |
| Final pending PCM | not recorded | 0 s | 0 s |
| Accounted completed PCM | not recorded | 20.320 s | 20.320 s |
| `run_finished` recorded | yes | yes | yes |

All runs produced the same ordered ASR and translation text and five readable
mono 48 kHz WAV files. Their frame counts matched:
`[172800, 218880, 192000, 172800, 218880]`. Completed playback indexes were
`[4, 7, 9, 13, 15]` in all three runs.

These are single runs, not controlled repeated benchmarks. Model warm-up,
inference variation, and system load were not held constant. Playback-stage
duration includes startup and waits for streamed audio, not just hardware
render time. The improved first-audio/MT numbers must not be attributed to the
playback controller. A higher ceiling did not improve this short run, and the
default was not raised.

Foreground XcodeBuildMCP invocations reported failure despite complete traces;
one exposed the CLI daemon's 30-second request timeout. Final candidate runs
used managed background launches, with completion verified from traces and
the completed process registrations cleaned up. The baseline comparison relies
on its complete trace and WAV files, not a successful CLI exit status.

## Verification and Limits

97 Swift tests and 21 Python tests pass. Coverage includes one-segment long
audio, short-audio pacing, configured ceilings, time-based rate slew, invalid
values, drain/reset/cancellation, notification before PCM delivery, and exact
byte preservation when splitting 16/24/48 kHz PCM buffers. Existing ordered
128-segment MT/TTS tests remain passing.

No accepted sentence is intentionally discarded. This does not mean error-free
ASR/translation or bit-identical speaker output: time stretching changes the
rendered waveform. Perceptual voice quality still needs listening evaluation.
Pending text and upstream PCM relays are not bounded by this controller, and
the accounting excludes PCM still inside a synthesis provider. Completion-based
pending duration is not a continuously sampled wall-clock lag estimate.

The fixture still produces 20.32 seconds of speech from 15 seconds of input.
Even continuous 1.15x playback needs about 17.67 seconds. This change cannot
guarantee fixed lag during sustained output-duration overload.

## Reproduction

Use XcodeBuildMCP `swift-package run --background` with `HeptapodLiveSpeechDemo`
and pass these arguments through `--json`:

```text
--real --audio /path/to/stress.wav --from en --to tr
--mt apple --tts moss --asr compact --latency balanced
--duration 15 --max-buffered-segments 3 --play-output
--trace /tmp/run.jsonl --output-dir /tmp/run-audio
```

Add `--max-playback-rate 1.35` for the optional-ceiling case. Wait for
`run_finished` before stopping/clearing the managed process registration.

```bash
python3 Tools/trace_summary.py before=/tmp/before.jsonl paced=/tmp/run.jsonl
```

Raw local artifacts: `/private/tmp/heptapod-playback.2SQqqc`, using
`before`, `paced-115`, and `paced-135` traces and their matching `-audio`
directories. Intermediate `after` and `ceiling-135` runs predate 200 ms
scheduling and are not the candidates in the table above.
