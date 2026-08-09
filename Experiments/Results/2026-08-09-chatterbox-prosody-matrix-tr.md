# Chatterbox MLX Turkish Prosody Matrix

Date: 2026-08-09

## Environment

- Device: MacBook Pro, Apple M3 Max, 64 GB
- OS: macOS 27.0 (26A5388g)
- Backend: Chatterbox Multilingual MLX FP16
- Seed: 42
- Voice prompt: none
- Text: `Bugün yerel canlı çeviriyi test ediyoruz. Çevrilmiş ses net, doğal ve akıcı duyulmalı.`

The matrix loads the model once and synthesizes the same Turkish sentence with
four fixed parameter sets. Inference time and real-time factor measure whether a
setting is viable for live output; selecting the most natural voice still
requires listening to the generated WAV files.

## Results

| Variant | Exaggeration | CFG weight | Temperature | Inference | Audio | RTF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Flat | 0.10 | 0.50 | 0.80 | 2.362s | 4.90s | 0.482 |
| Neutral | 0.50 | 0.50 | 0.80 | 2.385s | 5.02s | 0.475 |
| Deliberate | 0.50 | 0.30 | 0.80 | 2.227s | 4.56s | 0.488 |
| Expressive | 0.70 | 0.30 | 0.80 | 2.260s | 5.12s | 0.441 |

All four variants remained faster than real time, and their compute cost was
close enough that voice quality can determine the final preset. The neutral
upstream defaults (`0.50 / 0.50 / 0.80`) are now the live default instead of the
previous unusually flat `0.10` exaggeration setting.

## End-to-End Check

A three-sentence English fixture was run through stabilized Qwen ASR, Apple
Translation, and the neutral Chatterbox preset:

| Transcripts | Outputs | ASR avg | MT avg | TTS first avg | TTS full avg | Peak queues | Finished |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 3 | 3 | 0.246s | 0.126s | 1.428s | 1.428s | 1/1 | yes |

The first playable audio arrived an average of 1.554 seconds after each ASR
result, including translation and output-queue time. No sentence was dropped or
repeated.

After the deterministic EN-to-TR glossary was enabled, the same fixture reached
first audio in 1.481 seconds on average and produced the more natural second
translation `Çevrilmiş ses net ve doğal duyulmalı.`

## Reproduction

```bash
Tools/setup_chatterbox_mlx.sh

.venv-chatterbox-mlx/bin/python Tools/chatterbox_quality_matrix.py \
  --output-dir /tmp/heptapod-chatterbox-quality-matrix
```

For a permitted native Turkish reference voice:

```bash
.venv-chatterbox-mlx/bin/python Tools/chatterbox_quality_matrix.py \
  --voice-prompt /path/to/turkish-reference.wav \
  --output-dir /tmp/heptapod-chatterbox-quality-matrix-reference
```

The output directory contains one WAV per variant and `manifest.json` with the
exact parameters and timing measurements.
