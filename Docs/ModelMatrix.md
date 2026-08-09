# Model Matrix

All numbers are estimates until each adapter pins a model artifact and cache layout.
Silero VAD, Qwen3-ASR, MADLAD, Apple Translation, experimental TranslateGemma,
MOSS-TTS-Nano, Chatterbox MLX, native macOS voices, Kokoro, and the older
PyTorch Chatterbox bridge are runnable today.
MOSS is the streaming Turkish default; Chatterbox MLX is the quality mode.

Nemotron 3.5 ASR Streaming is tracked through the MLX community conversion,
not the original NeMo-only path. It currently needs `mlx-audio` with Nemotron
support; use it as an Apple Silicon benchmark candidate before promoting it to a
Swift-native adapter.

| Stage | Model | Status | Estimated Install | Notes |
| --- | --- | --- | ---: | --- |
| VAD | Silero VAD | Adapter target ready | ~8 MB | Low-cost silence gate |
| ASR | Qwen3 ASR 0.6B 4-bit | Adapter target ready | ~760 MB | Good default |
| ASR | Qwen3 ASR 1.7B 8-bit | Adapter target ready | ~3.6 GB | Higher accuracy |
| ASR | WhisperKit Base | Planned | ~220 MB | Streaming/timestamps candidate |
| ASR | WhisperKit Large v3 | Planned | ~3.4 GB | Heavy high-quality ASR |
| ASR | Parakeet Streaming | Planned | ~340 MB | True partial ASR candidate |
| ASR | Nemotron 3.5 ASR Streaming 0.6B | Planned | ~1.5 GB | MLX/Python cache-aware streaming candidate |
| MT | MADLAD-400 3B | Adapter target ready | ~2.8 GB | Practical first local translator |
| MT | Apple Translation | Adapter target ready | System-managed | Fast on-device quality mode; macOS 26+ |
| MT | TranslateGemma 4B 4-bit | Experimental adapter ready | ~2.4 GB | Faster than MADLAD, but below Apple EN-to-TR quality in the fixed fixture |
| MT | NLLB Distilled 600M | Research | ~1.6 GB | Non-commercial comparison candidate |
| MT | SeamlessM4T text path | Research | ~4.8 GB | Heavy unified translation research |
| TTS | MOSS-TTS-Nano 100M | Streaming bridge ready | ~1.5 GB | First PCM before full synthesis; CPU ONNX |
| TTS | Chatterbox MLX FP16 | Python/MLX bridge ready | ~3.5 GB | Natural Turkish quality mode; warmed sentence pipeline |
| TTS | macOS System Voice | Adapter target ready | 0 MB | Fast fallback; uses installed voices |
| TTS | Kokoro 82M | Adapter target ready | ~130 MB | Small supported-language TTS; no Turkish phonemizer |
| TTS | Chatterbox TTS | Python bridge ready | ~4.3 GB | Natural Turkish; about 23s output latency in the tested run |
| TTS | Qwen3 TTS 0.6B | Planned | ~1.2 GB | Natural local voice candidate |
| TTS | CosyVoice3 0.5B | Planned | ~1.0 GB | Expressive TTS candidate |
| Direct S2ST | SeamlessStreaming | Research | ~10 GB | Simultaneous direct S2ST/S2TT candidate |
| Direct S2ST | SeamlessM4T v2 | Research | ~10 GB | Closest direct S2ST family |

## Suggested Presets

Starter:

```text
Silero VAD + Qwen3 ASR 0.6B + MADLAD-400 3B + MOSS-TTS-Nano
```

Natural voice:

```text
Silero VAD + Qwen3 ASR 0.6B + Apple Translation + source-gated glossary + Chatterbox MLX
```

Future/research:

```text
Silero VAD + Qwen3 ASR 1.7B + NLLB Distilled + Qwen3 TTS
```

Research:

```text
Nemotron ASR via mlx-audio, SeamlessStreaming direct S2ST
```
