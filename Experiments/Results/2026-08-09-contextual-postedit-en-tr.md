# English-to-Turkish Post-Edit Comparison

Date: 2026-08-09

## Environment

- Device: MacBook Pro, Apple M3 Max, 64 GB
- OS: macOS 27.0 (26A5388g)
- Input: 24 fixed Apple Translation outputs
- Context limit: previous two accepted source/translation pairs
- Qwen: `mlx-community/Qwen3-4B-Instruct-2507-4bit`
- Qwen cache size: 2.1 GB

This experiment starts from identical Apple Translation drafts. It measures only
the optional post-edit stage, so ASR and base translation differences cannot
affect the comparison.

## Results

| Post-editor | Changed | Preparation | Warm-up | Mean | Median | P95 | Maximum | Quality decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Conservative Qwen 4B | 5/24 | 0.858s | 0.413s | 0.602s | 0.620s | 0.678s | 0.685s | Rejected |
| Source-gated glossary | 9/24 | 0.000025s | n/a | 0.001222s | n/a | n/a | 0.006032s | Accepted for live default |

The first Qwen prompt rewrote too many already-correct sentences. A second
minimal-change prompt left 19 drafts untouched, but three of its five edits
still regressed meaning or grammar:

- `acceptable` changed from `kabul edilebilir` to `kabul edebilecektir`.
- The quality/latency question became grammatically invalid.
- The stable-prefix edit omitted the translation queue entirely.

The glossary changed text only when both the English source phrase and an exact
Turkish draft phrase matched. Its nine edits corrected measured domain terms or
wording such as `ilk koşu`, `kaliteyi takas etmek`, `kalıcı çalışan`, and `sabit
transkript önekleri`. No meaning regression was observed in the fixed fixture.

Apple Foundation Models was also wired into the benchmark. It could not run on
this machine because Apple Intelligence was disabled, so it is not part of the
live default or the latency table.

## End-to-End Check

The final default path was run on a three-sentence fixture with stabilized Qwen
ASR, Apple Translation, the glossary, and neutral Chatterbox MLX:

| Transcripts | Outputs | Repeated MT | ASR avg | MT avg | TTS first avg | First audio avg | Peak queues | Finished |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 3 | 3 | 0 | 0.233s | 0.118s | 1.362s | 1.481s | 1/1 | yes |

The glossary changed `Çevrilen ses net ve doğal gelmelidir.` to `Çevrilmiş ses
net ve doğal duyulmalı.` before synthesis. All three sentences reached output.

## Decision

- Keep Apple Translation as the preferred EN-to-TR base translator.
- Enable the deterministic source-gated glossary in the live CLI by default.
- Use the bounded two-item context for deterministic technical-term consistency.
  Context is tagged and filtered by language pair, and concurrent calls are
  serialized so accepted history stays in source order.
- Select this terminology profile only for EN-to-TR. Other language pairs keep
  the generic pipeline but bypass the Turkish rules.
- Do not attach Qwen to live translation.
- Keep Qwen and Apple Foundation Models as explicit experiments only.
- Permit `--mt-postedit none` for raw backend comparisons.

The contextual terminology update was regression-tested on 2026-08-10. All 24
fixed EN-to-TR outputs remained byte-for-byte identical to the accepted glossary
report; the final verification averaged 0.0062 seconds and reached 0.0093
seconds maximum. Dedicated tests verify matching-context reuse, language-pair
isolation, whole-word replacement, and concurrent context ordering.

## Reproduction

Glossary:

```bash
xcrun swift run HeptapodTranslationBenchmark -- \
  --backend apple \
  --postedit glossary \
  --postedit-context 2 \
  --input Experiments/Fixtures/en-tr-translation-quality.json \
  --output /tmp/apple-glossary-en-tr.json
```

Qwen experiment:

```bash
Tools/setup_qwen_postedit_mlx.sh

.venv-qwen-postedit/bin/python Tools/qwen_mlx_postedit_benchmark.py \
  --input Experiments/Results/2026-08-09-translation-quality-apple-en-tr.json \
  --output /tmp/apple-qwen-postedit-en-tr.json \
  --context-limit 2
```

Committed raw outputs:

- `2026-08-09-postedit-apple-glossary-en-tr.json`
- `2026-08-09-postedit-apple-qwen3-4b-en-tr.json`
