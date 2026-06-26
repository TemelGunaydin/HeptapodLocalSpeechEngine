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
        HeptapodUnavailableAdapterFactory.swift
        UnavailableModelAdapters.swift
    HeptapodSpeechSwiftAdapters/
      HeptapodAVAudioMicrophoneSource.swift
      HeptapodAVAudioPlaybackSink.swift
      HeptapodSileroVADAdapter.swift
      HeptapodQwen3ASRAdapter.swift
      HeptapodMADLADTranslatorAdapter.swift
      HeptapodKokoroTTSAdapter.swift
      HeptapodSpeechSwiftAdapterFactory.swift
    HeptapodLiveSpeechDemo/
      main.swift
    HeptapodRealSpeechDemo/
      main.swift
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
    RealPipelineSchema.md
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

## Runnable Demos

Scripted pipeline preview without real inference:

```bash
swift run HeptapodLiveSpeechDemo
```

Preview interactive live session:

```bash
swift run HeptapodLiveSpeechDemo -- --interactive
```

Starter model cache status:

```bash
swift run HeptapodLiveSpeechDemo -- --cache-status
```

Real file-backed live session:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 swift run HeptapodLiveSpeechDemo -- \
  --real \
  --audio /path/to/input.wav \
  --to es \
  --output-dir /tmp/heptapod-live
```

File-backed live sessions use the local audio runtime and can read common
AVFoundation formats such as WAV, M4A, MP3, and CAF.

Real microphone live session:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 swift run HeptapodLiveSpeechDemo -- \
  --real \
  --microphone \
  --to es \
  --duration 10 \
  --play-output
```

Real macOS system-audio live session:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 swift run HeptapodLiveSpeechDemo -- \
  --real \
  --system-audio \
  --to tr \
  --play-output
```

Live audio sources use sentence/pause buffering by default: ASR results are
accumulated while the speaker is talking, then translation and TTS run when a
pause/silence endpoint is detected. This avoids speaking tiny partial fragments
such as "One of the goals of." Use `--chunk-translation` to restore the older
translate-every-chunk behavior.

Low and balanced latency presets also enable ASR stabilization. The current
Qwen adapter is still a chunk decoder, but the live session now wraps it in a
ring-buffer/sliding-window policy: each new speech chunk is decoded with recent
audio context, consecutive hypotheses are compared, and only the stable prefix
delta is sent downstream. On a silence endpoint, the latest uncommitted
hypothesis is flushed. Use `--no-asr-stabilization` to disable that layer.

Latency tuning:

```bash
swift run HeptapodLiveSpeechDemo -- \
  --real \
  --system-audio \
  --to tr \
  --latency low \
  --text-only \
  --trace /tmp/heptapod-low.jsonl \
  --punctuation-endpoint \
```

`--latency low` is the default for live demos. It favors earlier translation
with 0.75 second capture chunks, one-word stable-prefix ASR commits, and a
single buffered ASR segment before flushing to translation/TTS. This is
intentionally more aggressive and may sound more phrase-by-phrase. Use
`--latency balanced` or `--latency quality` when translation quality matters
more than delay.

Translation/TTS and playback are queued like a small backbuffer. Once a sentence
or stable phrase is flushed, the live input loop submits it to a serial synthesis
queue and immediately keeps consuming audio. The synthesis queue prepares
translation plus TTS audio in order, then hands ready audio to a separate serial
playback queue. This lets the next segment transcribe while the previous segment
is translating, synthesizing, or playing.

Use `--text-only` when local TTS quality is not useful. In this mode the demo
prepares only VAD, ASR, and translation, skips TTS model load/inference entirely,
prints translated text, and writes `translation_ready` trace events instead of
audio playback events.

Use `--trace /tmp/heptapod-run.jsonl` to write JSON-lines timestamps for later
performance comparison. The trace records run start/finish, segment starts,
translation/result-ready latency, playback completion latency when speech output
is enabled, transcript text, translation text, generated audio byte count, and
the command used for the run.

More natural Chatterbox TTS output:

```bash
/opt/homebrew/bin/python3.11 -m venv .venv-chatterbox311
.venv-chatterbox311/bin/pip install chatterbox-tts torchaudio

HF_DOWNLOAD_STALL_TIMEOUT=600 swift run HeptapodLiveSpeechDemo -- \
  --real \
  --system-audio \
  --to tr \
  --tts chatterbox \
  --tts-python .venv-chatterbox311/bin/python \
  --play-output
```

Chatterbox uses a persistent Python worker by default, so the model is loaded
once and later segments are sent over JSON-lines instead of starting a new
Python process every time. Pass `--tts-one-shot` to use the older per-segment
process mode for debugging.

For voice cloning, pass a permitted 5-10 second reference WAV:

```bash
--tts-voice-prompt /path/to/reference-voice.wav
```

Start YouTube, Safari, Chrome, or another app after the capture begins. macOS may
ask for Screen Recording permission for the terminal process; grant it and rerun
the command if capture fails the first time.

Real local model smoke test from an audio file:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 swift run HeptapodRealSpeechDemo -- \
  --audio /path/to/input.wav \
  --from en \
  --to es \
  --tts-language es \
  --output /tmp/heptapod-output.wav \
  --report /tmp/heptapod-real-report.json
```

The file input path can point to WAV, M4A, MP3, or CAF audio that AVFoundation
can decode locally.

The real demo uses Qwen3-ASR, MADLAD-400, and Kokoro through the
`HeptapodSpeechSwiftAdapters` target, which wraps `speech-swift`. It can also use
Chatterbox through a local Python bridge for more natural speech output.
The first run downloads model weights from Hugging Face and caches them locally.
The JSON report records model load times, per-stage inference latency, transcript,
translation, audio durations, and output paths.
The current real pipeline schema is documented in
[`Docs/RealPipelineSchema.md`](Docs/RealPipelineSchema.md).
MLX inference also requires `mlx.metallib`; if it is missing, install the Metal Toolchain and build the shader library:

```bash
xcodebuild -downloadComponent MetalToolchain
BUILD_DIR="$(pwd)/.build" .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh debug
```

## Model Families In The Catalog

ASR alternatives:

- Qwen3 ASR 0.6B 4-bit: small local default, about 760 MB installed.
- Qwen3 ASR 1.7B 8-bit: better accuracy, about 3.6 GB installed.
- WhisperKit Base/Large: good future path for streaming ASR and word timestamps.
- Parakeet Streaming: streaming-first ASR candidate.
- Nemotron 3.5 ASR Streaming 0.6B: MLX community conversion plus `mlx-audio` candidate for true cache-aware streaming ASR on Apple Silicon.

Text translation alternatives:

- MADLAD-400 3B: practical first local multilingual translator, about 2.8 GB installed.
- NLLB Distilled 600M: possible quality/size alternative after runtime conversion.
- SeamlessM4T text path: research-grade option, heavier packaging.

TTS alternatives:

- Kokoro 82M: small TTS option, about 130 MB installed.
- Qwen3 TTS 0.6B: better natural speech, about 1.2 GB installed.
- CosyVoice3 0.5B: expressive TTS alternative, about 1.0 GB installed.

Direct speech-to-speech:

- SeamlessStreaming: research path for simultaneous speech-to-text/speech-to-speech translation with lower latency than offline SeamlessM4T-style S2ST.
- SeamlessM4T v2: closest research family to direct local S2ST, but too heavy to be the first production path.

All file sizes are estimates until each adapter owns a concrete model artifact and cache layout.

## Current Model Matrix

| Stage | Model | Runtime | Status | Estimated Install | Best For | Main Tradeoff |
| --- | --- | --- | --- | ---: | --- | --- |
| VAD | Silero VAD | CoreML | Adapter target ready | ~8 MB | Silence gating | No transcription |
| ASR | Qwen3 ASR 0.6B 4-bit | MLX Swift | Adapter target ready | ~760 MB | Starter local mode | Segment-based, lower noisy-audio accuracy |
| ASR | Qwen3 ASR 1.7B 8-bit | MLX Swift | Adapter target ready | ~3.6 GB | Higher ASR quality | More memory and disk |
| ASR | WhisperKit Base | CoreML/WhisperKit | Planned | ~220 MB | Streaming ASR, timestamps | Separate model management |
| ASR | WhisperKit Large v3 | CoreML/WhisperKit | Planned | ~3.4 GB | Maximum ASR quality | Heavy |
| ASR | Parakeet Streaming | CoreML | Planned | ~340 MB | True partial ASR | Language coverage depends on variant |
| ASR | Nemotron 3.5 ASR Streaming 0.6B | MLX/Python | Planned | ~1.5 GB | True cache-aware streaming ASR | Needs mlx-audio bridge; not Swift-native yet |
| MT | MADLAD-400 3B | MLX Swift | Adapter target ready | ~2.8 GB | First local translation | Quality varies by language pair |
| MT | NLLB Distilled 600M | Custom/converted | Planned | ~1.6 GB | Better translation candidate | Runtime conversion needed |
| MT | SeamlessM4T text path | Seamless | Research | ~4.8 GB | Unified research path | Heavy packaging |
| TTS | Kokoro 82M | CoreML | Adapter target ready | ~130 MB | Small local TTS | Less natural |
| TTS | Qwen3 TTS 0.6B | MLX Swift | Planned | ~1.2 GB | Natural local speech | Memory/GPU pressure |
| TTS | CosyVoice3 0.5B | MLX Swift | Planned | ~1.0 GB | Expressive TTS | Adapter and voice management |
| Direct S2ST | SeamlessStreaming | Seamless | Research | ~10 GB | Simultaneous speech translation | Research runtime, packaging, license validation |
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
SeamlessStreaming / SeamlessM4T v2
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

1. `HeptapodQwen3ASRAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - Runs segment-level Qwen3-ASR transcription through `speech-swift`.

2. `HeptapodMADLADTranslatorAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - Adds local text translation behind `HeptapodTextTranslator`.
   - Measure quality by language pair.

3. `HeptapodKokoroTTSAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - Adds a small TTS option for the first local voice output.
   - Keep this as the smallest installed footprint target.

4. `HeptapodSileroVADAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - Adds real local speech/silence gating for the starter pipeline.
   - Keep file-based smoke tests runnable without VAD.

5. `Qwen3TTSAdapter`
   - Add higher-quality speech output.
   - Measure first-audio latency and memory pressure.

6. `WhisperKitASRAdapter`
   - Add streaming ASR and word timestamps.
   - Compare against Qwen3 ASR for latency and quality.

7. `NemotronASRAdapter`
   - Prototype an `mlx-audio` Python bridge for `mlx-community/nemotron-3.5-asr-streaming-0.6b`.
   - Compare bf16 and 8-bit MLX weights against Qwen compact/quality on the same WAV fixtures.

8. `NLLBTranslatorAdapter`
   - Add a translation quality alternative.
   - Decide whether conversion/runtime cost is acceptable.

9. `SeamlessStreamingExperimentAdapter`
   - Prototype a direct S2ST worker around SeamlessStreaming.
   - Keep as research-only until packaging, licensing, and Apple-hardware latency are proven.

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
2. Add microphone, system-audio, and audio-queue edges for live local mode.
3. Add richer model download/cache status reporting per adapter.
4. Add a Heptapod settings screen for local engine model selection.
5. Add benchmark logging: latency, disk size, memory pressure, and translation quality notes.

## Current State

This package currently contains:

- Model descriptors and catalog.
- Pipeline configuration validation.
- Pipeline readiness reporting for UI/integration checks.
- Protocols for VAD, ASR, text translation, TTS, and direct S2ST.
- A speech-to-speech pipeline actor.
- A live speech session that schedules audio chunks, emits segment events, skips silence, and optionally plays synthesized audio through a sink.
- Detailed pipeline results that expose transcript, translated text, and synthesized speech.
- Unavailable placeholder adapters for not-yet-integrated models.
- A placeholder adapter factory that can build the selected pipeline shape before real inference adapters exist.
- `HeptapodSpeechSwiftAdapters`, which provides runnable Silero VAD, Qwen3-ASR, MADLAD-400, Kokoro, AVAudio microphone/playback, and ScreenCaptureKit system-audio adapters.
- A real file-based speech-to-speech smoke test executable and recorded experiment result.

It runs file-based local inference through the speech-swift adapter target and
has microphone-backed and system-audio-backed live demo paths. The remaining
production gap is app integration polish: permissions UX, background audio
behavior, user-facing model cache status, and production playback scheduling.
