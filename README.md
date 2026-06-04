# HeptapodLocalSpeechEngine

<p align="center">
  <img src="Assets/heptapod-logo.png" alt="Heptapod app logo" width="160">
</p>

HeptapodLocalSpeechEngine is a Swift package architecture for local speech-to-speech translation on Apple platforms. The goal is to build a private, offline-capable alternative to cloud realtime speech translation for Heptapod and future apps.

The package is intentionally model-agnostic. Each stage can be swapped independently:

```text
Audio -> VAD -> ASR -> Text Translation -> TTS -> Audio
```

There is also a research slot for direct speech-to-speech models:

```text
Audio -> Direct S2ST -> Audio
```

## Product Goal

The first production goal is not to beat OpenAI Realtime immediately. The first goal is a local mode that:

- avoids cloud minutes for Basic/Starter users,
- works with private local audio,
- gives clear model size and quality tradeoffs,
- can improve over time as better ASR, translation, and TTS adapters are added.

OpenAI Realtime gives a single cloud service for low-latency speech-to-speech translation. Local models are not yet as clean for production, so the practical local path is a staged pipeline. The package keeps each stage behind a protocol so Heptapod can choose a small/private mode or a higher-quality/heavier mode.

## Design Principles

- Every pipeline stage has alternatives.
- Model choices are data, not hardcoded logic.
- File size, memory, latency, and quality notes are first-class metadata.
- Adapters are replaceable without changing the pipeline API.
- Experiments should be reproducible and stored in the repo.
- No UI assumptions live inside the engine package.

## Repository Layout

```text
HeptapodLocalSpeechEngine/
  Package.swift
  README.md
  Sources/
    HeptapodLocalSpeechEngine/
      Core/
        EngineTypes.swift
        EngineProtocols.swift
      Catalog/
        HeptapodModelCatalog.swift
      Pipeline/
        HeptapodPipelineConfiguration.swift
        HeptapodSpeechToSpeechPipeline.swift
      Adapters/
        UnavailableModelAdapters.swift
  Tests/
    HeptapodLocalSpeechEngineTests/
      HeptapodCatalogTests.swift
  Experiments/
    README.md
    Results/
    DemoOutputs/
    Fixtures/
  Docs/
    Architecture.md
    ModelMatrix.md
```

## Pipeline Contracts

The core protocols are:

- `HeptapodVoiceActivityDetector`: skips silence and avoids wasting compute.
- `HeptapodSpeechRecognizer`: audio to source text.
- `HeptapodTextTranslator`: source text to target text.
- `HeptapodSpeechSynthesizer`: target text to target speech.
- `HeptapodDirectSpeechTranslator`: optional research path for direct speech-to-speech.

The normal production pipeline is:

```text
VAD -> ASR -> MT -> TTS
```

The direct research pipeline is:

```text
Direct S2ST
```

The direct path is important to track because it is conceptually closest to OpenAI Realtime, but it is not the most practical first implementation.

## Model Families In The Catalog

ASR alternatives:

- Qwen3 ASR 0.6B 4-bit: small local default, about 760 MB installed.
- Qwen3 ASR 1.7B 8-bit: better accuracy, about 3.6 GB installed.
- WhisperKit Base/Large: good future path for streaming ASR and word timestamps.
- Parakeet Streaming: streaming-first ASR candidate.

Text translation alternatives:

- MADLAD-400 3B: practical first local multilingual translator, about 2.8 GB installed.
- NLLB Distilled 600M: possible quality/size alternative after runtime conversion.
- SeamlessM4T text path: research-grade option, heavier packaging.

TTS alternatives:

- Kokoro 82M: small TTS option, about 130 MB installed.
- Qwen3 TTS 0.6B: better natural speech, about 1.2 GB installed.
- CosyVoice3 0.5B: expressive TTS alternative, about 1.0 GB installed.

Direct speech-to-speech:

- SeamlessM4T v2: closest research family to direct local S2ST, but too heavy to be the first production path.

All file sizes are estimates until each adapter owns a concrete model artifact and cache layout.

## Current Model Matrix

| Stage | Model | Runtime | Status | Estimated Install | Best For | Main Tradeoff |
| --- | --- | --- | --- | ---: | --- | --- |
| VAD | Silero VAD | CoreML | Adapter required | ~8 MB | Silence gating | No transcription |
| ASR | Qwen3 ASR 0.6B 4-bit | MLX Swift | Ready in app, adapter pending | ~760 MB | Starter local mode | Segment-based, lower noisy-audio accuracy |
| ASR | Qwen3 ASR 1.7B 8-bit | MLX Swift | Ready in app, adapter pending | ~3.6 GB | Higher ASR quality | More memory and disk |
| ASR | WhisperKit Base | CoreML/WhisperKit | Planned | ~220 MB | Streaming ASR, timestamps | Separate model management |
| ASR | WhisperKit Large v3 | CoreML/WhisperKit | Planned | ~3.4 GB | Maximum ASR quality | Heavy |
| ASR | Parakeet Streaming | CoreML | Planned | ~340 MB | True partial ASR | Language coverage depends on variant |
| MT | MADLAD-400 3B | MLX Swift | Ready candidate | ~2.8 GB | First local translation | Quality varies by language pair |
| MT | NLLB Distilled 600M | Custom/converted | Planned | ~1.6 GB | Better translation candidate | Runtime conversion needed |
| MT | SeamlessM4T text path | Seamless | Research | ~4.8 GB | Unified research path | Heavy packaging |
| TTS | Kokoro 82M | CoreML | Adapter required | ~130 MB | Small local TTS | Less natural |
| TTS | Qwen3 TTS 0.6B | MLX Swift | Planned | ~1.2 GB | Natural local speech | Memory/GPU pressure |
| TTS | CosyVoice3 0.5B | MLX Swift | Planned | ~1.0 GB | Expressive TTS | Adapter and voice management |
| Direct S2ST | SeamlessM4T v2 | Seamless | Research | ~10 GB | Single-family speech translation | Too heavy for first production path |

## First Product Targets

Starter local mode:

```text
Silero VAD + Qwen3 ASR 0.6B + MADLAD-400 3B + Kokoro
Estimated installed size: roughly 3.7 GB
```

Higher-quality local mode:

```text
Silero VAD + Qwen3 ASR 1.7B + NLLB Distilled + Qwen3 TTS
Estimated installed size: roughly 6.4 GB
```

Research direct S2ST mode:

```text
SeamlessM4T v2
Estimated installed size: roughly 10 GB+
```

This is useful for experiments, but it is not the default product path.

## Experiment Tracking

Experiments should be added under `Experiments/Results/` as Markdown files. Each result should include:

- date,
- device model and chip,
- macOS/iOS version,
- model IDs and quantization,
- source language,
- target language,
- sample duration,
- input fixture path,
- output demo path,
- latency,
- real-time factor,
- installed size,
- peak memory if available,
- subjective quality notes,
- failure cases.

Recommended filename:

```text
Experiments/Results/2026-06-03-qwen-madlad-kokoro-en-tr.md
```

Demo audio/text outputs should be placed under:

```text
Experiments/DemoOutputs/
```

Input audio fixtures should be placed under:

```text
Experiments/Fixtures/
```

Avoid committing copyrighted or private audio. Use short synthetic or properly licensed clips.

## Evaluation Metrics

Minimum metrics for every experiment:

- ASR latency per segment.
- Translation latency per segment.
- TTS first-audio latency.
- End-to-end latency.
- Real-time factor.
- Installed model size.
- Whether the pipeline ran fully offline.
- Human quality score from 1 to 5.

Useful advanced metrics:

- WER for ASR if a reference transcript exists.
- BLEU/COMET-style score for translation if references exist.
- MOS-style subjective score for TTS.
- Dropout count during playback.
- Peak memory and GPU pressure.

## Adapter Roadmap

1. `Qwen3ASRAdapter`
   - Reuse the existing Heptapod Qwen3 ASR logic.
   - Add model cache reporting.
   - Add segment-level transcription.

2. `MADLADTranslatorAdapter`
   - Add local text translation behind `HeptapodTextTranslator`.
   - Measure quality by language pair.

3. `KokoroTTSAdapter`
   - Add a small TTS option for the first local voice output.
   - Keep this as the smallest installed footprint target.

4. `Qwen3TTSAdapter`
   - Add higher-quality speech output.
   - Measure first-audio latency and memory pressure.

5. `WhisperKitASRAdapter`
   - Add streaming ASR and word timestamps.
   - Compare against Qwen3 ASR for latency and quality.

6. `NLLBTranslatorAdapter`
   - Add a translation quality alternative.
   - Decide whether conversion/runtime cost is acceptable.

7. `SeamlessM4TExperimentAdapter`
   - Keep as research-only until packaging and latency are proven.

## Heptapod Integration Plan

1. Keep HeptapodLocalSpeechEngine as a standalone Swift package.
2. Add it to Heptapod through Swift Package Manager.
3. Build a Local Engine settings page:
   - ASR model picker,
   - translation model picker,
   - TTS model picker,
   - estimated installed size,
   - cache status,
   - quality/latency labels.
4. Add a `Local Voice Translation` mode next to cloud realtime translation.
5. Store local model choices in app preferences.
6. Store benchmark summaries locally for diagnostics.

## Engineering Notes

The first implementation should be segment-based. That means speech is processed in small chunks, then translated and synthesized. This is more stable than fake word-by-word streaming.

True realtime local speech translation needs:

- streaming ASR,
- incremental text translation,
- streaming TTS,
- audio queue scheduling,
- rollback/rewrite logic for partial transcripts.

That can be added later, but the first version should prioritize correctness and stability.

## Integration Plan

1. Keep this package independent from Heptapod UI.
2. Implement adapters one at a time, starting with existing Qwen3 ASR.
3. Add model download/cache management per adapter.
4. Add a Heptapod settings screen for local engine model selection.
5. Add benchmark logging: latency, disk size, memory pressure, and translation quality notes.

## Current State

This package currently contains:

- Model descriptors and catalog.
- Pipeline configuration validation.
- Pipeline readiness reporting for UI/integration checks.
- Protocols for VAD, ASR, text translation, TTS, and direct S2ST.
- A speech-to-speech pipeline actor.
- Detailed pipeline results that expose transcript, translated text, and synthesized speech.
- Unavailable placeholder adapters for not-yet-integrated models.
- A placeholder adapter factory that can build the selected pipeline shape before real inference adapters exist.

It does not yet run inference. Runtime adapters should be added behind the protocols without changing the public pipeline API.
