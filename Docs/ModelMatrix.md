# Model Matrix

All numbers are estimates until each adapter pins a model artifact and cache layout.
The Silero VAD, Qwen3-ASR, MADLAD, and Kokoro combination is runnable today through
`HeptapodSpeechSwiftAdapters` and the `HeptapodRealSpeechDemo` smoke test.

| Stage | Model | Status | Estimated Install | Notes |
| --- | --- | --- | ---: | --- |
| VAD | Silero VAD | Adapter target ready | ~8 MB | Low-cost silence gate |
| ASR | Qwen3 ASR 0.6B 4-bit | Adapter target ready | ~760 MB | Good default |
| ASR | Qwen3 ASR 1.7B 8-bit | Runnable candidate, adapter pending | ~3.6 GB | Higher accuracy |
| ASR | WhisperKit Base | Planned | ~220 MB | Streaming/timestamps candidate |
| ASR | WhisperKit Large v3 | Planned | ~3.4 GB | Heavy high-quality ASR |
| ASR | Parakeet Streaming | Planned | ~340 MB | True partial ASR candidate |
| MT | MADLAD-400 3B | Adapter target ready | ~2.8 GB | Practical first local translator |
| MT | NLLB Distilled 600M | Planned | ~1.6 GB | Translation quality candidate |
| MT | SeamlessM4T text path | Research | ~4.8 GB | Heavy unified translation research |
| TTS | Kokoro 82M | Adapter target ready | ~130 MB | Smallest useful TTS |
| TTS | Qwen3 TTS 0.6B | Planned | ~1.2 GB | Natural local voice candidate |
| TTS | CosyVoice3 0.5B | Planned | ~1.0 GB | Expressive TTS candidate |
| Direct S2ST | SeamlessM4T v2 | Research | ~10 GB | Closest direct S2ST family |

## Suggested Presets

Starter:

```text
Silero VAD + Qwen3 ASR 0.6B + MADLAD-400 3B + Kokoro
```

Quality:

```text
Silero VAD + Qwen3 ASR 1.7B + NLLB Distilled + Qwen3 TTS
```

Research:

```text
SeamlessM4T v2 direct S2ST
```
