# Apple Translation vs MADLAD-400: English to Turkish

Date: 2026-07-28

## Environment

- Device: MacBook Pro, Apple M3 Max, 64 GB
- OS: macOS 27.0 (26A5388g)
- Base commit: `aef7123` plus the translation changes in this worktree
- Pipeline: Silero VAD, Qwen3 ASR 0.6B 4-bit, text-only output
- Input: 9.358 seconds, English, 16 kHz mono PCM16 WAV
- Endpointing: quality profile, 1.0 second chunks, eight-segment limit
- ASR stabilization: six-chunk sliding window, four stable words
- Apple EN/TR language assets: already installed

The input was generated locally with the macOS Samantha voice. Both runs used
the same source WAV and produced the same final ASR text. Translation timings
are warm post-ASR measurements and exclude model startup.

## Results

| Backend | Post-ASR translation | Relative latency |
| --- | ---: | ---: |
| Apple Translation, high fidelity | 0.207s | 1.0x |
| MADLAD-400 3B MLX int4 | 3.423s | 16.5x |

## Text

Source:

```text
Today we are testing Local live translation. The translated voice should sound clear and natural. The book that you recommended yesterday is much better than I expected.
```

Apple Translation:

```text
Bugün Yerel canlı çeviriyi test ediyoruz. Çevrilen ses net ve doğal gelmelidir. Dün önerdiğin kitap beklediğimden çok daha iyi.
```

MADLAD-400:

```text
Bugün yerel canlı çeviriyi test ediyoruz. Çevirilen ses açık ve doğal olmalıdır. Dün tavsiye ettiğiniz kitap beklendiğimden çok daha iyi.
```

Apple was faster and more natural for this fixture. MADLAD's final
`beklendiğimden` is grammatically wrong in context; `beklediğimden` is the
intended form. This is one EN-to-TR fixture, not a broad multilingual quality
claim.

## Chatterbox MLX Integration

The Apple translation path was also run through Chatterbox MLX instead of
text-only output. It produced one valid 24 kHz mono PCM16 WAV:

| Metric | Result |
| --- | ---: |
| First/full Chatterbox audio after ASR | 6.203s |
| Generated audio duration | 6.800s |
| Generated PCM | 326,400 bytes |

This confirms the new MT backend is connected to the complete synthesis queue.
For this long segment, Chatterbox's non-streaming synthesis is now the dominant
post-ASR delay rather than translation.

## Commands

```bash
xcrun swift run HeptapodLiveSpeechDemo -- \
  --real \
  --audio /private/tmp/heptapod-translation-quality-0728.wav \
  --from en \
  --to tr \
  --mt apple \
  --text-only \
  --latency quality \
  --chunk-duration 1 \
  --max-buffered-segments 8 \
  --asr-stabilization \
  --trace /private/tmp/heptapod-apple-translation-0728-quality-v2.jsonl

xcrun swift run HeptapodLiveSpeechDemo -- \
  --real \
  --audio /private/tmp/heptapod-translation-quality-0728.wav \
  --from en \
  --to tr \
  --mt madlad \
  --text-only \
  --latency quality \
  --chunk-duration 1 \
  --max-buffered-segments 8 \
  --asr-stabilization \
  --trace /private/tmp/heptapod-madlad-translation-0728-quality-v2.jsonl
```

## Decision

- Prefer `--mt apple` for the measured EN-to-TR quality mode when the OS and
  installed language pair support it.
- Keep MADLAD as the model-backed multilingual fallback.
- Preserve sentence punctuation and use wider stable-prefix ASR context for
  quality mode; MT cannot repair missing or prematurely split source text.
