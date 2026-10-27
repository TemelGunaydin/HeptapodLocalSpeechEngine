# Live latency: separate timings for outputs sharing a capture index

Date: 2026-10-27. Starting HEAD: `dc2a1d623ee5b671b9ca270cc61e9821c2617b57`.

## Observed defect and reproduction

The prior voice reports identified multiple distinct outputs attributed to one
capture index. The demo kept most timestamps in `[Int: Date]` dictionaries,
allowing a later output to overwrite an earlier output's accepted-transcript,
stage, or playback timestamps. The prepared-translation timestamps alone already
used an occurrence queue.

A regression exercises the production `runLiveSession` and JSON-lines recorder
with injected local recognizer, translator, synthesizer, and optional playback
sink. One input, `First complete sentence. Second`, releases the completed
sentence at punctuation and the tail at stream end. The source waits for the
first synthesis to start, then ends after 150 ms; that synthesis waits for the
second translation. Both outputs therefore share capture index 1 while their
accepted times differ.

On the original timing implementation, the first-audio latency was approximately
zero, understating the trace's accepted-input-to-first-audio interval by
**0.1598 seconds**. The test failed after a successful build. With the fix it
passes and the demo reports approximately 0.16 seconds for the first output.
This deliberately delayed test is regression evidence, not model-performance
data or a measured speed improvement.

## Change

- Keep an occurrence record per accepted output and correlate each serial
  stage independently. No core events, inference, endpointing, or audio change.
- Add a per-run `outputID` to output lifecycle trace events; the existing
  `index` still identifies the captured chunk.
- Use monotonic uptime for reported stage/queue durations. JSON trace wall
  timestamps and elapsed fields retain their existing format and clock.
- Start first-audio/output latency at `output_queued`, including text-only
  output latency. Raw ASR deltas do not reset an accepted output's clock.
- Release completed timing records. Streaming playback may complete before
  the result event, so retain the occurrence until both finish.

The tracker lives in the demo target; the engine's public API stays unchanged.
Dedicated demo tests avoid adding an executable dependency to the library tests.
Historical trace duration fields are not repaired retroactively. Correlate old
records by index and occurrence as described in the prior reports.

## Validation

- Red: original demo failed the live-session/trace regression by 0.1598 s.
- Green: **110 Swift tests in 3 suites passed**, including four new test
  functions and both playback/no-playback regression cases. Deterministic
  tests cover MT/TTS/playback overlap, playback finishing before the result,
  text-only deltas, and release of completed timing records.
- **35 Python tooling tests passed**.
- Task diff whitespace check passed. Unrelated `.pi/**` and root agent
  documents remain untouched. No separate agent review was performed.

FlowDeck is not installed. XcodeBuildMCP was attempted: the shell's Swift 6.3.1
with the Xcode macOS 27 SDK failed with `-target-arch-variant` errors; correcting
the compiler exposed the missing Metal Toolchain in the default `swiftbuild`
backend. Swift 6.3.1 with the installed macOS 26.5 SDK also lacked the required
FoundationModels macro plugin. The successful gate used the installed Xcode
compiler and matching SDK with SwiftPM's native backend, without installing
components or changing global settings:

```bash
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
SWIFT_EXEC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
SWIFT_EXEC_MANIFEST=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
  test --build-system native

/opt/homebrew/bin/python3.11 -m unittest discover -s Tools/tests
```

The native backend emits a deprecation warning. The standard `swiftbuild`
route still requires the missing Metal component.

## Remaining latency work

Real-model inference, acoustic latency, and a new full-voice comparison were
not run. `--cache-status` confirms Silero, Qwen compact, MADLAD, and Kokoro are
not cached (0 bytes each); the previous MOSS cache directory is also absent.
No model weights were downloaded or sampling defaults changed.

After restoring the models, repeat the full-voice experiment with the same
fixture and settings and correlate results using `outputID`. Measure accepted
input to first PCM, wait before MT, TTS first PCM, generated audio duration,
and playback backlog. Then isolate sentence/fragment endpointing from synthesis
throughput before changing either; the prior MOSS cap-exhaustion outlier remains
a separate issue. The present patch establishes reliable timing, not lower lag.

Temporary local logs: `/tmp/heptapod-trace-red-native.log`,
`/tmp/heptapod-trace-green-native.log`, `/tmp/heptapod-trace-full-native.log`,
`/tmp/heptapod-trace-python.log`, `/tmp/heptapod-cache-status-native.log`.
