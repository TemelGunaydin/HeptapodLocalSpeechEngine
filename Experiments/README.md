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
  --examples 1
```

Use labels in the form `name=/path/to/trace.jsonl` when comparing multiple
ASR models or chunk settings.

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
