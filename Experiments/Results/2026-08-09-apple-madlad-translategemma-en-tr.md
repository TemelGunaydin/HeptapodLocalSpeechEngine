# Apple Translation vs MADLAD vs TranslateGemma: English to Turkish

Date: 2026-08-09

## Environment

- Device: MacBook Pro, Apple M3 Max, 64 GB
- OS: macOS 27.0 (26A5388g)
- Fixture: 24 fixed English inputs with hand-written natural Turkish references
- Apple Translation: installed on-device EN/TR assets, high-fidelity strategy
- MADLAD: MADLAD-400 3B MLX int4 through speech-swift
- TranslateGemma: `mlx-community/translategemma-4b-it-4bit` through MLX LM 0.31.3
- Decode: deterministic greedy generation
- TranslateGemma cache: 2.1 GB on disk; Python environment: 414 MB

This benchmark bypasses ASR. Every backend receives exactly the same complete
source text, so source segmentation and transcript errors cannot affect the
comparison.

## Latency

| Backend | Preparation | Warm-up | Mean | Median | P95 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple Translation | 0.000s | n/a | 0.071s | 0.043s | 0.052s | 0.460s |
| TranslateGemma 4B 4-bit | 2.601s | 0.329s | 0.400s | 0.414s | 0.443s | 0.452s |
| MADLAD-400 3B int4 | 2.883s | 0.700s | 1.296s | 1.337s | 1.667s | 1.861s |

Apple had one 0.460-second outlier. Its P95 was 0.052 seconds and is more
representative of live sentence latency. TranslateGemma was about 3.2 times
faster than MADLAD by median latency, but about 9.6 times slower than Apple.

## Quality Review

Apple produced the strongest overall Turkish in this fixture. It preserved
meaning and natural Turkish word order on relative clauses, conditionals,
reported speech, numbers, and the two-sentence context case. Its remaining
problems were mostly terminology or spoken-style choices:

- `quality trade` became `kaliteyi takas etmek` instead of `kaliteden ödün vermek`.
- `first run` became `ilk koşu` instead of `ilk çalıştırma`.
- `persistent worker` became `kalıcı çalışan`, losing the technical noun.

TranslateGemma was fast enough for an optional quality stage, but the 4B 4-bit
checkpoint was not reliable enough to replace Apple for EN-to-TR:

- `The translated voice should sound clear and natural.` lost the requirement
  and became `Doğru ve doğal bir ses tonunda çevrilmiş.`
- The latency/quality question became repetitive and unnatural.
- The quoted sentence omitted `she said` and weakened `as soon as`.
- The multi-sentence context output ended with an ungrammatical clause.

MADLAD was both slower and less reliable than Apple. It confused `download`
with `discount` in the quoted-speech case and produced several grammatical
errors such as `kesilmesiz` and `deneyim kabul edilebilir`.

## Decision

- Keep Apple Translation as the default EN-to-TR backend on supported systems.
- Keep MADLAD as the portable model-backed fallback.
- Keep TranslateGemma as an experimental adapter and benchmark target, not as
  the default live translator.
- Keep the second-pass model out of the live path. The follow-up bounded-context
  experiment found that Qwen 4B still regressed meaning, while a deterministic
  source-gated glossary corrected domain terms with negligible latency. See
  `2026-08-09-contextual-postedit-en-tr.md`.
- Use the glossary for measured EN-to-TR terminology fixes and keep the generic
  two-item context interface available for future post-edit experiments.

## Reproduction

```bash
Tools/setup_translategemma_mlx.sh

xcrun swift run HeptapodTranslationBenchmark -- \
  --backend apple \
  --input Experiments/Fixtures/en-tr-translation-quality.json \
  --output /tmp/apple-en-tr.json

xcrun swift run HeptapodTranslationBenchmark -- \
  --backend translategemma \
  --input Experiments/Fixtures/en-tr-translation-quality.json \
  --output /tmp/translategemma-en-tr.json

xcrun swift run HeptapodTranslationBenchmark -- \
  --backend madlad \
  --input Experiments/Fixtures/en-tr-translation-quality.json \
  --output /tmp/madlad-en-tr.json
```

Committed raw outputs:

- `2026-08-09-translation-quality-apple-en-tr.json`
- `2026-08-09-translation-quality-translategemma-en-tr.json`
- `2026-08-09-translation-quality-madlad-en-tr.json`
