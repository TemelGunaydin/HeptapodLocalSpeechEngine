# Architecture

HeptapodLocalSpeechEngine separates the local speech translation problem into replaceable stages.

## Standard Pipeline

```text
System audio
  -> Voice activity detection
  -> Speech recognition
  -> Text translation
  -> Optional bounded-context post-edit
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
`SeamlessStreaming` is tracked as a separate direct S2ST research model in the
catalog rather than as a default pipeline stage, because it needs a validated
runtime, model artifact packaging, and license review before product use.

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

The optional translation post-edit wrapper owns:

- retaining only the configured number of accepted source/translation pairs,
- tagging and filtering history by source/target language pair,
- serializing translation calls so accepted context remains in source order,
- applying a post-editor after the base translator,
- falling back to the original draft if an optional post-editor fails.

Post-edit profiles are language-pair specific. The current deterministic
EN-to-TR profile can reuse previously accepted technical terminology, while an
EN-to-ES session bypasses those Turkish rules and keeps the rest of the pipeline
unchanged.

The live session owns:

- consuming an async audio chunk source,
- emitting segment lifecycle events,
- skipping silent chunks,
- running optional ring-buffer/sliding-window ASR stabilization,
- queueing stable transcript segments into serial translation/TTS synthesis,
- releasing completed sentence prefixes while retaining unfinished ASR tails,
- forwarding streaming TTS PCM chunks into a serial playback backbuffer,
- increasing playback rate only when the translated-audio backlog grows,
- emitting per-stage queue, MT, TTS, and playback timing events,
- keeping input/ASR work moving while previous translated audio is translating,
  synthesizing, or playing.

The sentence-buffered session uses separate serial MT and TTS workers with a
FIFO of pending transcripts and a single prepared-translation slot. Translation
of the next segment can overlap synthesis of the current segment, without
concurrent calls to the same model or changes to source/context order.
`maximumPendingOutputs` limits synthesized segments in the playback queue; it
does not suspend capture/ASR when that queue fills. Both workers drain on normal
input completion and are cancelled together on failure or session cancellation.
Completed work is released instead of retaining a task chain for the whole session.

Playback sinks can opt into `HeptapodPlaybackAudioTracking`. The producer
announces each nonempty PCM chunk's original-rate duration before delivering
it to the playback relay. The AVAudio sink subtracts durations only after
processed `.dataPlayedBack` completions, so relay-buffered audio is counted
even before it reaches the AVAudioEngine scheduling buffer. This accounting
does not include PCM still buffered inside a synthesis provider.
Long batch-TTS waveforms are scheduled as at most 200 ms PCM buffers without
changing their byte order, giving cancellation and pacing regular completion
points. The scheduling limit can overshoot by at most one such buffer.

The AVAudio sink uses that duration to pace playback, with two seconds of
headroom and a twenty-second recovery horizon. Rate changes are limited to
0.05x per second upward and 0.10x per second downward. The default ceiling
stays at 1.15x; the demo's `--max-playback-rate` permits 1.0...1.5. No text or
audio segments are discarded. The existing segment-count hook remains a
fallback for callers that do not announce PCM durations. Cancellation clears
the pacing state, and the WAV sink archives unmodified-rate synthesis.

This is not an end-to-end memory or latency bound. Pending text can still grow
when sustained MT/TTS throughput is below the incoming speech rate, and PCM
stream relays are not byte-bounded. A live overload policy remains separate work;
the default preserves transcripts rather than silently dropping speech.

The UI owns:

- model selection,
- showing model size and cache status,
- progress display,
- playback controls,
- user-facing error messages.

## Stable API Boundary

Adapters conform to protocols in `Core/EngineProtocols.swift`. The app should depend on protocols and descriptors, not concrete model packages.

This keeps the product free to move from Qwen to WhisperKit, from MADLAD to
Apple Translation or another MT runtime, and from MOSS to Chatterbox without
rewriting the Heptapod feature surface.

`HeptapodSpeechSwiftAdapters` is the first concrete adapter target. It keeps
`speech-swift` and AVFoundation dependencies out of the model-agnostic core
package while making Silero VAD, Qwen3-ASR, MADLAD-400, Apple Translation,
streaming MOSS-TTS-Nano, Chatterbox MLX/PyTorch TTS, native macOS speech,
Kokoro, microphone capture, system-audio capture, and playback usable through
the core engine protocols.
