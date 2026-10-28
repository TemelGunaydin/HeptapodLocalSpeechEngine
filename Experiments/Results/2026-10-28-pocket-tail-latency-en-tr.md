# Pocket Turkish: reducing accumulated playback delay

Date: 2026-10-28. Apple M3 Max, 64 GiB, macOS 27.0.1.
This follows the [Pocket integration measurement](2026-10-28-pocket-live-en-tr.md)
and uses its final Pocket run as the baseline.

## Result

On the same 60-second input with actual speaker playback, the final drain
decreased from **8.086 s to 4.564 s**, a **3.522 s / 43.6% reduction**.
All twenty source sentences and translations are exactly the same in all
three runs. Every output completed playback, in order, with no pending PCM
at shutdown. The first playback dispatch remains approximately 2.34 s.

| Measure | Baseline | Quiet tails shortened | Tails + sustained catch-up pace |
| --- | ---: | ---: | ---: |
| Run completion | 68.086 s | 65.689 s | 64.564 s |
| Drain beyond the 60 s input | 8.086 s | 5.689 s | 4.564 s |
| Outputs / completed playbacks | 20 / 20 | 20 / 20 | 20 / 20 |
| Accepted transcript to first PCM, mean | 1.399 s | 0.653 s | 0.523 s |
| Accepted transcript to first PCM, p95 | 4.242 s | 2.386 s | 1.859 s |
| Accepted transcript to playback dispatch, mean | 3.796 s | 2.694 s | 2.331 s |
| Accepted transcript to playback dispatch, p95 | 6.717 s | 5.399 s | 4.974 s |
| Generated and completed PCM | 61.110 s | 57.084 s | 57.084 s |
| Peak pending PCM | 8.000 s | 7.519 s | 6.559 s |
| Peak playback rate | 1.15 | 1.15 | 1.15 |
| ASR word edits / reference words | 3 / 185 | 3 / 185 | 3 / 185 |

All configurations use native streaming Nemotron ASR, Apple MT without
post-editing, Pocket `female_2`, one-second capture, sixteen buffered stable
ASR updates, and a 1.15 playback ceiling. Sentence endpointing, text
normalization, model weights, voice, synthesis settings, and pitch handling
are unchanged.

## Changes

`Tools/pocket_turkish_tts.py` now buffers up to 500 ms of trailing PCM at or
below eight PCM16 units, approximately -72 dBFS. At utterance completion it
retains 150 ms after the last louder sample. If another word arrives, all
held samples are released unchanged. Leading silence, interior pauses, and
entirely quiet output are preserved. Speech is emitted immediately; the
filter does not wait for an entire utterance before streaming it.

`HeptapodPlaybackPacing` previously lowered its target rate when remaining
PCM fell below the two-second headroom, even if another utterance was already
queued. It now retains the catch-up rate it has already reached while more
than one utterance remains. The existing speed ceiling and gradual rate
changes remain in place. With one utterance left, the normal duration-based
target applies again; an empty queue resets to the base rate.

## Speech and sentence preservation

- The ordered twenty source/translation pairs match the baseline exactly.
  Recognition still contains three word edits across 185 words, with no new
  sentence splits, missing outputs, or dropped playback.
- Applying the tail filter to the twenty baseline WAVs retains an exact byte
  prefix of each original recording. The removed tail totals 4.072 s; its
  maximum absolute sample is four PCM16 units, approximately -78 dBFS.
- Real model streams for both accepted voices (`female_2`, `male_1`) were
  captured before and after the filter from the same generation. Both a full
  request sentence and a date/time/currency example retain exact byte
  prefixes, including all interior pauses. The removed samples have absolute
  values of at most four PCM16 units. One example needs no shortening.
- Independent model generations can differ slightly. Byte preservation is
  therefore established using the same generated PCM on both sides, rather
  than claiming separate end-to-end renders are bit-identical.

These checks establish that the filter preserves the speech samples. They
are not a new subjective voice-quality score. Playback continues to use the
existing pitch-preserving processing within its previous rate ceiling.

## Validation and reproduction

120 Swift tests and 45 Python tooling tests pass. The pacing regression test
failed before the fix and passed afterward. Tail tests cover quiet word
endings, leading/internal pauses, resumed soft speech, bounded buffering,
different chunk boundaries, and immediate first-speech delivery.

Each final WAV matches its result event's byte count and sample rate. All
twenty output IDs have exactly one first-PCM, playback-start, and
playback-completion event, in order. Completed PCM equals generated PCM.

The fixture is the same synthetic English Samantha recording, repeated five
times and padded to 60 seconds, mono PCM16 at 16 kHz. Its SHA-256 is
`3a2a80d7a8b24d83dbe83e83cd4599db2bad756e7ce569d8ca83ea1e4b0755b5`.

With the demo built and models cached:

```bash
.build/debug/HeptapodLiveSpeechDemo --real --audio /path/to/source60.wav \
  --from en --to tr --latency realtime --asr nemotron --mt apple --tts pocket \
  --chunk-duration 1 --max-buffered-segments 16 --mt-postedit none \
  --duration 60 --max-playback-rate 1.15 --play-output \
  --trace /tmp/pocket-tail-pace.jsonl --output-dir /tmp/pocket-tail-pace-audio
python3 Tools/trace_summary.py /tmp/pocket-tail-pace.jsonl
```

This is one repeated synthetic fixture per configuration, with software
timestamps rather than an acoustic latency measurement. Accepted-transcript
timing starts after ASR endpointing, and first-PCM timing includes playback
backpressure. Startup/model preparation is outside the input window. Broader
conversational recordings may produce different delays. System-audio capture
was not repeated; the user selected file-based validation.

Aggregate measurements and paired PCM checks are in
[`2026-10-28-pocket-tail-latency-en-tr.json`](2026-10-28-pocket-tail-latency-en-tr.json).
Raw traces (`pocket-final`, `pocket-tail`, `pocket-tail-pace`), WAVs, and test
logs are under `/private/tmp/heptapod-live-20261028.bq52d7pb/`; these temporary
files may be removed by the OS.
