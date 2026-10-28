# Pocket Turkish voice and live translation latency

Date: 2026-10-28. Starting HEAD: `92acbb596d9f7f76cc121a2af872c183fdfe884e`.
Machine: Apple M3 Max, 64 GiB, macOS 27.0.1.

## Result

The user accepted both Pocket listening samples (`female_2`, `male_1`). Pocket
Turkish now supplies the demo's default Turkish voice, with native 24 kHz PCM
streaming from a persistent CPU worker. `--pocket-voice male_1` selects the
other accepted voice. The new `realtime` launcher profile selects native
streaming Nemotron for English, Apple Translation on macOS 26+, and endpoint
settings that preserve complete sentences in this fixture.

The same 60-second input was run with actual AVAudioEngine speaker playback,
WAV archiving, Apple MT without post-editing, and a 1.15 playback-rate ceiling.
All runs completed. This compares complete configurations, not isolated TTS
model speed. ASR, synthesis, and playback are correlated by `outputID`.

| Measure | MOSS/Ava baseline | Pocket final |
| --- | ---: | ---: |
| Capture / maximum stable ASR updates | 1 s / 3 | 1 s / 16 |
| Output / completed playback count | 41 / 41 | 20 / 20 |
| Accepted transcript to first PCM, mean | 25.281 s | 1.399 s |
| Accepted transcript to first PCM, median | 24.558 s | 0.638 s |
| Accepted transcript to first PCM, p95 | 48.297 s | 4.242 s |
| Accepted transcript to playback dispatch, mean | 27.882 s | 3.796 s |
| First playback dispatch after run start | 2.671 s | 2.338 s |
| Peak output / playback queue | 19 / 2 | 2 / 2 |
| Generated and completed PCM | 103.360 s | 61.110 s |
| Peak pending PCM | 7.600 s | 8.000 s |
| Run completion | 115.953 s | 68.086 s |
| ASR word edits / 185 reference words | 3 | 3 |

These are software timestamps. Accepted-transcript latency begins after ASR
endpointing, not when the person starts speaking. Playback dispatch precedes
the sink's startup buffer and physical speaker output. Synthesis first-PCM
timings also include waiting for playback capacity; the earlier standalone
Pocket voice probes reached first PCM in 0.228-0.240 s. Formal acoustic latency
was not measured.

The benefit is reduced accumulated delay and fewer fragmented translations.
The first audible response is not established to be dramatically faster.
The final run still needs 8.086 s after the 60-second input window to drain;
this is a useful live improvement, not zero-lag simultaneous interpretation.
Twenty WAVs exactly match the twenty result events in byte count, sample rate,
and order. Every output has one first-PCM and completed-playback event.

## Endpoint selection and rejected trials

- A 320 ms capture trial produced 35 ASR word edits and only 161 recognized
  words. The per-call VAD lacks sufficient speech context at this size. Its
  attractive 0.312 s accepted-to-PCM mean does not justify the recognition loss.
- Keeping 1 s capture with an eight-update limit restored the baseline's
  three ASR edits, but split the request before `reach the office`, yielding
  separate, misleading translations. It produced 24 outputs, with a 2.856 s
  accepted-to-PCM mean and 70.849 s completion time.
- The final sixteen-update limit lets native punctuation release complete
  sentences first. The fixture produces its expected twenty sentences. The
  request now reads: `Lütfen raporu Cuma gününden önce gönderin ve ofise
  vardığınızda beni arayın.` This is a profile change, not a change to the
  engine's endpointing algorithm. Long unpunctuated speech can still hit the
  fallback limit and needs broader evaluation.

## Implementation and provenance

`HeptapodPocketTurkishTTSAdapter` validates language and voice, retains a warmed
worker, and forwards every PCM chunk. Request IDs, sample rate and PCM framing
are checked. Monotonic deadlines apply during startup and generation; stream
cancellation terminates the worker and the next request starts cleanly.

The Python bridge uses the upstream Turkish text frontend rather than adding
normalization rules here. Setup pins the Turkish runtime to
`88df358df6b57fb6bddaa82ac7d2d856521b7a20`, Pocket TTS to `3.3.0`, PyTorch to
`2.15.0`, and model weights to `fcbd37c74dc127be846face0ff36062e9a939f7b`.
NumPy in this run was `2.4.6`. All six synthetic voices are available.

[Pocket TTS Turkish](https://huggingface.co/wite-tech/pocket-tts-turkish), by
Wite Tech, derives from [Kyutai Pocket TTS](https://huggingface.co/kyutai/pocket-tts).
Both model licenses are CC-BY-4.0. Attribution and adaptation details are in
the repository README. The runtime code is Apache-2.0.

## Validation and reproduction

- 119 Swift tests passed, including PCM collection, voice changes, broken
  protocol and worker crashes, generation deadlines, cancellation/recovery,
  factory readiness, profile routing, and argument-order overrides.
- 39 Python tooling tests passed, including malformed-request recovery,
  correlation IDs, launcher arguments and Pocket benchmark routing.
- The real `male_1` bridge also synthesized a Turkish date/time/currency sample
  from cached weights with `HF_HUB_OFFLINE=1` and `--offline`.
- Browser/system-audio capture was attempted but macOS rejected the TCC
  Screen Recording permission before capture. The user chose file validation
  for this turn. No successful system-audio run is claimed.

The input is the synthetic Samantha fixture from the earlier latency reports:
37 reference words, repeated five times and padded to 60 seconds, PCM16 mono
at 16 kHz. The 60-second SHA-256 is
`3a2a80d7a8b24d83dbe83e83cd4599db2bad756e7ce569d8ca83ea1e4b0755b5`.
Counts and WER use the ordered concatenated output transcripts and standard
word-level Levenshtein distance, not a repeated-text sequence matcher.

With a built demo and cached models:

```bash
.build/debug/HeptapodLiveSpeechDemo --real --audio /path/to/source60.wav \
  --from en --to tr --latency realtime --asr nemotron --mt apple --tts pocket \
  --chunk-duration 1 --max-buffered-segments 16 --mt-postedit none \
  --duration 60 --max-playback-rate 1.15 --play-output \
  --trace /tmp/pocket-final.jsonl --output-dir /tmp/pocket-final-audio
python3 Tools/trace_summary.py /tmp/pocket-final.jsonl
```

Build/test used the matching Xcode compiler and SDK with SwiftPM's native
backend, as documented in the previous timing report. FlowDeck is absent and
the standard build backend still needs the missing Metal Toolchain. The native
backend emits a deprecation warning; no global settings were changed.

Aggregated evidence is saved in `2026-10-28-pocket-live-en-tr.json`. Raw logs,
traces, input hashes, listening samples, and generated WAVs are under
`/private/tmp/heptapod-live-20261028.bq52d7pb/`; these temporary files may be
removed by the OS. No microphone recordings or user media are included.
