# Stable pacing through the last queued sentence

Date: 2026-10-28. Apple M3 Max, 64 GiB, macOS 27.0.1.
Starting HEAD: `f19b88b86a1c25fc400cbf9d62c93b6143450558`.

## Result

The same 60-second file with actual speaker playback finishes in **61.984 s**,
leaving **1.984 s** of final drain. The baseline reproduced at **2.231 s** of
drain, compared with the preceding report's 2.313 s. The measured reduction
against the reproduced baseline is **248 ms / 11.1%**.

| Measure | Reproduced baseline | Steady pacing |
| --- | ---: | ---: |
| Run completion | 62.231 s | 61.984 s |
| Drain beyond the 60 s input | 2.231 s | 1.984 s |
| Final transcript accepted | 57.458 s | 57.480 s |
| Final transcript accepted to device completion | 4.773 s | 4.503 s |
| Last capture event | 60.462 s | 60.492 s |
| Last capture to device completion | 1.769 s | 1.492 s |
| Outputs / completed playbacks | 20 / 20 | 20 / 20 |
| Generated and completed PCM | 57.084 s | 57.084 s |
| Pending PCM after completion | 0 s | 0 s |
| Peak playback rate | 1.098 | 1.110 |
| Peak playback queue | 2 | 2 |
| ASR word edits / reference words | 3 / 185 | 3 / 185 |

The ordered twenty transcript/translation pairs match exactly. All output IDs
have one first-PCM, playback-start, and playback-completion event. Every WAV
matches the corresponding result's byte count and sample rate. Completed PCM
equals generated PCM within floating-point precision.

## Change and quality constraints

The previous pacing policy held its rate while multiple utterances were
queued, but started slowing as soon as only one remained. That final utterance
could still contain several seconds of delayed speech. The controller now
retains the rate it has already reached while tracked PCM remains, including
within a single long utterance. When device completion drains PCM to zero, it
returns to base speed immediately, even if the backlog notification has not
arrived yet. A new short utterance starts at natural speed.

The model, voice, PCM conversion, quiet-tail filter, sentence segmentation,
translation, pitch processing, acceleration limits, and 1.15 rate ceiling are
unchanged. No audio is dropped or newly trimmed. The deliberate change is to
the tempo policy: uninterrupted audio can retain its attained catch-up pace
until PCM actually drains. This is not a claim that perceived tempo is
identical. The observed peak remains below the existing ceiling.

## Rejected capture experiment

A 640 ms capture trial produced only 181 recognized words and eighteen
outputs, with merged and fragmented sentences and five ASR word edits. It
also finished later, at 63.051 s. It was rejected; the final configuration
retains one-second capture and sixteen buffered stable ASR updates.

Batch Silero VAD resets model state on each detection call. Safe shorter
capture needs streaming VAD context and retained onset audio, rather than
simply reducing the capture interval or weakening silence endpointing. The
current final sentence lacks terminal punctuation and has too little silence
inside its last speech chunk to justify an earlier flush.

## Validation and timing limits

126 Swift tests pass. The pacing regression failed on the old implementation
and passed after the change. Coverage includes holding the final sentence's
rate, a long single utterance, reset with a stale backlog count, natural speed
after a gap, configured ceilings, time-based acceleration, PCM accounting,
and cancellation. Python and model code were unchanged in this step.

The file source uses relative sleeps and accumulates scheduling drift. Its
first chunk is delivered immediately, so it is not an exact simulation of
physical capture timing. Neither replay pacing nor capture size changed in
the final comparison. The final transcript actually arrived 23 ms later in
the improved run, while acceptance-to-device-completion became 270 ms shorter;
the gain is not explained by an earlier replay finish. The table includes
last-capture and acceptance timestamps to make that distinction explicit.

These are software/device-completion measurements for one repeated synthetic
fixture per configuration, not an acoustic-onset or subjective listening
study. Independent model generations need not be bit-identical. System-audio
capture was not repeated. Model preparation remains outside the timed input.

The input, models, and command match the
[continuous-playback report](2026-10-28-continuous-playback-en-tr.md):

```bash
.build/debug/HeptapodLiveSpeechDemo --real --audio /path/to/source60.wav \
  --from en --to tr --latency realtime --asr nemotron --mt apple --tts pocket \
  --chunk-duration 1 --max-buffered-segments 16 --mt-postedit none \
  --duration 60 --max-playback-rate 1.15 --play-output \
  --trace /tmp/pocket-steady.jsonl --output-dir /tmp/pocket-steady-audio
```

Aggregate evidence is in
[`2026-10-28-steady-playback-en-tr.json`](2026-10-28-steady-playback-en-tr.json).
Raw traces, WAVs, and test logs are under
`/private/tmp/heptapod-live-20261028.bq52d7pb/`, using prefixes
`pocket-lastmile-baseline`, `pocket-lastmile-steady`, and the rejected
`pocket-lastmile-640ms`. Temporary artifacts may be removed by the OS.
