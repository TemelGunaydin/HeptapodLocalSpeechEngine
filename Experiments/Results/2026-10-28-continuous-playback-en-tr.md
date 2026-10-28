# Continuous playback without changing speech or sentence boundaries

Date: 2026-10-28. Apple M3 Max, 64 GiB, macOS 27.0.1.
Starting HEAD: `92acbb596d9f7f76cc121a2af872c183fdfe884e`, with the preceding
Pocket integration and tail-latency changes in the working tree.

## Result

The remaining delay after the 60-second input decreased from **4.539 s to
2.313 s**, a **49.0% reduction**. The reproduced baseline agrees with the
[previous 4.564 s measurement](2026-10-28-pocket-tail-latency-en-tr.md).
The final run uses actual speaker playback and WAV archiving.

| Measure | Reproduced baseline | Continuous playback |
| --- | ---: | ---: |
| Run completion | 64.539 s | 62.313 s |
| Final drain beyond the 60 s input | 4.539 s | 2.313 s |
| Last device playback completion | 64.539 s | 62.313 s |
| Outputs / completed playbacks | 20 / 20 | 20 / 20 |
| Generated and completed PCM | 57.084 s | 57.084 s |
| Pending PCM at completion | 0 s | 0 s |
| Peak pending PCM | 6.559 s | 4.751 s |
| Peak playback rate | 1.150 | 1.098 |
| Peak playback queue | 2 | 2 |
| Next utterance dispatched before prior playback completed | 0 | 13 |
| ASR word edits / reference words | 3 / 185 | 3 / 185 |

All twenty transcript/translation pairs match exactly. Every WAV matches its
result event's byte count and sample rate, and all output IDs have exactly
one first-PCM, playback-start, and playback-completion event, in order.
The sum of completed PCM equals generated PCM within floating-point precision.

## Cause and change

The serial playback queue waited for an entire utterance to finish at the
audio device before sending the next one to the player. Apple's
[`dataPlayedBack` callback](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback)
includes downstream processing and device latency. Waiting for that callback
before supplying the next utterance left the processing path without queued
audio at sentence transitions.

The additive `HeptapodContinuousSpeechPlaybackSink` protocol separates a
scheduling notification from actual playback completion. Once an utterance
is scheduled, the queue may supply the next one. The AV sink retains its
existing one-second buffering threshold and 200 ms scheduling chunks. It
still waits for `dataPlayedBack` for the utterance's final buffer before
returning. Completion events remain ordered and the session drains all of
them before finishing. Existing sinks retain serial behavior.

Buffer identities prevent duplicate retirement when the previous utterance's
completion and the next utterance's buffer-limit wait resume together. A
sample-rate change drains prior audio before rebuilding the graph. The demo's
composite sink forwards scheduling only after its speaker and archive outputs
are ready, and now forwards cancellation to the speaker as well.

Successful stream termination no longer invokes cancellation. This preserves
final playback accounting while the event consumer reads the last completion.
Errors and consumer cancellation still stop pending work.

## Voice and sentence integrity

This step changes scheduling only. Pocket's voice, model, synthesis parameters,
PCM conversion, quiet-tail filter, capture duration, ASR endpointing, translation,
pitch handling, and 1.15 speed ceiling are unchanged. No speech is skipped,
summarized, crossfaded, or newly trimmed. Lower queue pressure allows a lower
peak rate in this fixture.

Independent model renders are not consistently bit-identical, even with the
same seed. Quality preservation here rests on unchanged synthesis/PCM paths,
unchanged sentence content, complete playback accounting, and tests that
forward the exact input PCM through both speaker and archive outputs. This
is not a new subjective voice-quality assessment.

## Validation and reproduction

- 125 Swift tests pass, including scheduling the second utterance while the
  first is gated, bounded pending segments, ordered final drain, cancellation,
  failure after scheduling, and the composite speaker/archive scheduling barrier.
- 45 Python tooling tests pass.
- An initial continuous-playback trial completed in 62.329 s. It exposed the
  normal-termination accounting reset; the final 62.313 s trial uses the
  corrected build and verifies zero pending PCM and all completed samples.

Both measured configurations use native Nemotron ASR, Apple MT without
post-editing, Pocket `female_2`, one-second capture, sixteen buffered stable
ASR updates, and `--max-playback-rate 1.15`. The synthetic Samantha source is
repeated five times and padded to 60 seconds, mono PCM16 at 16 kHz, SHA-256
`3a2a80d7a8b24d83dbe83e83cd4599db2bad756e7ce569d8ca83ea1e4b0755b5`.

```bash
.build/debug/HeptapodLiveSpeechDemo --real --audio /path/to/source60.wav \
  --from en --to tr --latency realtime --asr nemotron --mt apple --tts pocket \
  --chunk-duration 1 --max-buffered-segments 16 --mt-postedit none \
  --duration 60 --max-playback-rate 1.15 --play-output \
  --trace /tmp/pocket-continuity.jsonl --output-dir /tmp/pocket-continuity-audio
python3 Tools/trace_summary.py /tmp/pocket-continuity.jsonl
```

Playback-start timestamps describe software dispatch and can now precede the
previous utterance's completion. They must not be interpreted as audible
onset or compared as acoustic latency. Run completion still includes actual
device playback completion. These measurements cover one repeated file,
not arbitrary conversational audio. Model preparation is outside the timed
input window; system-audio capture was not repeated.

Aggregate evidence is in
[`2026-10-28-continuous-playback-en-tr.json`](2026-10-28-continuous-playback-en-tr.json).
Raw traces and WAVs are under `/private/tmp/heptapod-live-20261028.bq52d7pb/`
with prefixes `pocket-continuity-baseline` and `pocket-continuity-verified`.
Temporary artifacts may be removed by the OS.
