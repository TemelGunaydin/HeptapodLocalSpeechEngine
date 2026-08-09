# Chatterbox MLX Sentence-Pipelined TTS: English to Turkish

Date: 2026-08-09

## Environment

- Device: MacBook Pro, Apple M3 Max, 64 GB
- OS: macOS 27.0 (26A5388g)
- Commit: `3a90442`
- Pipeline: Silero VAD, Qwen3 ASR 0.6B 4-bit, Apple on-device
  Translation, Chatterbox MLX FP16
- Input: 9.358 seconds, English, 16 kHz mono PCM16 WAV
- Endpointing: quality profile, 1.0 second chunks, eight-segment limit
- ASR stabilization: six-chunk sliding window, four stable words
- Playback sink: WAV file output; `tts_first_audio` measures when the first PCM
  chunk became available, while reported playback duration is file-write time

The fixture and translation match the pre-pipelining measurement from
2026-07-28. The new implementation sends each natural translated sentence to
batch TTS separately. The first sentence can enter the playback stream while
the persistent Chatterbox worker synthesizes the next sentence.

## Text

Source:

```text
Today we are testing local live translation. The translated voice should sound clear and natural. The book that you recommended yesterday is much better than I expected.
```

Apple Translation:

```text
Bugün yerel canlı çeviriyi test ediyoruz. Çevrilen ses net ve doğal gelmelidir. Dün önerdiğin kitap beklediğimden çok daha iyi.
```

## Results

| Run | First audio after ASR | Full result after ASR | Output duration |
| --- | ---: | ---: | ---: |
| Pre-pipelining baseline | 6.203s | 6.203s | 6.800s |
| Sentence pipeline, cold Metal cache | 4.367s | 7.527s | 9.080s |
| Sentence pipeline, warm cache 1 | 1.850s | 4.879s | 9.080s |
| Sentence pipeline, warm cache 2 | 1.767s | 4.805s | 9.080s |
| Sentence pipeline, warm average | 1.809s | 4.842s | 9.080s |

Against the old single-segment baseline, the warm sentence pipeline reduced
first-audio latency by 70.8% and full-result latency by 21.9%. First audio was
available about 3.4 times sooner.

The first run followed restoration of the local Python 3.11 runtime and paid a
one-time Metal compilation/cache cost. It still improved first audio by 29.6%,
but total synthesis was slower than the baseline. The two subsequent runs used
independent app and Python worker processes and produced closely matching warm
results.

## Command

```bash
HeptapodLiveSpeechDemo \
  --real \
  --audio /private/tmp/heptapod-chatterbox-chunked-input-0809.wav \
  --from en \
  --to tr \
  --mt apple \
  --tts chatterbox-mlx \
  --output-dir /private/tmp/heptapod-chatterbox-chunked-output \
  --trace /private/tmp/heptapod-chatterbox-chunked.jsonl \
  --latency quality \
  --chunk-duration 1 \
  --max-buffered-segments 8 \
  --asr-stabilization
```

## Decision

- Keep natural sentence pipelining for Chatterbox quality mode; it materially
  improves time to first speech without changing the translation.
- Add a short Chatterbox warm-up during model preparation so the first live
  translation does not pay the lazy Metal compilation cost.
- Investigate per-sentence leading/trailing silence before shipping this as the
  default quality path. Independent synthesis increased this fixture's output
  duration from 6.80s to 9.08s, which can make the spoken translation fall
  behind the source.
