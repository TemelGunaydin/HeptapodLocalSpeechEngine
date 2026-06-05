# Qwen3 ASR + MADLAD + Kokoro EN->ES Smoke Test

Date: 2026-06-04

## Environment

- Device: local Apple Silicon Mac
- Runtime: SwiftPM debug build
- Input fixture: `/tmp/heptapod-real-input.wav`
- Output audio: `/tmp/heptapod-real-output-es.wav`
- JSON report: `/tmp/heptapod-real-report.json`

## Models

| Stage | Model |
| --- | --- |
| VAD | `aufklarer/Silero-VAD-v5-CoreML` |
| ASR | `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` |
| Translation | `aufklarer/MADLAD400-3B-MT-MLX` |
| TTS | `aufklarer/Kokoro-82M-CoreML` |

## Command

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 swift run HeptapodRealSpeechDemo -- \
  --audio /tmp/heptapod-real-input.wav \
  --from en \
  --to es \
  --tts-language es \
  --output /tmp/heptapod-real-output-es.wav \
  --report /tmp/heptapod-real-report.json
```

The same input also passed through the live session file source:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 swift run HeptapodLiveSpeechDemo -- \
  --real \
  --audio /tmp/heptapod-real-input.wav \
  --to es \
  --output-dir /tmp/heptapod-live-output
```

Live session output:

```text
/tmp/heptapod-live-output/segment-001.wav
1.250s, 24 kHz, mono
```

The microphone live path also started successfully and processed a one-second
chunk. The local environment was silent, so VAD skipped the segment as expected:

```bash
swift run HeptapodLiveSpeechDemo -- \
  --real \
  --microphone \
  --duration 1 \
  --to es
```

```text
Segment 1
  VAD: silence, skipped
```

## Results

| Metric | Value |
| --- | ---: |
| Input duration | 0.937s |
| Output duration | 1.250s |
| VAD model load | 1.618s |
| VAD inference | 0.008s |
| ASR model load | 2.644s |
| ASR inference | 0.138s |
| Translation model load | 2.330s |
| Translation inference | 0.537s |
| TTS model load | 17.393s |
| TTS inference | 0.273s |
| Pipeline inference total | 0.956s |
| Total including model loads | 24.957s |

Transcript:

```text
Hello, how are you?
```

Translation:

```text
Hola, ¿cómo estás?
```

## Notes

- The full staged local pipeline completed successfully with cached model weights and VAD gating.
- The live-latency number to optimize is `pipelineInferenceSeconds`, not the startup model load time.
- The current demo is still file-based and segment-based; the next target is microphone input, streaming VAD, and queued playback.
