# System Audio Stress: English to Turkish

Date: 2026-08-09

## Goal

Exercise the complete local path for longer than a smoke test:

```text
Chrome playback -> ScreenCaptureKit -> Silero VAD -> Qwen3 ASR 0.6B
-> Apple Translation + glossary -> Chatterbox MLX -> AVAudioEngine
```

The fixture contains six repetitions of three English sentences with a short
pause between repetitions. It is 60 seconds, mono PCM16, and 16 kHz. Capture ran
for 65 seconds so the final source audio and queued output could drain.

## Findings

The first file-backed stabilized run treated each one-second capture chunk as a
single speech/silence decision. Pauses inside a chunk were invisible, so the ASR
sliding window carried text across utterance boundaries. A silence-separated
baseline produced 22 transcript events and 12 translated outputs; later windows
still merged unrelated sentence tails.

Silero now exposes speech time ranges through
`HeptapodSegmentingVoiceActivityDetector`. The live session splits a capture
chunk at an internal silence of at least 350 ms, flushes the current ASR
hypothesis, and resets the sliding window before the next speech region. On the
same file-backed fixture, transcript events increased from 22 to 34 and the
late-run boundary corruption disappeared.

The first browser run exposed a separate playback issue. Starting
`AVAudioEngine` only after the first translated sentence caused ScreenCaptureKit
input to become silent after roughly nine seconds. The run completed with only
two outputs. Chatterbox generation without speaker playback completed normally,
which isolated the failure to audio graph startup rather than MLX inference.

The playback graph is now prepared at 24 kHz mono before the system-audio stream
is created. The full browser run then completed all expected work:

| Metric | Result |
| --- | ---: |
| Capture segments | 65 |
| Transcript events | 18 |
| Translation/TTS outputs | 18 |
| Completed playbacks | 18 |
| Repeated translations | 0 |
| ASR average | 0.194 s |
| MT average | 0.054 s |
| TTS first audio average | 1.335 s |
| First audible output after ASR | 1.417 s |
| Playback queue average | 0.256 s |
| Peak output/playback queues | 2 / 2 |
| Clean run finish | yes |

## Reproduction

Build `HeptapodLiveSpeechDemo`, then run the already-built executable through
the benchmark runner:

```bash
.venv-chatterbox-mlx/bin/python Tools/run_live_benchmark.py \
  --system-audio \
  --playback-audio /tmp/heptapod-system-audio-stress-60s.wav \
  --playback-browser chrome \
  --playback-delay 1 \
  --duration 65 \
  --case browser-full:compact:1.0:8 \
  --asr-stabilization \
  --punctuation-endpoint \
  --speech-output \
  --tts chatterbox-mlx \
  --play-output \
  --mt apple \
  --mt-postedit glossary \
  --demo-binary /path/to/HeptapodLiveSpeechDemo \
  --skip-build \
  --min-outputs 10
```

The benchmark writes the command, JSONL trace, console log, generated WAV files,
latency summary, and transcript/translation examples into its output directory.
