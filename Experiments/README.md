# Experiments

Use this folder to store reproducible local speech translation experiments.

## Folders

- `Fixtures/`: short, licensed input audio clips and reference transcripts.
- `DemoOutputs/`: generated text and audio outputs.
- `Results/`: Markdown reports for each experiment.

Do not commit private user audio or copyrighted long-form media.

## Trace Summaries

Live demo JSONL traces can be summarized as a GitHub-ready Markdown table:

```bash
Tools/trace_summary.py \
  compact=/tmp/heptapod-audio-compact-v10.jsonl \
  quality=/tmp/heptapod-audio-quality-v1.jsonl \
  --examples 1 \
  --compare-examples 3
```

Use labels in the form `name=/path/to/trace.jsonl` when comparing multiple
ASR models or chunk settings. `--compare-examples` prints matching translation
events side by side so ASR and MT regressions are easier to inspect.

## Live Benchmark Runner

Run a repeatable text-only benchmark matrix from one local audio file:

```bash
Tools/run_live_benchmark.py \
  --audio /Users/temelgunaydin/Downloads/output.wav \
  --duration 60 \
  --preset quick \
  --compare-examples 3 \
  --last-examples 3 \
  --repeated-segments 5
```

The runner builds `HeptapodLiveSpeechDemo`, writes each trace/log under a
timestamped `/tmp/heptapod-live-benchmarks/...` directory, and generates a
`report.md` with the same trace summary table format. Summary tables include
audio RMS/peak columns so silent system-audio capture can be distinguished from
VAD or ASR failures. Use `--preset matrix` for the six-case compact/quality and
chunk-duration comparison, or pass custom cases with
`--case label:asr:chunk_duration:max_buffered_segments`.
Audio input can be WAV, M4A, MP3, or CAF if the local audio runtime can decode
it.
Use `--asr-stabilization` to force sliding-window stable-prefix ASR buffering in
text-only benchmark runs.
Use `--punctuation-endpoint` to flush complete ASR sentences before the maximum
buffer limit. Add `--speech-output --tts moss --play-output` to benchmark the
streaming local speech path. Use `--tts chatterbox-mlx` for the quality mode.
Use `--mt apple` to benchmark installed Apple Translation assets or
`--mt madlad` for the model-backed translator. `--mt translategemma` selects
the experimental persistent MLX worker after running
`Tools/setup_translategemma_mlx.sh`.
The summary reports TTS first-audio latency separately from full output latency.
The runner also prepares `mlx.metallib` after SwiftPM build so MLX can load its
Metal kernels at runtime.

Run a repeatable macOS system-audio smoke by playing a local file in Chrome
while the demo captures ScreenCaptureKit audio:

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

The runner opens an isolated Chrome app window and closes only that browser
process group after the run. `afplay` remains the default when
`--playback-browser` is omitted, but it was not visible to ScreenCaptureKit in
the tested configuration.

When `--playback-audio` is used, the runner expects at least one output event by
default. Use `--min-outputs 0` only when you explicitly want to permit a silent
capture run.

On machines where the active Xcode beta SDK is newer than the installed Swift
compiler, the runner automatically builds with the latest compatible macOS SDK
under `/Library/Developer/CommandLineTools/SDKs`.

## Translation Quality Benchmark

Compare translation backends with identical source text, independent of ASR:

```bash
xcrun swift run HeptapodTranslationBenchmark -- \
  --backend apple \
  --input Experiments/Fixtures/en-tr-translation-quality.json \
  --output /tmp/apple-en-tr.json
```

The backend can be `apple`, `madlad`, or `translategemma`. Add `--postedit
glossary --postedit-context 2` to measure the deterministic EN-to-TR post-edit
stage, or `--postedit apple-foundation` to experiment with the on-device Apple
Foundation Model when Apple Intelligence is enabled. The committed 2026-08-09
comparisons and raw outputs are under `Results/`.

The experimental Qwen contextual post-editor runs against an existing raw
translation report:

```bash
Tools/setup_qwen_postedit_mlx.sh

.venv-qwen-postedit/bin/python Tools/qwen_mlx_postedit_benchmark.py \
  --input Experiments/Results/2026-08-09-translation-quality-apple-en-tr.json \
  --output /tmp/apple-qwen-postedit-en-tr.json
```

It is retained for reproducibility and is not a recommended live backend.

## Chatterbox Prosody Matrix

Generate four deterministic Turkish listening samples while loading Chatterbox
only once:

```bash
.venv-chatterbox-mlx/bin/python Tools/chatterbox_quality_matrix.py \
  --output-dir /tmp/heptapod-chatterbox-quality-matrix
```

Add `--voice-prompt /path/to/turkish-reference.wav` to compare the same presets
with a permitted native-language reference voice. Each run writes WAV files and
a timing/parameter manifest.

## Result Template

```markdown
# Experiment: <name>

Date:
Device:
OS:
App/Package commit:

## Pipeline

VAD:
ASR:
Translation:
TTS:

## Input

Source language:
Target language:
Duration:
Fixture:

## Metrics

ASR latency:
Translation latency:
TTS first-audio latency:
End-to-end latency:
Real-time factor:
Installed size:
Peak memory:
Offline: yes/no

## Outputs

Transcript:
Translation:
Audio output:

## Quality Notes

Human score:
Errors:
Good cases:
Bad cases:
Next action:
```
