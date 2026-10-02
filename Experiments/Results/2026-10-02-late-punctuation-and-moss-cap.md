# Late sentence punctuation and the MOSS generation-limit outlier

Date: 2026-10-02
Baseline: `d094c6d66f17af025b828a2a69a1c7bea63b15bb`.
Candidate: change to `HeptapodLiveSpeechSession.swift`'s
`SlidingASRStabilizer.commitDelta`, with regression tests.
Status: implemented and checked inline; **no independent review**.

## Scope and correction

A recorded Nemotron partial changed already accepted `Good morning everyone`
to `Good morning everyone. The we`. Once the period was stable, the next
accepted delta was `The`, not `. The`. The adapter's partial already contained
the period: this example loses it in the stable-prefix-to-delta conversion.

Previously, `newTerminalPunctuation` compared the complete new hypothesis to
all committed words and required equal word counts. That can detect a final
period added without new words, but not a boundary on the last committed word
while the hypothesis grows.

The candidate compares the **matched committed span**, excluding tolerated
leading corrections and the new suffix. If that span gains stable terminal
punctuation, it emits the punctuation before the new words. It neither replays
committed words nor changes public events, queue policies, models, or defaults.

This is deliberately an append-only boundary correction. A period added to an
older internal word after subsequent words have already been emitted cannot be
inserted there by this change. It is not moved to the wrong location. General
revision of already emitted text/audio remains outside this patch.

Tests cover six supported terminal punctuation marks in speech/text-only modes,
final-tail delivery at silence and stream end, tolerated leading corrections,
already emitted boundaries, transient punctuation, and no relocation of older
internal punctuation. Existing streaming/cancellation/ordered-queue tests pass.

## Same-fixture full-voice comparison

Pipeline: Silero VAD → Nemotron CoreML streaming ASR → Apple Translation EN→TR
(no post-edit) → MOSS-TTS-Nano ONNX/CPU, voice Ava → AVAudio speaker playback
and original-rate WAV archive. No microphone/system capture or OpenAI request.

Settings: balanced, 1 s chunks, 3-segment buffer fallback, playback ceiling
1.15x. No TTS parameters, speed ceilings, or audio-trimming settings changed.

Fixture construction: repeat the synthetic 11.230375 s Samantha recording from
[the ASR comparison](2026-09-30-nemotron-qwen-asr-en.md) five times, then pad
3.848125 s of zero PCM to exactly 60 s. This preserves all five repetitions
instead of cutting the last sentence. Mono PCM16, 16 kHz, 960000 frames.

- Source fixture SHA-256: `93a02fecee39e3a75d53f532e4d88c1d0b99de241015cd27ba6115de8e85b130`.
- 60 s fixture SHA-256: `3a2a80d7a8b24d83dbe83e83cd4599db2bad756e7ce569d8ca83ea1e4b0755b5`.
- Reference: the same 37-word text repeated five times (185 words).

Host: Mac15,9, macOS 27.0 (26A428). Both product runs used XcodeBuildMCP
`swift-package run --background` with the matching Xcode toolchain, macOS Debug
destination. Build/launch success was
checked separately from actual `run_finished`, ordered playback completions,
and readable WAVs. Managed process registrations were stopped after completion.

| Metric | Before | After |
| --- | ---: | ---: |
| Input chunks | 60 | 60 |
| MT inputs / results / completed playbacks / WAVs | 35 / 35 / 35 / 35 | 41 / 41 / 41 / 41 |
| Run duration after preparation | 127.971 s | 132.473 s |
| Generated original-rate PCM (also WAV total) | 125.920 s | 132.480 s |
| Peak tracked pending PCM | 24.680 s | 23.840 s |
| Final pending PCM | 0 s | 0 s |
| Peak playback rate | 1.150x | 1.150x |
| Accepted MT input → first PCM mean | 26.323 s | 30.140 s |
| Accepted MT input → first PCM p95 (nearest rank) | 63.816 s | 66.448 s |
| Accepted MT input → first PCM max | 64.525 s | 69.214 s |
| Input queue wait before MT mean | 20.029 s | 24.474 s |
| MT duration mean | 0.697 s | 0.716 s |
| First PCM → playback-queue start mean | 3.046 s | 2.769 s |

The first outputs are better delimited: the candidate translates `Good morning
everyone.` as `Herkese günaydın.`, then `The weather is warm today and the
train arrives at noon.` as a separate sentence. The baseline's first output
combined both with an unfinished `Please send`. Later candidate outputs still
contain fragments; this patch does not solve endpointing generally.

**There is no demonstrated speed gain.** This single candidate run generated
more segments/audio, finished 4.502 s later, and had longer average wait to first
PCM. Both runs still contain one 30 s `herkes.` output. Cold-start/system load
and model variability were not controlled; there is one run per version.
Neither the result count nor a passing correctness test establishes realtime
quality or speed.

Both accepted streams have the same 185 normalized words in the same order.
They both differ from the reference at positions 89–91: `please send the` →
`ple sent a`. All other positions match. This is a same-length positional
comparison, not a WER claim or proof of translation accuracy. Generic sequence
matching can misalign distant identical repetitions in this fixture.

All generated results reached playback completion in order. The candidate has
two distinct outputs attributed to capture index 27, not duplicate content.
Because some demo timing dictionaries are keyed only by capture index, the table
recomputes durations from event timestamps paired by **index and occurrence**
in each serial stage, rather than trusting overwritten per-index timing fields.

## MOSS outlier: bounded reproduction, no runtime fix

The baseline `everyone.` → `herkes.` result produced exactly 30.000 s of PCM.
The candidate produces another such result (at index 37). To distinguish
playback accounting from actual generation, the existing Python bridge was
also exercised directly, without speaker playback or concurrent benchmark work.

The probe uses the existing MOSS cache/runtime, voice Ava, fixed sampling,
seed 1234 and 8 CPU threads, and calls the same `stream_synthesis` function.
Observation-only in-process wrappers forward every frame decision, generated
frame array and prepared text unchanged. No runtime/model files or generation
parameters are edited, and no dependencies or model weights are installed.

| Input | Repetition | Generated frames | `should_continue = false` observed | PCM duration |
| --- | ---: | ---: | ---: | ---: |
| `herkes.` | 1 | 375 | 0 | 30.000 s |
| `herkes.` | 2 | 375 | 0 | 30.000 s |
| `Herkese günaydın.` | 1 | 20 | 1 | 1.600 s |

The loaded manifest sets `max_new_frames = 375`. The codec's downsample rate is
3840 samples/frame at 48000 Hz: `375 × 3840 / 48000 = 30 s`.
`OrtCpuRuntime.generate_audio_frames` iterates up to that cap; these two word
probes returned `should_continue = true` on all 375 decisions. The sentence
control returned false after 20 generated frames. The bridge forwards those
frames and does not separately report whether generation stopped normally or
exhausted its cap.

This proves **cap exhaustion with no stop observed in the measured frame
window**, not a playback-rate bug or a known linguistic/model root cause. It
does not prove the model could never stop, that every short input fails, or
that lowering the cap would preserve speech. The two word PCM hashes differ
despite the same seed; bit-identical synthesis is not claimed. Listening/EOS
logit analysis and a safe recovery policy remain unperformed. No audio is
silently trimmed, dropped, retried or replaced by this patch.

## Validation and limits

- Regression first: the three late-boundary test functions failed on the old
  source after a successful build (punctuation/early-output assertions).
- After the patch: XcodeBuildMCP macOS arm64 package build passed; **103 Swift
  tests in 2 suites passed** (six new test functions, parameterized cases
  included). **35 Python tests passed**.
- `Tools/run_focused_core_tests.sh`: six checks passed after explicitly setting
  the matching Xcode `SDKROOT`. The initial SDK-unset attempt failed with
  `unable to load standard library for target arm64-apple-macosx27.0.0`.
  This is recorded as an environment correction, not a source fix.
- Trace drain, ordered outputs, PCM/WAV totals and the bounded MOSS probe passed.
- Software timestamps do not measure physical first-audible speaker latency or
  meaning-aligned source-word delay. The file source yields its first chunk
  immediately, then uses 1 s intervals; it is not a microphone capture clock.
- Offline enforcement/network-disabled validation was not performed.
  `HF_HUB_OFFLINE=1` in the launch environment does not force the Swift Hub
  loader offline; cached-model preparation can issue metadata requests.
- WORKFLOW OFF: work was implemented and checked inline without delegation or
  an agent/model switch. No independent review is claimed.

## Reproduction and local evidence

Use XcodeBuildMCP `swift-package run --background`, macOS Debug, with
`PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH`.
The argument array in each trace records the exact launch; common arguments:

```text
--real --audio /tmp/heptapod-voice-baseline-3vr3bz6b/nemotron-en-60s.wav
--from en --to tr --asr nemotron --mt apple --mt-postedit none --tts moss
--tts-python /Users/temelgunaydin/Projects/HeptapodLocalSpeechEngine/.venv-moss-tts-nano/bin/python
--tts-script /Users/temelgunaydin/Projects/HeptapodLocalSpeechEngine/Tools/moss_tts_nano_bridge.py
--latency balanced --chunk-duration 1 --max-buffered-segments 3 --duration 60
--max-playback-rate 1.15 --play-output --trace <trace> --output-dir <audio-dir>
```

Local artifacts, not committed:

- Baseline: `/tmp/heptapod-voice-baseline-3vr3bz6b/` (`baseline.jsonl`, `audio/`,
  fixture, reference, manifest, initial diagnosis).
- Candidate/probe: `/tmp/heptapod-late-punctuation.8SFEUG/` (`after.jsonl`,
  `audio/`, `before-after.json`, `occurrence-paired-timings.json`,
  `probe_moss_outlier.py`, `moss-probe-results.json`, probe WAVs and launch logs).
- Gates/boundary: `/tmp/heptapod-late-punctuation-boundary.1izRIp/`
  (`red-punctuation-tests.log`, `green-streaming-tests.log`, `build.log`,
  `full-swift-tests.log`, `python-tests.log`, `focused-core-tests*.log`,
  task-only patches and original unrelated-file hashes).

Remaining work: separately design and test a non-lossy response to MOSS
generation-cap exhaustion and revisit fragment endpointing. These are not solved
by the punctuation patch. Independent review is also not part of the evidence
collected in this inline session.
