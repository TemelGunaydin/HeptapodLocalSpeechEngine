# MOSS-TTS-Nano vs Chatterbox MLX: English to Turkish

Date: 2026-07-15

## Environment

- Device: MacBook Pro, Apple M3 Max, 64 GB
- OS: macOS 27.0 (26A5378j)
- Base commit: `e452e20` plus the TTS architecture changes in this worktree
- Pipeline: Silero VAD, Qwen3 ASR 0.6B 4-bit, MADLAD-400 3B
- Input: 5.608 seconds, English, 16 kHz mono PCM16 WAV
- Target: Turkish
- Endpointing: balanced, 1.0 second chunks, four-segment limit, punctuation endpoint

## Results

| Backend | Output | ASR ready | First audio after ASR | Full output after ASR | Output duration |
| --- | --- | ---: | ---: | ---: | ---: |
| MOSS-TTS-Nano ONNX | 48 kHz mono | 0.196s | 1.400s | 3.356s | 6.480s |
| Chatterbox MLX FP16 | 24 kHz mono | 0.186s | 3.477s | 3.477s | 5.040s |

The transcript and MADLAD translation were identical in both runs. MOSS exposed
playable PCM about 1.96 seconds before its complete waveform was ready.
Chatterbox MLX does not stream audio, but its warm model inference ran faster
than playback: separate direct tests measured RTF 0.44-0.51. The previous
PyTorch/MPS Chatterbox worker averaged roughly 23 seconds and is no longer the
recommended quality path.

## Text

```text
ASR: Today we are testing Local live translation the translated voice should sound clear and natural.
MT:  Bugün Yerel canlı çeviri test ediyoruz. Çevirilen ses açık ve doğal seslenmelidir.
```

## Commands

```bash
Tools/setup_moss_tts_nano.sh
Tools/setup_chatterbox_mlx.sh

.build/debug/HeptapodLiveSpeechDemo \
  --real --audio /private/tmp/heptapod-live-input.wav --to tr \
  --tts moss --output-dir /private/tmp/heptapod-moss-e2e \
  --trace /private/tmp/heptapod-moss-e2e.jsonl \
  --latency balanced --chunk-duration 1 --max-buffered-segments 4 \
  --punctuation-endpoint

.build/debug/HeptapodLiveSpeechDemo \
  --real --audio /private/tmp/heptapod-live-input.wav --to tr \
  --tts chatterbox-mlx --output-dir /private/tmp/heptapod-chatterbox-mlx-e2e \
  --trace /private/tmp/heptapod-chatterbox-mlx-e2e.jsonl \
  --latency balanced --chunk-duration 1 --max-buffered-segments 4 \
  --punctuation-endpoint
```

## Decision

- Default live mode: MOSS-TTS-Nano, true PCM streaming, CPU ONNX.
- Quality mode: Chatterbox MLX, persistent worker, Metal inference.
- Keep the old PyTorch Chatterbox backend only as a reference/debug option.
