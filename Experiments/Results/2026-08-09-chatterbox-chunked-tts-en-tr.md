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

## Warm-up and Boundary Follow-up

A follow-up based on commit `4f68ebb` moved one short target-language generation
into worker preparation. The worker now reports ready only after lazy model and
tokenizer initialization completes. Boundary processing also keeps 40 ms of
leading silence and 120 ms of trailing silence, then applies an 8 ms fade at
both PCM edges. Internal pauses are not inspected or removed.

| Run | First audio after ASR | Full result after ASR | Output duration |
| --- | ---: | ---: | ---: |
| Warm-up + boundary trim 1 | 2.067s | 4.800s | 7.960s |
| Warm-up + boundary trim 2 | 2.140s | 5.081s | 7.540s |
| Warm-up + boundary trim average | 2.104s | 4.941s | 7.750s |

The explicit warm-up added 0.853 seconds to model preparation in a direct warm
worker smoke test. It did not improve steady-state inference; it moves lazy
first-request work before capture begins. Chatterbox generation is stochastic,
so first-audio timing varied with generated waveform length.

Compared with the original 6.203-second single-segment baseline, follow-up first
audio remained 66.1% lower and full-result latency was 20.3% lower. Boundary
processing reduced average output duration by 14.6% versus the untrimmed
sentence pipeline, from 9.080 seconds to 7.750 seconds. Both measured aggregate
WAVs began and ended at a zero PCM sample after the edge fade.

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
- Keep the short target-language warm-up in persistent MLX workers so the first
  live translation does not pay lazy initialization costs.
- Keep conservative boundary trim and fade enabled. The quality mode still
  speaks this fixture about 14% longer than the old single-segment output, so a
  real speaker-playback listening test remains necessary before making it the
  default live mode.
