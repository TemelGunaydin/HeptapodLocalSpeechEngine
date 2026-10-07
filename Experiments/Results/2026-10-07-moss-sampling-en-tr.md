# MOSS sampling: bounded termination probe and same-fixture comparison

Date: 2026-10-07. Host: Mac15,9, macOS 27.0 (26A428).
Starting HEAD: `cd150b17bf3a866e6456d989a41a16fa5b3219e0`.
Candidate: adapter/factory/demo sampling option plus tests.
Status: implemented and checked inline; no independent review.

## Narrow outcome

The Python bridge already supports `--sample-mode fixed|full|greedy`. Previously,
Swift always started it with the Python default, so the alternate paths could
not be selected from the live demo or adapter API. The candidate exposes the
existing option without changing inference code or model files:

- Adapter: `sampleMode: HeptapodMossTTSSampleMode = .fixed`.
- Factory: `mossSampleMode: HeptapodMossTTSSampleMode = .fixed`.
- Live demo: `--moss-sample-mode <mode>`, case-insensitive; invalid/missing values
  are rejected before model preparation. The header displays the selected mode.
- The persistent worker receives `--sample-mode <mode>` at startup. The setting
  is immutable for that adapter, not a per-request restart or a fallback retry.

**Default remains `fixed`.** No cap, seed, temperature, playback ceiling,
endpointing, text-normalization, trimming, dependency, or model changes. The
JSON-lines audio/done/error protocol and streamed PCM forwarding are unchanged.
Custom bridge overrides must accept the existing Python `--sample-mode` flag.

## Generation-only diagnosis

The previous investigation found `herkes.` reaching the 375-frame limit without
an observed stop; see [the punctuation/cap report](2026-10-02-late-punctuation-and-moss-cap.md).
Its old `/tmp` raw artifacts were no longer available at the start of this turn.
The measurements below are new, not a reread of those artifacts.

A new probe used the cached runtime, Ava, seed 1234, 8 CPU threads, and the
unchanged 375-frame limit. It prepared/split each input through the existing
bridge path, then called `generate_audio_frames` without codec playback or a
speaker. The probe refused any model-download call. Mode selection was changed
only on this diagnostic runtime instance, not in installed files/defaults.

| Input | Mode | Generated frames | Observed stop flag |
| --- | --- | ---: | --- |
| `herkes.` (repeat 1) | fixed | 375 | none in 375 decisions |
| `herkes.` (repeat 2) | fixed | 375 | none in 375 decisions |
| `Herkes.` | fixed | 13 | false after 13 frames |
| `Herkese günaydın.` | fixed | 20 | false after 20 frames |
| `herkes.` | greedy | 11 | below cap; host sampling path |
| `Herkese günaydın.` | greedy | 19 | below cap; host sampling path |
| `herkes.` | full | 13 | below cap; host sampling path |
| `Herkese günaydın.` | full | 36 | below cap; host sampling path |

In the installed export, greedy/full use host-side token sampling rather than
an available greedy fused-frame session, so the boolean-frame observation
wrapper does not run for them. Their below-cap return indicates that the
runtime's assistant-token branch broke the generation loop; no unobserved
boolean flag is claimed.

For fixed mode, additional pure local-decoder queries sampled the same hidden
states every 25 frames. On the lowercase word, the two-candidate end-token
probability at those samples stayed between approximately `0.000000626` and
`0.00278`. The capitalized input's final sample was approximately `0.638`, and
the sentence control's was `0.909`. These are diagnostic decoder logits, not
proof that the fused sampler is mathematically wrong or that capitalization is
a generally safe remedy. The two lowercase generation-only frame hashes matched
in this probe; PCM or universal deterministic synthesis is not claimed.

Evidence narrows this outlier to input/sampling-path sensitivity, not speaker
accounting. The underlying model/export explanation is still unknown. No
automatic capitalization, mode switching, retry, early stop, or audio discard
was implemented from this small sample.

## Fresh paired 60-second full-voice runs

The original synthetic Samantha fixture was regenerated using the recorded
command. Both hashes matched the previous fixture exactly:

- Original 11.230375 s clip: `93a02fecee39e3a75d53f532e4d88c1d0b99de241015cd27ba6115de8e85b130`.
- Five repetitions plus 3.848125 s zero PCM, mono PCM16/16 kHz/960000 frames:
  `3a2a80d7a8b24d83dbe83e83cd4599db2bad756e7ce569d8ca83ea1e4b0755b5`.

Pipeline: Silero VAD → Nemotron → Apple Translation EN→TR, no post-edit →
MOSS ONNX/CPU/Ava → AVAudio speaker playback + original-rate WAVs. Settings:
balanced, 1 s chunks, 3-segment fallback, 60 s input, playback ceiling 1.15x.

Both runs used the same candidate build through XcodeBuildMCP `swift-package
run --background`, macOS Debug/arm64 with the matching Xcode toolchain. The
first omitted the new flag, exercising the unchanged fixed default; the second
added only `--moss-sample-mode full` (besides new trace/WAV paths). Runs were
sequential with no overlapping diagnostic/test work. Build/launch success was
not used as completion evidence: both traces have `run_finished`, matching
ordered output/playback occurrences, and 41 readable WAVs matching result PCM
byte counts. Managed runs were stopped after completion.

| Metric | Fixed default | Explicit full |
| --- | ---: | ---: |
| Input chunks | 60 | 60 |
| MT inputs / results / completed playbacks / WAVs | 41 / 41 / 41 / 41 | 41 / 41 / 41 / 41 |
| Run duration after preparation | 131.530 s | 126.342 s |
| Generated original-rate PCM / WAV total | 132.480 s | 126.240 s |
| `everyone.` → `herkes.` PCM (output 27, capture 37) | 30.000 s | 1.040 s |
| Peak tracked pending PCM | 23.600 s | 6.720 s |
| Final pending PCM | 0 s | 0 s |
| Peak playback rate | 1.150x | 1.150x |
| Accepted MT input → first PCM mean | 29.375 s | 33.799 s |
| Accepted MT input → first PCM p95 (nearest rank) | 65.818 s | 61.036 s |
| Accepted MT input → first PCM max | 68.563 s | 64.121 s |
| Input queue wait before MT mean | 23.815 s | 28.981 s |
| MT mean | 0.614 s | 0.576 s |
| TTS start → first PCM mean | 2.641 s | 2.001 s |
| First PCM → playback-queue start mean | 2.733 s | 2.537 s |

The ordered capture-index/source-text/translation-text lists are **identical**
between modes. Both accepted streams have 185 normalized words; both differ
from the 185-word reference only at positions 89–91: `please send the` →
`ple sent a`. This is a same-length positional check, not WER, audible-content
verification, or proof of translation accuracy.

Capture index 27 belongs to two distinct outputs in each run. Timing durations
were therefore recomputed from timestamps paired by capture index **and
occurrence**, not taken from potentially overwritten per-index timing fields.

Full removes the measured 30-second word outlier but does not establish a
better default. Two identical translations, `Bugün hava sıcak ve tren öğlen
saatlerinde varıyor.`, each grow from **4.400 s to 12.400 s**. No human listening
validation was performed; the subsequent automated ASR cross-check below also
raises quality concerns. This is not called improved speech quality or faithful
longer speech. The overall run is 5.188 s shorter, yet the average accepted-input-
to-first-PCM wait is 4.424 s longer. Both outputs still greatly exceed 60 s of
source audio.

**Conclusion: useful opt-in comparison path, not a demonstrated general
realtime or model-quality fix.** One run per mode, one repeated synthetic voice,
fixed run order, and uncontrolled cold-start/system variance limit conclusions.
No same-fixture OpenAI comparison, acoustic latency measurement, or air-gapped
validation was performed. `HF_HUB_OFFLINE=1` was present in both product launches
but does not enforce offline mode in the Swift loader; Hub metadata traffic
remains possible. No model/dependency downloads were requested for this work.

## Whole-file Turkish ASR cross-check

After the user asked to continue, four existing output WAVs were each recognized
by the already cached Qwen compact (0.6B/4-bit) and quality (1.7B/8-bit) adapters.
A temporary Swift diagnostic target used `offlineMode: true`, language hint
`tr`, whole-file 16 kHz audio loading, and direct `transcribe`. No VAD, live
sliding-window stabilizer, MT, TTS, speaker, or private capture was used in this
check. Avoiding live 2-second chunking removes that additional segmentation
confound. It does not turn either ASR model into ground truth.

For output 2, expected text is `Bugün hava sıcak ve tren öğlen saatlerinde
varıyor.`; for output 27 it is `herkes.`:

| Output / mode | Compact ASR | Quality ASR |
| --- | --- | --- |
| 2 / fixed, 4.4 s | `Bugün havacık ve tren ölen saatlerinde varıyor.` | `Bugün hava sıcak ve tren ölen saatlerinde varıyor.` |
| 2 / full, 12.4 s | `Bugün hava sıcak ve ve, ken böyle saatlerinde varıyor.` | `Bugün havas sıcak ve ben böyle saatlerin de varıyor.` |
| 27 / fixed, 30 s | `Per kes, de, se, te.` | `Herkes de seyir.` |
| 27 / full, 1.04 s | `Perykips.` | `perçets.` |

Both ASR variants fail to recognize the short full-mode word as expected and
produce substantial mismatches on the long full-mode sentence. Fixed also has
mismatches. These are **quality warning signals**, not proof separating TTS
errors from ASR errors: the models are related variants, the sample is tiny,
and no human transcript/listening annotation exists. The shorter full-mode
output is not accepted as a faithful recovery merely because it terminates.

All eight recognitions completed and were saved with expected text, model ID,
input duration, and path. The first diagnostic launch attempts failed because
the temporary harness did not tolerate the launcher's literal `--` separator;
that harness-only parsing was corrected before the completed probe. The
production CLI already tolerates this separator. The temporary target/source
was then removed and `Package.swift` restored byte-for-byte (SHA-256
`d4a9cd427c605213967addc5b0eb7392fc87abdc73abda2eb7b2291cb5adbb13`).

## Validation

- Red first: the new default-worker regression built, then failed on the old
  adapter with `workerProtocol("Missing or invalid --sample-mode")`.
- Green: default fixed forwarding plus all three adapter/factory modes passed.
  Isolated stdlib-only fake Python workers encode the selected mode/request
  ordinal in two PCM chunks. Tests assert byte order, chunk boundaries, language,
  sample rate, and reuse across two adapter requests, without loading models.
- XcodeBuildMCP macOS arm64 build passed; **106 Swift tests in 2 suites passed**.
  The three new functions include seven sampling test cases.
- **35 Python tests passed**; Python bridge source is unchanged.
- XcodeBuildMCP CLI checks: full/fixed/greedy help, uppercase FULL, invalid value,
  and missing value. Invalid/missing cases exited with status 1 and the expected
  diagnostic, not a successful model launch.
- Diff whitespace check passed. Work was inline (WORKFLOW OFF); unrelated
  `.pi/**` and root agent documents are not part of the change.

## Reproduction and local evidence

Common live arguments (product launched through XcodeBuildMCP, not directly):

```text
--real --audio <identical-60s-fixture> --from en --to tr --asr nemotron
--mt apple --mt-postedit none --tts moss --tts-python <existing-moss-venv-python>
--tts-script Tools/moss_tts_nano_bridge.py --latency balanced --chunk-duration 1
--max-buffered-segments 3 --duration 60 --max-playback-rate 1.15 --play-output
--trace <new-trace> --output-dir <new-wav-dir>
```

Omit `--moss-sample-mode` for fixed; add `--moss-sample-mode full` for the candidate.
For an isolated bridge comparison (writes WAVs; does not play speaker audio):

```bash
.venv-moss-tts-nano/bin/python Tools/moss_tts_nano_bridge.py \
  --text 'herkes.' --language tr --voice Ava --seed 1234 \
  --sample-mode full --output /tmp/moss-full-word.wav
```

Use `--sample-mode fixed` and a different output path for the control. Do not
lower `max_new_frames` to make a timing result look better.

Local raw artifacts: `/tmp/heptapod-moss-eos.7cgwuU/` (`probe.py`,
`generation-results.json`, fixture/manifest/reference, `fixed.jsonl`, `full.jsonl`,
`fixed-audio/`, `full-audio/`, `comparison.json`, `asr-content.json`,
`content-probe.swift`, diagnostic launch logs, red/green/full test logs,
CLI-check logs and exact launch arguments). These temporary raw files are not
tracked; this report preserves the principal measured results.

Next evidence needed before changing defaults: human listening/content checks
of both short and long synthesized Turkish, broader inputs and repeated runs.
The automated cross-check above is insufficient and does not justify a switch.
Explicit generation-cap status and a non-lossy recovery policy also remain
unimplemented; fixed cap exhaustion is still reported as normal bridge `done`.
