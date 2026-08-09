# HeptapodLocalSpeechEngine

<p align="center">
  <img src="Assets/heptapod-logo.png" alt="Heptapod app logo" width="160">
</p>

HeptapodLocalSpeechEngine is a Swift package and runnable macOS demo for local
speech-to-speech translation on Apple platforms. Anyone can clone the repository,
download the required model weights, and translate microphone, system, or file
audio locally without sending speech to a remote service.

The package is intentionally model-agnostic. Each stage can be swapped independently:

```text
Audio -> VAD -> ASR -> Text Translation -> TTS -> Audio
```

There is also a research slot for direct speech-to-speech models:

```text
Audio -> Direct S2ST -> Audio
```

## Project Goal

The project provides a practical local live-translation pipeline that:

- keeps captured speech and generated audio on the local machine,
- works with microphone, macOS system audio, and local audio files,
- supports low-latency and higher-quality local voice modes,
- gives clear model size and quality tradeoffs,
- can adopt better ASR, translation, and TTS adapters over time.

The practical local path is currently a staged pipeline. Each stage stays behind
a protocol so applications can choose a compact low-latency configuration or a
higher-quality configuration without changing the pipeline API.

## Quick Start

Requirements: an Apple Silicon Mac, full Xcode, and Python 3.11. Setup scripts
use `/opt/homebrew/bin/python3.11` by default; set `PYTHON_BIN` to override it.
Setup needs an internet connection once to download dependencies and model
weights; live translation remains local after those files are cached.

```bash
git clone https://github.com/TemelGunaydin/HeptapodLocalSpeechEngine.git
cd HeptapodLocalSpeechEngine

Tools/setup_moss_tts_nano.sh
Tools/run_live_translation.sh
```

Start browser or YouTube playback after capture begins. On the first run, macOS
may request Screen Recording permission for the terminal. Grant it, then run the
launcher again.

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
        HeptapodTranslationPostEditing.swift
      Adapters/
        HeptapodUnavailableAdapterFactory.swift
        UnavailableModelAdapters.swift
    HeptapodSpeechSwiftAdapters/
      HeptapodAVAudioMicrophoneSource.swift
      HeptapodAVAudioPlaybackSink.swift
      HeptapodSileroVADAdapter.swift
      HeptapodQwen3ASRAdapter.swift
      HeptapodMADLADTranslatorAdapter.swift
      HeptapodAppleTranslationAdapter.swift
      HeptapodTranslateGemmaTranslatorAdapter.swift
      HeptapodKokoroTTSAdapter.swift
      HeptapodChatterboxTTSAdapter.swift
      HeptapodMossTTSNanoAdapter.swift
      HeptapodMacOSSpeechSynthesizerAdapter.swift
      HeptapodSpeechSwiftAdapterFactory.swift
    HeptapodLiveSpeechDemo/
      main.swift
    HeptapodRealSpeechDemo/
      main.swift
    HeptapodTranslationBenchmark/
      HeptapodTranslationBenchmark.swift
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
- `HeptapodTranslationPostEditor`: optional bounded-context correction after translation.
- `HeptapodSpeechSynthesizer`: target text to target speech.
- `HeptapodDirectSpeechTranslator`: optional research path for direct speech-to-speech.

The default pipeline is:

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
xcrun swift run HeptapodLiveSpeechDemo
```

Preview interactive live session:

```bash
xcrun swift run HeptapodLiveSpeechDemo -- --interactive
```

Local model cache status:

```bash
xcrun swift run HeptapodLiveSpeechDemo -- --cache-status
```

Real file-backed live session:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 xcrun swift run HeptapodLiveSpeechDemo -- \
  --real \
  --audio /path/to/input.wav \
  --to es \
  --output-dir /tmp/heptapod-live
```

File-backed live sessions use the local audio runtime and can read common
AVFoundation formats such as WAV, M4A, MP3, and CAF.

Real microphone live session:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 xcrun swift run HeptapodLiveSpeechDemo -- \
  --real \
  --microphone \
  --to es \
  --duration 10 \
  --play-output
```

Real macOS system-audio live session:

```bash
Tools/run_live_translation.sh
```

This defaults to English source audio, Turkish output, compact Qwen ASR, the
balanced `1.0s / 4 segment` endpointing profile, MADLAD translation, and
streaming MOSS-TTS-Nano.
The pipeline is fully local after model weights are cached. It does not use a
WebSocket or remote server; optional Python models run as local persistent child
processes over JSON-lines pipes.

On macOS 26 or newer, use Apple's installed on-device translation assets for
faster and more natural EN-to-TR text translation:

```bash
Tools/run_live_translation.sh \
  --from en \
  --to tr \
  --mt apple
```

The source/target language pair must already be installed in the system
Translation settings. This path uses the
[Apple Translation framework](https://developer.apple.com/documentation/translation)
and does not download or load MADLAD weights.

TranslateGemma 4B is also available as an experimental local MLX backend:

```bash
Tools/setup_translategemma_mlx.sh

Tools/run_live_translation.sh \
  --from en \
  --to tr \
  --mt translategemma
```

In the fixed EN-to-TR quality fixture, TranslateGemma was much faster than
MADLAD but less reliable than Apple Translation. It remains an explicit
experiment rather than the default live backend. See
[`2026-08-09-apple-madlad-translategemma-en-tr.md`](Experiments/Results/2026-08-09-apple-madlad-translategemma-en-tr.md).

Live EN-to-TR runs also apply a deterministic terminology post-editor by
default. A replacement occurs only when both its English source phrase and the
exact Turkish draft phrase match, so it does not ask a second model to rewrite
already-correct sentences. Disable it for raw backend comparisons:

```bash
Tools/run_live_translation.sh \
  --mt apple \
  --mt-postedit none
```

The core post-edit wrapper retains at most the previous two accepted sentence
pairs for future contextual editors. A measured Qwen 4B experiment added about
0.60 seconds per sentence and still introduced meaning regressions, so it is
not connected to live output. See
[`2026-08-09-contextual-postedit-en-tr.md`](Experiments/Results/2026-08-09-contextual-postedit-en-tr.md).

The launcher intentionally uses `xcrun swift`, so the Swift compiler and macOS
SDK come from the same active Xcode toolchain. A bare `swift` command may resolve
to Swiftly while selecting a newer Command Line Tools SDK, which produces an
`SDK is not supported by the compiler` error. Extra demo options can be appended
directly, for example `Tools/run_live_translation.sh --duration 60`.

Live audio sources use sentence/pause buffering by default: ASR results are
accumulated while the speaker is talking. A completed terminal-punctuation
prefix is sent to translation and TTS immediately while an unfinished trailing
phrase remains in the ASR buffer. Silence, the configured segment limit, and
stream end provide fallback endpoints. This avoids both waiting for an entire
paragraph and speaking tiny partial fragments such as "One of the goals of."
Use `--chunk-translation` to restore the older translate-every-chunk behavior.

Low and balanced latency presets also enable ASR stabilization. The current
Qwen adapter is still a chunk decoder, but the live session now wraps it in a
ring-buffer/sliding-window policy: each new speech chunk is decoded with recent
audio context, consecutive hypotheses are compared, and only the stable prefix
delta is sent downstream. On a silence endpoint, the latest uncommitted
hypothesis is flushed. Segment-capable VAD adapters also expose speech time
ranges, so a pause of at least 350 ms can close the ASR window even when it falls
inside a larger capture chunk. Text-only mode keeps stabilization off by default
for easier ASR observability; use `--asr-stabilization` to force it on or
`--no-asr-stabilization` to disable it explicitly.

Latency tuning:

```bash
xcrun swift run HeptapodLiveSpeechDemo -- \
  --real \
  --system-audio \
  --to tr \
  --latency low \
  --text-only \
  --trace /tmp/heptapod-low.jsonl \
  --punctuation-endpoint \
```

`--latency balanced` is the default for live demos. It uses 1 second capture
chunks, stable-prefix ASR, terminal-punctuation endpoints, and a four-segment
safety flush. The `low` preset uses 0.75 second chunks and a single buffered
segment; it starts sooner but often splits a sentence into unnatural phrases.
The `quality` preset also releases completed sentences at terminal punctuation,
but keeps its longer capture window and eight-segment safety limit for context.

For better sentence context at the cost of waiting longer before the first
translation, use:

```bash
Tools/run_live_translation.sh \
  --mt apple \
  --latency quality \
  --asr-stabilization
```

Translation/TTS and playback are queued like a small backbuffer. Once a sentence
or stable phrase is flushed, the live input loop submits it to a serial synthesis
queue and immediately keeps consuming audio. Streaming TTS chunks are handed to
the serial playback queue as soon as they arrive; the full waveform does not need
to finish first. Speaker playback starts at `1.0x` and rises gradually to at most
`1.15x` only when the backlog grows. WAV archive output remains at the original
TTS rate. The next segment can transcribe while the previous segment is
translating, synthesizing, or playing. When speaker output is enabled, the
24 kHz playback graph is prepared before system capture starts. This avoids
reconfiguring the macOS output graph when the first translated sentence arrives.

Use `--text-only` when local TTS quality is not useful. In this mode the demo
prepares only VAD, ASR, and translation, skips TTS model load/inference entirely,
prints translated text, and writes `translation_ready` trace events instead of
audio playback events.

Use `--trace /tmp/heptapod-run.jsonl` to write JSON-lines timestamps for later
performance comparison. The trace records run start/finish, segment starts,
per-segment audio RMS/peak levels, ASR-ready latency, output-queue wait, MT
duration, TTS first-audio/full-output duration, playback-queue wait, queue
backlogs, transcript/translation text, generated audio byte count, and the
command used for the run.

Repeatable system-audio smoke test:

```bash
Tools/run_live_benchmark.py \
  --system-audio \
  --playback-audio /tmp/heptapod-local-fixture.wav \
  --playback-browser chrome \
  --playback-delay 1 \
  --duration 16 \
  --case browser-smoke:compact:1.0:4 \
  --asr-stabilization \
  --punctuation-endpoint \
  --speech-output \
  --tts moss \
  --play-output \
  --examples 3 \
  --last-examples 3 \
  --repeated-segments 5
```

This uses the same ScreenCaptureKit path as YouTube/browser audio, but plays a
known local fixture in an isolated Chrome app window so latency and transcript
regressions can be reproduced. Direct `afplay` output was silent in the tested
ScreenCaptureKit configuration, so browser playback is required for the
repeatable browser-audio smoke. Playback-audio runs require at least one output
event by default (`translation_ready` for text or `result_ready` for speech), so
silent capture is reported as a failed case.

If the demo was built by Xcode or FlowDeck, reuse that exact executable without
invoking another Swift toolchain:

```bash
Tools/run_live_benchmark.py \
  --system-audio \
  --playback-audio /tmp/heptapod-local-fixture.wav \
  --playback-browser chrome \
  --demo-binary /path/to/HeptapodLiveSpeechDemo \
  --skip-build
```

The 60-second browser/system-audio stress result, including the failed baseline
and the fixed `18/18/18` transcript/output/playback run, is recorded in
[`2026-08-09-system-audio-stress-en-tr.md`](Experiments/Results/2026-08-09-system-audio-stress-en-tr.md).

Install the low-latency live voice once:

```bash
Tools/setup_moss_tts_nano.sh
Tools/run_live_translation.sh
```

Install and select the higher-quality Metal backend:

```bash
Tools/setup_chatterbox_mlx.sh

Tools/run_live_translation.sh \
  --tts chatterbox-mlx
```

Chatterbox quality/prosody can be tuned without restarting its persistent
worker:

```bash
Tools/run_live_translation.sh \
  --tts chatterbox-mlx \
  --tts-exaggeration 0.5 \
  --tts-cfg-weight 0.5 \
  --tts-temperature 0.8
```

Both backends keep their model loaded in a persistent worker. MOSS streams
48 kHz PCM chunks and keeps Metal available for ASR/MT by using ONNX Runtime on
CPU. Chatterbox MLX warms its Metal path before capture starts, generates
natural sentence-sized 24 kHz batches, and sends the first sentence to playback
while the next one is synthesized. Excess boundary silence is trimmed and each
batch receives a short edge fade. Pass `--tts-one-shot` only for Chatterbox
bridge debugging.

The neutral Chatterbox defaults are `0.5` exaggeration, `0.5` CFG weight, and
`0.8` temperature. A reproducible four-preset Turkish listening matrix is
available through `Tools/chatterbox_quality_matrix.py`; see
[`2026-08-09-chatterbox-prosody-matrix-tr.md`](Experiments/Results/2026-08-09-chatterbox-prosody-matrix-tr.md).

On the tested M3 Max, MOSS produced its first PCM 1.40 seconds after ASR and
finished at 3.36 seconds. Chatterbox MLX produced its complete higher-quality
segment at 3.48 seconds. A later three-sentence quality benchmark measured
Chatterbox first audio at 2.10 seconds and full output at 4.94 seconds on
average; see
[`2026-08-09-chatterbox-chunked-tts-en-tr.md`](Experiments/Results/2026-08-09-chatterbox-chunked-tts-en-tr.md).
The older PyTorch Chatterbox backend remains available as `--tts chatterbox`
for comparison, but is not recommended for live output.

For voice cloning, pass a permitted 5-10 second reference WAV:

```bash
--tts-voice-prompt /path/to/reference-voice.wav
```

Start YouTube, Safari, Chrome, or another app after the capture begins. macOS may
ask for Screen Recording permission for the terminal process; grant it and rerun
the command if capture fails the first time.

Real local model smoke test from an audio file:

```bash
HF_DOWNLOAD_STALL_TIMEOUT=600 xcrun swift run HeptapodRealSpeechDemo -- \
  --audio /path/to/input.wav \
  --from en \
  --to es \
  --tts-language es \
  --output /tmp/heptapod-output.wav \
  --report /tmp/heptapod-real-report.json
```

The file input path can point to WAV, M4A, MP3, or CAF audio that AVFoundation
can decode locally.

The real demo uses Qwen3-ASR with MADLAD-400, Apple Translation, or the
experimental TranslateGemma adapter through the `HeptapodSpeechSwiftAdapters`
target, which wraps `speech-swift`. The live demo adds deterministic terminology
post-editing, MOSS streaming, Chatterbox MLX quality output, native macOS voices,
Kokoro, and the older PyTorch Chatterbox bridge.
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

If `swift` resolves to a Swiftly installation, do not combine that compiler with
the Command Line Tools `MacOSX.sdk` symlink. Use `xcrun` so the compiler and SDK
come from the same selected Xcode installation:

```bash
xcrun swift build --product HeptapodLiveSpeechDemo
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
- Apple Translation: fast on-device quality mode on macOS 26+ using installed system language assets.
- TranslateGemma 4B 4-bit: experimental MLX adapter; fast, but not reliable enough to replace Apple for EN-to-TR.
- NLLB Distilled 600M: research-only comparison candidate; the reference checkpoint is non-commercial.
- SeamlessM4T text path: research-grade option, heavier packaging.

TTS alternatives:

- MOSS-TTS-Nano 100M: streaming Turkish live default; CPU ONNX leaves Metal for ASR/MT.
- Chatterbox MLX FP16: more natural Turkish quality mode; faster than playback on the tested M3 Max.
- macOS System Voice: zero-download fallback using installed voices.
- Kokoro 82M: small option for en/fr/es/ja/zh/hi/pt/it; Turkish is rejected.
- Chatterbox PyTorch: retained as the older slow reference backend.
- Qwen3 TTS 0.6B: better natural speech, about 1.2 GB installed.
- CosyVoice3 0.5B: expressive TTS alternative, about 1.0 GB installed.

Direct speech-to-speech:

- SeamlessStreaming: research path for simultaneous speech-to-text/speech-to-speech translation with lower latency than offline SeamlessM4T-style S2ST.
- SeamlessM4T v2: closest research family to direct local S2ST, but too heavy to be the default path.

All file sizes are estimates until each adapter owns a concrete model artifact and cache layout.

## Current Model Matrix

| Stage | Model | Runtime | Status | Estimated Install | Best For | Main Tradeoff |
| --- | --- | --- | --- | ---: | --- | --- |
| VAD | Silero VAD | CoreML | Adapter target ready | ~8 MB | Silence gating | No transcription |
| ASR | Qwen3 ASR 0.6B 4-bit | MLX Swift | Adapter target ready | ~760 MB | Compact local mode | Segment-based, lower noisy-audio accuracy |
| ASR | Qwen3 ASR 1.7B 8-bit | MLX Swift | Adapter target ready | ~3.6 GB | Higher ASR quality | More memory and disk |
| ASR | WhisperKit Base | CoreML/WhisperKit | Planned | ~220 MB | Streaming ASR, timestamps | Separate model management |
| ASR | WhisperKit Large v3 | CoreML/WhisperKit | Planned | ~3.4 GB | Maximum ASR quality | Heavy |
| ASR | Parakeet Streaming | CoreML | Planned | ~340 MB | True partial ASR | Language coverage depends on variant |
| ASR | Nemotron 3.5 ASR Streaming 0.6B | MLX/Python | Planned | ~1.5 GB | True cache-aware streaming ASR | Needs mlx-audio bridge; not Swift-native yet |
| MT | MADLAD-400 3B | MLX Swift | Adapter target ready | ~2.8 GB | First local translation | Quality varies by language pair |
| MT | Apple Translation | System framework | Adapter target ready | System-managed | Fast, natural on-device translation | macOS 26+ and installed language pair |
| MT | TranslateGemma 4B 4-bit | MLX/Python | Experimental adapter ready | ~2.4 GB | Local translation experiments | EN-to-TR quality trails Apple in the fixed fixture |
| MT | NLLB Distilled 600M | Custom/converted | Research | ~1.6 GB | Translation comparison | Non-commercial reference license |
| MT | SeamlessM4T text path | Seamless | Research | ~4.8 GB | Unified research path | Heavy packaging |
| TTS | MOSS-TTS-Nano 100M | ONNX Runtime/CPU | Adapter target ready | ~1.5 GB | Streaming Turkish live default | Less expressive than quality mode |
| TTS | Chatterbox MLX FP16 | MLX/Python | Adapter target ready | ~3.5 GB | Natural multilingual quality mode | Full segment before playback; Metal contention |
| TTS | macOS System Voice | AVFoundation/`say` | Adapter target ready | 0 MB | Fast Turkish live output | Voice depends on installed macOS assets |
| TTS | Kokoro 82M | CoreML | Adapter target ready | ~130 MB | Small supported-language TTS | No Turkish phonemizer |
| TTS | Chatterbox Multilingual | PyTorch/MPS | Adapter target ready | ~4.3 GB | Natural multilingual reference | About 23s output latency in the tested live run |
| TTS | Qwen3 TTS 0.6B | MLX Swift | Planned | ~1.2 GB | Natural local speech | Memory/GPU pressure |
| TTS | CosyVoice3 0.5B | MLX Swift | Planned | ~1.0 GB | Expressive TTS | Adapter and voice management |
| Direct S2ST | SeamlessStreaming | Seamless | Research | ~10 GB | Simultaneous speech translation | Research runtime, packaging, license validation |
| Direct S2ST | SeamlessM4T v2 | Seamless | Research | ~10 GB | Single-family speech translation | Too heavy for the default path |

## Reference Configurations

Compact local mode:

```text
Silero VAD + Qwen3 ASR 0.6B + MADLAD-400 3B + MOSS-TTS-Nano
Estimated downloaded model size: roughly 4.3 GB
```

EN-to-TR quality mode on macOS 26+:

```text
Silero VAD + Qwen3 ASR 0.6B + Apple Translation + Chatterbox MLX
Translation assets are managed by macOS.
```

Research direct S2ST mode:

```text
SeamlessStreaming / SeamlessM4T v2
Estimated installed size: roughly 10 GB+
```

This is useful for experiments, but it is not the default path.

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

2. `HeptapodMADLADTranslatorAdapter` / `HeptapodAppleTranslationAdapter` / `HeptapodTranslateGemmaTranslatorAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - Adds local text translation behind `HeptapodTextTranslator`.
   - Apple Translation is the measured EN-to-TR quality/latency option on macOS 26+; MADLAD remains the portable model-backed fallback.
   - TranslateGemma remains experimental after the fixed EN-to-TR comparison.
   - The source-gated terminology post-editor fixes measured domain terms without a second model pass.

3. `HeptapodKokoroTTSAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - Adds a small TTS option for supported languages; Turkish is rejected explicitly.
   - Keep this as the smallest installed footprint target.

4. `HeptapodMossTTSNanoAdapter` / `HeptapodChatterboxTTSAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - MOSS is the streaming low-latency Turkish default.
   - Chatterbox MLX is the higher-quality segment backend; PyTorch Chatterbox remains a reference.

5. `HeptapodSileroVADAdapter`
   - Status: ready in `HeptapodSpeechSwiftAdapters`.
   - Adds real local speech/silence gating for the compact pipeline.
   - Keep file-based smoke tests runnable without VAD.

6. `Qwen3TTSAdapter`
   - Add higher-quality speech output.
   - Measure first-audio latency and memory pressure.

7. `WhisperKitASRAdapter`
   - Add streaming ASR and word timestamps.
   - Compare against Qwen3 ASR for latency and quality.

8. `NemotronASRAdapter`
   - Prototype an `mlx-audio` Python bridge for `mlx-community/nemotron-3.5-asr-streaming-0.6b`.
   - Compare bf16 and 8-bit MLX weights against Qwen compact/quality on the same WAV fixtures.

9. `NLLBTranslatorAdapter`
   - Add a translation quality alternative.
   - Decide whether conversion/runtime cost is acceptable.

10. `SeamlessStreamingExperimentAdapter`
   - Prototype a direct S2ST worker around SeamlessStreaming.
   - Keep as research-only until packaging, licensing, and Apple-hardware latency are proven.

## Engineering Notes

The current implementation is segment-based: speech is processed in short chunks,
then translated and synthesized. This is more stable than emitting unstable
word-by-word translations.

True realtime local speech translation needs:

- streaming ASR,
- incremental text translation,
- streaming TTS,
- audio queue scheduling,
- rollback/rewrite logic for partial transcripts.

These can be added incrementally while preserving the existing pipeline contracts.

## Integration Roadmap

1. Keep the package independent from any host application UI.
2. Add richer model download and cache-status reporting per adapter.
3. Expose reusable permission and background-audio integration APIs.
4. Add host-app model selection for latency, quality, and installed size.
5. Expand benchmark logging for latency, memory pressure, and translation quality.

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
- `HeptapodSpeechSwiftAdapters`, which provides runnable Silero VAD, Qwen3-ASR, MADLAD-400, Apple Translation, MOSS-TTS-Nano streaming, Chatterbox MLX/PyTorch, macOS System Voice, Kokoro, AVAudio microphone/playback, and ScreenCaptureKit system-audio adapters.
- A real file-based speech-to-speech smoke test executable and recorded experiment result.

It runs file-based local inference through the speech-swift adapter target and
has microphone-backed and system-audio-backed live demo paths. The remaining
work is app-integration polish: permissions UX, background audio behavior,
user-facing model cache status, and hardened playback scheduling.
