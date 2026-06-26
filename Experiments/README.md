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
`report.md` with the same trace summary table format. Use `--preset matrix` for
the six-case compact/quality and chunk-duration comparison, or pass custom cases
with `--case label:asr:chunk_duration:max_buffered_segments`.
Audio input can be WAV, M4A, MP3, or CAF if the local audio runtime can decode
it.
The runner also prepares `mlx.metallib` after SwiftPM build so MLX can load its
Metal kernels at runtime.

On machines where the active Xcode beta SDK is newer than the installed Swift
compiler, the runner automatically builds with the latest compatible macOS SDK
under `/Library/Developer/CommandLineTools/SDKs`.

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
