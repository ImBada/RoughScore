# Transcription and separation evaluation

The evaluator measures supplied engine outputs against licensed references. It contains no inference engine and does not infer reference notes from predictions. Related to [#10](https://github.com/ImBada/RoughScore/issues/10); this infrastructure does not close its real quality gate.

Run the deterministic metric/regression tests without network or dependencies:

```sh
python3 -m unittest discover -s Tests/Evaluation -v
python3 scripts/evaluate-transcription.py
python3 scripts/evaluate-transcription.py --require-real-gates
```

The checkout includes pinned derived note references and acquisition/hash metadata, but no audio or engine predictions. The last command exits **2** until required real references and outputs meet the gates. Default mode writes a diagnostic report and exits 0 even when the report is BLOCKED; do not use its process exit alone to approve a release. Invalid input exits 2. A missing output is SKIPPED, whereas an explicitly supplied empty note array is measured and fails recall. Synthetic success never contributes to a real slice gate. `PASS` means the specified numerical gates/coverage, not listener usability or broad musical correctness.

## Explicit lawful acquisition

[GuitarSet v1.1.0](https://zenodo.org/records/3371780) provides acoustic guitar audio, string-derived note/pitch-contour JAMS annotations and metadata. The [publisher metadata](https://zenodo.org/api/records/3371780) declares **CC-BY-4.0**. Attribution and known annotation exclusions are in [guitarset-acquisition.json](guitarset-acquisition.json). Code license is not used as a substitute for dataset permission.

```sh
python3 scripts/fetch-evaluation-fixtures.py \
  --destination /private/tmp/roughscore-evaluation-guitarset --download
python3 scripts/evaluate-transcription.py \
  --manifest /private/tmp/roughscore-evaluation-guitarset/evaluation-manifest.json \
  --output /private/tmp/roughscore-evaluation-report.json
```

Without `--download` the fetcher returns SKIPPED and creates no destination. This explicit command fetches approximately **696 MB** (annotations and microphone archive); there are no restricted model weights. It verifies the pinned archive size/publisher MD5 and pinned SHA256 (recorded by the first verified acquisition), and records SHA256 for both archives, selected audio/JAMS members and derived files. A fresh/owned destination is required, existing unrelated files are not overwritten, and ZIP member paths/symlinks/oversized entries are checked. The checked-in [reference lock](guitarset-reference-lock.json) records the actual two acquired smoke cases and all hashes. Derived note references in `References` are CC-BY-4.0 GuitarSet adaptations, not predicted notes. Use a fresh destination to regenerate references; verified archives may be copied to its owned `archives` directory to avoid re-downloading. Files in `Tests/Fixtures/downloads` are ignored if that explicit destination is preferred. CI does not download audio silently.

The fetcher derives at most one 5 s acoustic mono and one chord smoke window from performer 00, selecting the first matching reference-only window in sorted track order. It never selects based on engine success. MIDI is rounded to the nearest semitone; original annotated MIDI, onset/end and source JAMS are retained, and crop origin/hashes are recorded. A window containing simultaneous reference notes cannot be relabeled mono. The notes' times are **crop-local seconds**; the manifest also records original recording offset. `lane=left` identifies a mono evaluation channel, not a panned guitarist.

These small real smoke references are **not a representative quality benchmark**. GuitarSet has known timing errors in two recordings and a duplicate-note report; those tracks are excluded rather than silently repaired. Its annotations were largely generated from string pickups and are fallible. [Basic Pitch's training configuration](https://github.com/spotify/basic-pitch/blob/9991303bba609a3b93089d13ec80d1d495083596/basic_pitch/constants.py) includes GuitarSet, so results for that model here cannot be advertised as unseen-data evidence. No distortion, bends/slide-specific labels, real dual-guitar/panning or band-mixture guitar ground truth is claimed acquired by this fetcher.

## Engine export contract

Provide an evaluation manifest with `schema_version: 1`, a name and `cases`. Each case has a unique `id`, `material: real|synthetic`, a slice (`clean_mono`, `clean_chords`, `distortion`, `bends_slides`, `dual_guitar_panning`, or `separation`), `license`, `source`, and `reference_method`. Artifacts have relative `path` and lowercase `sha256`; path traversal or a changed hash is BLOCKED. Note references are JSON `{"schema_version":1,"notes":[...]}`. A note has `onset` (nonnegative seconds), `midi` (integer 0–127) and `lane` (`left` or `right`, default left). Predicted onset-only candidates may have `midi:null`; they contribute to onset-only recall but never count as a correct pitched note.

Predictions are a separate JSON file:

```json
{
  "schema_version": 1,
  "engine": {
    "id": "actual-engine-name",
    "version": "actual-version",
    "qualification_rule": "Describe the actual diagnostic threshold; not a probability",
    "settings": {}
  },
  "cases": [{
    "id": "exact-manifest-case-id",
    "input_sha256": "SHA256 of this case's audio_input",
    "notes": [{"onset": 1.013, "midi": 40, "lane": "left", "qualified": true}]
  }]
}
```

`input_sha256` is required whenever the reference case specifies `audio_input`. `qualified` is an explicit engine decision; it must be present on every prediction for the clean-mono gate. Do not convert an amplitude or periodicity score into a calibrated probability. Use the real engine's qualification policy and record it in provenance. Missing `notes` means unavailable, not zero detections; present `[]` is zero detections.

```sh
python3 scripts/evaluate-transcription.py --manifest path/evaluation-manifest.json \
  --predictions path/engine-predictions.json --output path/metrics.json \
  --require-real-gates
```

## Metric and gate definitions

Notes match one-to-one at **50 ms inclusive onset tolerance**, exact MIDI and lane. The assignment maximizes match count, then minimizes total absolute onset error; it can reassign an earlier ambiguous match. Reports include TP/FP/FN, micro precision/recall, signed/absolute matched onset errors, median/p95, onset recall ignoring pitch, qualified precision and qualified reference coverage. Wrong pitches, duplicated guesses, and opposite-lane guesses cannot manufacture true positives. No offset/duration or contour accuracy is asserted by the onset+pitch metric.

The fixed issue #10 gates are unchanged:

- Clean mono: qualified precision **≥90%**, qualified reference coverage (recall of qualified suggestions against *all* reference notes) **≥75%**. All-suggestion recall is also reported; low-quality exhaustive guessing cannot hide abstention behind high precision on one note.
- Clean chords: all-suggestion precision **≥80%**, recall **≥70%**.
- Guitar separation: median real-case SI-SDR improvement over the mixture **≥3 dB**.

Distortion, bends/slides and dual-guitar/panning must each have measured real reference/output coverage. No extra numerical threshold for those slices was invented: the original issue provides none. Their metrics and failures are separate from the fixed clean gates. Missing cases in a present slice make its gate BLOCKED, even if another case succeeds. Unsupported/missing slices prevent overall release PASS.

For source evaluation a case supplies `guitar_reference` and `mixture` WAV artifact descriptors. Its prediction supplies a `guitar_estimate` descriptor relative to the prediction file. WAVs must have equal sample rate, mono/stereo channel count and frame count, explicitly aligned at the same gain convention; the evaluator does not resample, search for the best lag, trim, downmix or correct a channel swap. It accepts PCM 8/16/24/32-bit and float32/64 RIFF WAV and reads bounded chunks.

[SI-SDR](https://arxiv.org/abs/1811.02508) removes DC independently per channel, then projects the estimate onto the reference with **one shared stereo gain**. Stereo imbalance/swaps remain observable. Improvement is output SI-SDR minus mixture SI-SDR. The bleed proxy projects output onto the known interference after orthogonalizing it against the guitar reference; its energy divided by the target projection energy is reported in dB (**lower is better**). This measures reference-related leakage, not subjective artifacts or every interfering instrument separately. A reference guitar must correspond to a genuine mixture component; an `other` stem is not guitar ground truth.

Perfect reconstruction and zero leakage use JSON-safe explicit positive/negative infinity limits, not invalid JSON `Infinity`. Silent/DC-only references/estimates and no-interference or zero-target-projection baselines have undefined improvement and are BLOCKED. There is no arbitrary noise-floor epsilon that turns a zero-output separator into a passing result.

## Remaining gates

Inference issue #11 and separation #20 have not supplied predictions, so **no actual engine accuracy has been measured** by this PR. Full #10 completion still needs a representative frozen permitted corpus for distortion, bends/slides and dual-guitar/panning, aligned real band guitar-reference mixtures, actual engine exports, failure slices and listener/comfort review. Native MVP work is independent of that release approval.

[model-license-evidence.json](model-license-evidence.json) records the Demucs author restriction and alternative candidates separately. External downloading does not erase a weight-use restriction; no model is selected or downloaded by this evaluation tooling.
