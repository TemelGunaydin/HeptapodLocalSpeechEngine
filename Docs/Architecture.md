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
It is a cascaded realtime pipeline, not a single end-to-end interpreter model:
latency is managed through chunk size, VAD endpointing, stable sentence buffers,
sliding ASR stabilization, synthesis queueing, and playback queue behavior.

The currently runnable real-model smoke test is documented in
[`RealPipelineSchema.md`](RealPipelineSchema.md).

## Direct Speech-to-Speech Pipeline

```text
System audio
  -> Direct speech-to-speech model
  -> Audio playback
```

This path is tracked for research because it is closest to a cloud realtime model. It is not the initial production target because current open models are large and harder to package for native Apple apps.

The OpenAI-like target architecture is:

```text
streaming audio session
  -> partial/stable transcript events
  -> incremental translation events
  -> audio delta playback
```

The local product path keeps the cascaded stages for now and incrementally
pushes latency down before attempting SeamlessStreaming-style end-to-end speech
translation.

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

The live session owns:

- consuming an async audio chunk source,
- emitting segment lifecycle events,
- skipping silent chunks,
- running optional ring-buffer/sliding-window ASR stabilization,
- queueing stable transcript segments into serial translation/TTS synthesis,
- queueing synthesized audio into a serial playback backbuffer,
- keeping input/ASR work moving while previous translated audio is translating,
  synthesizing, or playing.

The UI owns:

- model selection,
- showing model size and cache status,
- progress display,
- playback controls,
- user-facing error messages.

## Stable API Boundary

Adapters conform to protocols in `Core/EngineProtocols.swift`. The app should depend on protocols and descriptors, not concrete model packages.

This keeps the product free to move from Qwen to WhisperKit, from MADLAD to NLLB, or from Kokoro to Qwen3-TTS without rewriting the Heptapod feature surface.

`HeptapodSpeechSwiftAdapters` is the first concrete adapter target. It keeps
`speech-swift` and AVFoundation dependencies out of the model-agnostic core
package while making Silero VAD, Qwen3-ASR, MADLAD-400, Kokoro, Chatterbox
Python TTS, microphone capture, system-audio capture, and playback usable
through the core engine protocols.
