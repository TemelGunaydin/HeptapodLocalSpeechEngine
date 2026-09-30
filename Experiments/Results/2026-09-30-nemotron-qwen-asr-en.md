# Experiment: Nemotron streaming ASR vs Qwen compact/quality on one English fixture

Date: 2026-09-30
Device: Mac15,9 (Apple Silicon, arm64)
OS: macOS 27.0 (build 26A428)
App/Package commit: `de9d0f4d8b5d5bcf5920286c84f93c41675b2d5c`
(product binary built from HEAD sources; the working tree only contains the
benchmark tooling/docs changes for this task)

Purpose: Adapter Roadmap item 8 remaining work — compare EN quality and latency
of Nemotron streaming ASR against Qwen compact/quality on the same WAV fixture.

## Pipeline

Flow: audio chunk source -> live session -> VAD -> ASR -> MT (text-only)

- VAD: Silero VAD v5 CoreML (`aufklarer/Silero-VAD-v5-CoreML`). No
  `silence_skipped` events fired in any run (continuous speech).
- ASR: per run below.
- Translation: Apple Translation EN->TR, `--mt-postedit none` (no post-edit) to
  isolate ASR overhead from TTS/post-edit stages.
- TTS: none. `--text-only`; no playback, microphone, or system audio.

### ASR backends

| Case | Model ID | Runtime | Status here |
| --- | --- | --- | --- |
| compact | `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` | MLX windowed batch ASR | ran |
| quality | `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` | MLX windowed batch ASR | ran (weights fetched 2026-09-30, see Model Download) |
| nemotron | `aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8` | CoreML cache-aware streaming (FastConformer-RNNT) | ran |

## Input

Source language: en
Target language: tr
Duration: 11.230375 s of audio (WAVE, 1 ch, 16000 Hz, Int16)
Fixture: `/tmp/heptapod-asr-bench-en-20260930/en-say-synthetic.wav`
(raw artifacts stay outside git; see Artifacts)

Fixture SHA-256:
`93a02fecee39e3a75d53f532e4d88c1d0b99de241015cd27ba6115de8e85b130`

The fixture is synthetic, machine-generated, plain English; no private or
copyrighted capture is used or committed.

Reference text (exact):

```text
Good morning everyone. The weather is warm today and the train arrives at noon. Please send the report before Friday and call me when you reach the office. We will review the budget numbers together after lunch.
```

Generation command (installed macOS `say` voice, no new dependencies):

```bash
say -v "Samantha (English (US))" -r 170 \
  --file-format=WAVE --data-format=LEI16@16000 \
  -o /tmp/heptapod-asr-bench-en-20260930/en-say-synthetic.wav \
  "$(cat /tmp/heptapod-asr-bench-en-20260930/reference.txt)"
```

## Method

Common settings for every run (identical fixture and duration):

```text
--real --audio <fixture> --from en --to tr --mt apple --mt-postedit none
--latency balanced --chunk-duration 1 --max-buffered-segments 3 --duration 20
--trace <per-run trace> --text-only --asr-stabilization --punctuation-endpoint
```

1.0 s input chunks, 3-segment fallback buffer, sliding-window stable-prefix ASR
buffering and punctuation endpointing enabled. Full fixture processed in each
run; `--duration 20` is an identical upper bound above the 11.23 s fixture.

Execution: product launched **only** through XcodeBuildMCP
`swift-package run --background` (no direct executable, runner real mode,
`xcrun`, `xcodebuild`, FlowDeck, or `simctl`). The Qwen quality weights were
fetched in one **online download step** before its measurement (see Model
Download). All required model files were present in the local caches before
each recorded run (compact and nemotron caches date from 2026-09-22; the six
quality files were verified present after the fetch), and model inference
itself ran locally from those files.

**Offline enforcement caveat (applies to every run in this report):** the
`HF_HUB_OFFLINE=1` exported by the run wrapper does **not** enforce offline
behavior for this Swift model loader. The `speech-swift` dependency does not
read that environment variable; the live demo does not pass `offlineMode` to
`HeptapodSpeechSwiftAdapterFactory.makePipeline`, so the default `false`
flows through the Qwen adapter to `Qwen3ASRModel.fromPretrained` →
`HuggingFaceDownloader.downloadWeights` → `HubApi(useOfflineMode: false)`,
and the Nemotron load path is likewise not configured for enforced offline.
With `useOfflineMode: false` the loader's snapshot setup takes the online
branch even for fully cached models: it performs a repo-file-list API `GET`
(`getFilenames`) and a per-file metadata `HEAD` before returning the cached
files. Network-disabled / end-to-end offline validation was **NOT RUN**;
offline behavior is **not verified** for compact, quality, or nemotron. The
quality cache listing (85 files: paths, sizes, mtimes) is identical before
and after the recorded run — this shows no observed persistent file-size or
mtime changes across the measured run only; it does not prove that no network
access occurred and does not establish bitwise content identity of the files.
Apple Translation uses installed system language assets.

Product preparation — the manual model download and a warmup run that loads
the model (`trace-quality-warmup.jsonl`, see Model Download) — happened
strictly before the recorded traces. Preparation is not measured inference:
every measured number in this report comes from the three recorded per-run
traces only.

Per-run commands (wrapper `/tmp/heptapod-asr-bench-en-20260930/run-asr.sh`,
`<ASR>` = `compact` / `quality` / `nemotron`):

```bash
export HF_HUB_OFFLINE=1
export PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
/opt/homebrew/bin/xcodebuildmcp swift-package run \
  --package-path /Users/temelgunaydin/Projects/HeptapodLocalSpeechEngine \
  --configuration debug \
  --background \
  --json '{"executableName":"HeptapodLiveSpeechDemo","arguments":["--real","--audio","/tmp/heptapod-asr-bench-en-20260930/en-say-synthetic.wav","--from","en","--to","tr","--mt","apple","--mt-postedit","none","--asr","<ASR>","--latency","balanced","--chunk-duration","1","--max-buffered-segments","3","--duration","20","--trace","/tmp/heptapod-asr-bench-en-20260930/trace-<ASR>.jsonl","--text-only","--asr-stabilization","--punctuation-endpoint"]}'
```

Each trace's `command` field records the exact argv of the launched demo.

**`HF_HUB_OFFLINE=1` note:** the wrapper's export line is kept above for
faithful reproduction, but it is **ineffective** for this pipeline's Swift
model loader (see the offline enforcement caveat above) and must not be read
as offline enforcement.

The `PATH` prefix above matches the wrapper and is required to reproduce the
run: it selects the Xcode 27.0 / Swift 6.4 toolchain
(`.../XcodeDefault.xctoolchain`, macOS 27 target). Without it a pre-existing
Swiftly-managed `swift` (Swift 6.3.1, macOS 28 target) is first on the default
`PATH` and would be used instead (toolchain mismatch). This correction is local
to the run wrapper only; no global or repo build configuration was changed.

### ASR latency definition

"ASR accepted-transcript latency" is the trace field
`transcript_ready.resultLatencySeconds`: wall-clock seconds from the input
chunk's `segment_started` event to the emission of the accepted (final or
stable-prefix) transcript attributed to that chunk. It includes chunk
ingestion, ASR inference, and buffering/endpointing decisions; it is not pure
model inference time. `Tools/trace_summary.py` reports the same quantity as
"ASR avg". For Nemotron, `partial_transcript.resultLatencySeconds` uses the
same start reference for growing (not yet accepted) hypotheses.

## Metrics

| Metric | compact | quality | nemotron |
| --- | ---: | --- | ---: |
| Input chunks (`segment_started`) | 12 | 12 | 12 |
| Accepted transcripts (`transcript_ready`) | 5 | 5 | 28 |
| Partial hypotheses (`partial_transcript`) | 0 | 0 | 33 |
| Outputs (`translation_ready`) | 3 | 3 | 7 |
| `run_finished` present | yes | yes | yes |
| ASR accepted-transcript latency min / mean / median / max | 0.007 / 0.222 / 0.265 / 0.337 s | 0.010 / 0.281 / 0.330 / 0.431 s | 0.075 / 0.142 / 0.145 / 0.176 s |
| Partial latency min / mean / max | n/a (no partials) | n/a (no partials) | 0.101 / 0.141 / 0.176 s |
| Repeated output indexes | 0 | 0 (indexes 4/8/12 unique) | 0 |
| Run wall duration after start (trace last event) | 12.507 s | 12.376 s | 12.053 s |
| Peak memory | not measured | not measured | not measured |
| Installed size (local HF cache dir) | 680 MB (approx.) | 2,467,854,870 B ≈ 2.47 GB (measured) | 612 MB (approx.) |
| Required model files present locally before run | yes (cache present since 2026-09-22) | yes (6/6 verified after fetch, see Model Download) | yes (cache present since 2026-09-22) |
| Offline enforcement / network-disabled validation | **NOT RUN** (see Method) | **NOT RUN** (see Method) | **NOT RUN** (see Method) |

House summary table: `Tools/trace_summary.py` gives ASR avg 0.222 s (compact),
0.281 s (quality), 0.142 s (nemotron); MT avg 0.884 s / 0.892 s / 0.485 s;
output avg 0.884 s / 0.892 s / 0.512 s; Finished yes for all three
(`trace-summary.md` in Artifacts).

## Outputs

### Final accepted transcript sequences (in emission order)

compact (5 accepted window transcripts):

```text
Good morning, everyone.
The weather is
warm today, and the
train arrives at noon. Please send the report before Friday.
and call me when you reach the office. We will review the budget numbers together after lunch.
```

quality (5 accepted window transcripts):

```text
Good morning, everyone.
The weather is
warm today, and the train
arrives at noon. Please send the.
And call me when you Reach the office. We will review the budget numbers together after lunch.
```

nemotron (28 accepted stable-prefix fragments, joined):

```text
Good morning everyone The weather is warm today and the train arrives at noon Please send the report before Friday and call me when you reach the office We will review the budget numbers together after lunch
```

### Translations (Apple MT EN->TR, `--mt-postedit none`)

compact (3 outputs; output 1 is the input-index-4 buffer safety-cap flush —
continuation-tail retention drained only the greeting — outputs 2–3 are
punctuation-endpoint flushes):

```text
Günaydın herkese.
Bugün hava sıcak ve tren öğlen saatlerinde varıyor. Lütfen raporu Cuma gününden önce gönderin.
ve ofise vardığınızda beni arayın. Öğle yemeğinden sonra bütçe rakamlarını birlikte gözden geçireceğiz.
```

quality (3 outputs; output 1 is the input-index-4 buffer safety-cap flush of
all 3 buffered windows, outputs 2–3 are punctuation-endpoint flushes of
single windows):

```text
Günaydın herkese. Hava bugün sıcak ve tren
Öğlen saatlerinde varır. Lütfen gönderin.
Ofise vardığınızda beni arayın. Öğle yemeğinden sonra bütçe rakamlarını birlikte gözden geçireceğiz.
```

nemotron (7 fragment-group outputs):

```text
Herkese günaydın Hava bugün sıcak ve tren öğlen saatlerinde varıyor Lütfen gönderin
Cuma'dan önceki rapor
ve beni aradığında
Ofise ulaşacağız
bütçeyi gözden geçirin
sonrasında birlikte sayılar
öğle yemeği
```

## Quality Notes

Word-level comparison against the reference (lowercased, punctuation-stripped
word sequences, ordered alignment, difflib opcodes; substitutions = wrong
words, omissions = dropped words, duplicates = words appearing more often than
in the reference):

- compact: **exact match, 37/37 words, order preserved** — 0 substitutions,
  0 omissions, 0 duplicates.
- nemotron: **exact match, 37/37 words, order preserved** — 0 substitutions,
  0 omissions, 0 duplicates.
- quality: **not an exact match — 34/37 words**, 0 substitutions, **3 omissions,
  0 duplicates**. The contiguous phrase `report before Friday` is dropped: the
  accepted window reads `arrives at noon. Please send the.` where the reference
  has `arrives at noon. Please send the report before Friday and call me...`.
  The accepted stream truncates the phrase mid-NP, leaving a dangling `the.`
  with a spurious terminal period. All 34 accepted words are correct and in
  order; the loss is word omissions only, not wrong words. This is recorded as
  an accepted-stream omission; whether it originates in the model, the
  sliding-window/stabilizer buffering, or the endpointing is not established
  by this single run.

Punctuation/segmentation differences:

- compact inserts commas ("Good morning, everyone.", "warm today, and the") and
  one extra sentence break after "Friday."; 3 of its 5 accepted transcripts end
  in terminal punctuation, while the remaining two ("The weather is",
  "warm today, and the") are mid-sentence windows.
- quality: 3 of its 5 accepted transcripts end in terminal punctuation
  (`Good morning, everyone.`, `arrives at noon. Please send the.`, and the final
  long window); the remaining two (`The weather is`, `warm today, and the
  train`) are mid-sentence windows. Internal sentence punctuation is present in
  the accepted fragments (the period after `noon`). Quality emits no partial
  hypotheses (windowed batch ASR like compact). Artifacts to note: a spurious
  terminal period on the truncated `Please send the.`, an extra sentence break
  after `noon.`, and mid-sentence capitalization flips (`And call me when you
  Reach the office`).
- nemotron's accepted stable-prefix fragments carry no terminal punctuation in
  this run; 0 of its 33 growing partials end in terminal punctuation either.
  The partials do carry internal sentence punctuation (e.g. the period in
  `...arrives at noon. Please`) that the accepted stable-prefix fragments omit,
  so the accepted sequence is punctuation-free; capitalization is consistent.

No WER is reported: no validated normalization/alignment WER pipeline is set up
for this comparison, and a single synthetic fixture would not justify a WER
claim. The exact-text comparison above is qualitative and complete for this
fixture.

MT endpoint grouping observations: under `--latency balanced`,
`minimumWordsForPunctuationEndpoint` is 6 words, and `--max-buffered-segments
3` caps the pending sentence buffer. The first accepted window in the compact
and quality runs (`Good morning everyone`, 3 words) is below the 6-word
threshold, so the completed-prefix drain declines and nothing is emitted at
that point. At input index 4 the 3-segment buffer **safety cap** fires first,
before any punctuation flush: compact's buffered text ends `...and the`, so
the continuation-tail retention drains only the greeting
(`Günaydın herkese.`) and keeps the rest buffered; quality's buffered text
ends `...and the train` (not a continuation tail), so the cap flush drains the
whole 3-window buffer midphrase (`Günaydın herkese. Hava bugün sıcak ve
tren`). Outputs 2–3 in both runs come from later **punctuation-endpoint**
flushes (terminal punctuation with at least 6 words). Nemotron's unpunctuated
accepted fragments were grouped at fragment/buffer boundaries into 7 MT
calls; several fragment translations are incoherent in isolation (e.g.
`Ofise ulaşacağız`, `sonrasında birlikte sayılar`, `öğle yemeği`) and one
continuation starts lowercase (`ve ofise ...` in compact). For compact and
nemotron these are punctuation/grouping artifacts of this endpointing, not
recognition errors (both matched the reference 37/37). The blanket claim does
not hold for quality: its second output (`Öğlen saatlerinde varır. Lütfen
gönderin.`) additionally inherits the accepted-stream omission of `report
before Friday` (see Quality Notes) and renders it as a bare `Lütfen gönderin.`
("please send it"); that omission is a real word loss not explained by
grouping, and its cause (model vs. window/stabilizer buffering) is not
established by this run. Only quality's third output is a coherent
full-sentence translation.

### ASR latency observations

On this fixture Nemotron's accepted-transcript latency was tighter and lower
(mean 0.142 s, max 0.176 s) than compact's window flushes (mean 0.222 s,
max 0.337 s), and Nemotron additionally produced 33 growing partials (first
partials ~0.10 s after chunk start) where compact and quality produced none.
Quality's window flushes were the slowest and widest of the three
(mean 0.281 s, max 0.431 s). Note the minimum latency values (compact 0.007 s,
quality 0.010 s) are the end-of-audio flush of an already-computed window, not
fresh inference. These are single-run fixture observations, not speed
guarantees.

### Confounds and limits

- Run order: compact first (colder caches, 2026-09-30T09:33Z), nemotron second
  (09:34Z), quality third (12:57Z) after the manual model fetch (completed
  12:47:54Z per cache mtime) and one preparation warmup run under a separate
  trace path (12:50Z, see Model Download). One recorded run per ASR, no
  repetitions, model generation/contention not controlled.
- Enforced-offline / network-disabled validation was **NOT RUN** for any case;
  `HF_HUB_OFFLINE=1` in the wrapper does not enforce this loader's offline
  behavior (see Method), so offline operation is unverified here. No
  offline-mode runtime change or airgap test is included in this experiment.
- Fixture is one short, synthetic `say` voice utterance; it does not represent
  natural speech, accents, noise, or long-form use.
- MT endpoint grouping differs per backend (see above) and interacts with
  `--punctuation-endpoint`; translation latency/output counts are therefore not
  an apples-to-apples MT benchmark.
- No universal speed, quality, or realtime guarantees are claimed from this
  fixture.

## Model Download (Qwen quality)

The quality weights were missing from every local cache at the start of this
experiment. After user authorization, they were fetched on 2026-09-30 in one
online download step; afterwards all six required files were verified present
in the loader's own cache directory (table below). Offline behavior was not
enforced or verified for the subsequent runs (see Method).

Model: `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` (public, unauthenticated access),
revision `e5450a26d1fd417c45fc9c405651ddc3180a27a6` (resolved from `main`; all
six per-file metadata entries record this commit hash).

Preparation attempts 1–2 — the app's own loader (dependency
`speech-swift`/`HuggingFaceDownloader`, invoked via managed product runs) —
**failed before producing any trace**. Two managed launches are preserved:
`quality-warmup-cli.log` (launched 11:35:09Z) and `quality-warmup-cli2.log`
(launched 12:21:54Z); both preceded the manual fetch below. The detailed
failure mode (error codes, transferred byte counts, retry behavior) is **not
independently established** from the preserved artifacts; earlier specifics
on those points are removed as unverified. No source mutation was made to
bypass the loader.

Manual fetch (Python, succeeded) — with the **pre-existing** Python
`huggingface_hub` (1.27.0 in `.venv-translategemma`, no new dependencies
installed), unauthenticated public access (`token=False`):

```bash
.venv-translategemma/bin/python3 fetch-quality-hf.py   # snapshot_download
# repo_id="aufklarer/Qwen3-ASR-1.7B-MLX-8bit", revision="main", token=False,
# allow_patterns=["config.json", "model.safetensors", "model.safetensors.index.json",
#                 "vocab.json", "merges.txt", "tokenizer_config.json"],
# local_dir="~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
```

`allow_patterns` matches exactly the dependency loader's required file set
(`Qwen3ASRModel.fromPretrained`'s `additionalFiles: vocab.json, merges.txt,
tokenizer_config.json` plus `HuggingFaceDownloader.downloadWeights`' implicit
`config.json`, `*.safetensors`, `model.safetensors.index.json`) — no README or
other needless assets were fetched. The fetch succeeded and the complete file
set was afterwards verified in the loader's own cache directory with the
standard per-file download metadata (`.cache/huggingface/download/*.metadata`,
commit hash / etag / timestamp, byte-compatible with the Swift loader's
format). Which step wrote each individual file is not independently
established (preserved cache-listing mtimes: `tokenizer_config.json`
11:35:14Z, `model.safetensors.index.json` 11:35:15Z, `vocab.json` 11:39:06Z,
`merges.txt` 11:39:07Z, `config.json` 12:23:35Z, `model.safetensors`
12:47:54Z).

Cache evidence — `~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/`:

| File | Bytes |
| --- | ---: |
| `model.safetensors` | 2,463,307,541 |
| `vocab.json` | 2,776,833 |
| `merges.txt` | 1,671,853 |
| `model.safetensors.index.json` | 78,968 |
| `tokenizer_config.json` | 12,487 |
| `config.json` | 7,188 |
| **total** | **2,467,854,870 ≈ 2.47 GB (2.30 GiB)** |

(The catalog's 3.2 GB footprint estimate is conservative; actual is 2.47 GB.)

Preparation warmup (managed launch 3): `quality-warmup-cli3.log` (launched
12:50:07Z) produced `trace-quality-warmup.jsonl`
(2026-09-30T12:50:14Z–12:50:26Z), which loaded the model and completed with
`run_finished`. This warmup is product preparation before measurement, not a
measured run, and its model-loading/setup phase can perform Hub metadata
requests (see Method). The recorded quality benchmark then ran via the
unchanged `run-asr.sh quality` wrapper at 12:57:04Z–12:57:17Z. The cache
listing (85 files: paths, sizes, mtimes) is identical before and after the
recorded run (`cache-before-recorded.txt` vs `cache-after-recorded.txt`, diff
empty) — evidence of no observed persistent file-size or mtime changes across
the measured run; it does not prove that no network access occurred and does
not establish bitwise content identity of the files.

## Artifacts

Raw artifacts (not committed, outside git):
`/tmp/heptapod-asr-bench-en-20260930/`

- `en-say-synthetic.wav`, `reference.txt` — fixture and reference text
- `trace-compact.jsonl`, `trace-quality.jsonl`, `trace-nemotron.jsonl` — full
  demo traces of the measured runs (each with exact argv in `command`)
- `trace-quality-warmup.jsonl` — the preparation warmup run's trace (separate
  path, product preparation only, not part of the measurements)
- `trace-summary.md` — `Tools/trace_summary.py` output (three traces)
- `run-asr.sh` — exact per-run wrapper (byte-unchanged for all runs)
- download/cache evidence also under `/tmp/heptapod-asr-boundary.Bo0ytk/`:
  - `fetch-quality-hf.py` — manual Python fetch script
  - `quality-warmup-cli.log`, `quality-warmup-cli2.log` — the two failed
    managed preparation attempts (11:35:09Z / 12:21:54Z launches; failed
    before producing any trace)
  - `quality-warmup-cli3.log` — the successful preparation warmup launch
    (12:50:07Z; produced `trace-quality-warmup.jsonl`)
  - `quality-recorded-cli.log` — the measured quality run launch (12:56:58Z)
  - `cache-before-quality.txt`, `cache-before-recorded.txt`,
    `cache-after-recorded.txt` — cache listings

Next action: optionally repeat with natural speech fixtures and with repeated
runs before drawing quality or speed conclusions; the quality run's
accepted-stream `report before Friday` omission on this fixture deserves
attention on more test material. Enforced-offline / airgap validation and any
offline-mode loader change are explicitly out of scope of this experiment and
remain open.
