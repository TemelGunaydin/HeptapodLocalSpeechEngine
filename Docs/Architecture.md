# Architecture

HeptapodLocalSpeechEngine separates the local speech translation problem into replaceable stages.

## Standard Pipeline

```text
System audio
  -> Voice activity detection
  -> Speech recognition
  -> Text translation
  -> Speech synthesis
  -> Audio playback
```

This path is practical because each model family can be upgraded independently.

## Direct Speech-to-Speech Pipeline

```text
System audio
  -> Direct speech-to-speech model
  -> Audio playback
```

This path is tracked for research because it is closest to a cloud realtime model. It is not the initial production target because current open models are large and harder to package for native Apple apps.

## Runtime Ownership

Each adapter owns:

- model download/cache location,
- prepare/load lifecycle,
- inference calls,
- model-specific streaming or batching behavior,
- model-specific errors.

The pipeline owns:

- stage ordering,
- silence gating,
- passing language hints,
- combining ASR -> translation -> TTS,
- rejecting empty/fake output.

The UI owns:

- model selection,
- showing model size and cache status,
- progress display,
- playback controls,
- user-facing error messages.

## Stable API Boundary

Adapters conform to protocols in `Core/EngineProtocols.swift`. The app should depend on protocols and descriptors, not concrete model packages.

This keeps the product free to move from Qwen to WhisperKit, from MADLAD to NLLB, or from Kokoro to Qwen3-TTS without rewriting the NoBorderX feature surface.
