# Experimental native monophonic proposals (Related #11)

This is the DSP prerequisite for selected-region note review, not completion of
#11. It does not write TAB or choose frets, rhythms, lanes or note lengths. No
trained model, third-party implementation or weights are involved. The real
quality release gate remains **BLOCKED**: this smoke evaluation fails reference
coverage, polyphony is unsupported, and representative/distorted/dual-guitar
and separation references have not been acquired. The evaluator itself reports
`FAIL` for the measured failed slices and overall gate, and `SKIPPED` for absent
slices; neither means release acceptance.

## Integration interface

```swift
let processor = MonophonicTranscriber()
let proposals = try processor.analyze(
    samples: leftMonoPCM, sampleRate: 48_000, timeOrigin: 0.8,
    isCancelled: { cancellationFlag.isCancelled },
    progress: { fraction in /* dispatch to your UI actor */ }
)
// Independently call the same value with rightMonoPCM for the right lane.
```

Alternatively pass the whole channel buffer with `region: first..<last` and
its buffer's original `timeOrigin`. The processor adds the selected sample
index/sample rate to that origin; it never rounds onsets, resamples time to a
musical grid, merges lanes, or edits any existing project. Calls own their state.
Run on a worker executor, not the main actor. The caller owns safe synchronization
of cancellation/progress and must discard obsolete results when its selection
changes. Cancellation throws `.cancelled` and returns no partial output.

`Proposal` supplies original-seconds `onset`, `audioEnd`, a boundary marker,
measured frequency/continuous MIDI/cents, deterministic periodicity, `qualified`
and an explicit unknown reason. Unknown pitch is nil, not a guessed fret or
rest. An attack at sample zero is marked `onsetIsRegionBoundary`: audio may
already have been sounding before the crop, so this is an activity boundary,
not evidence of a true earlier attack. `audioEnd` is observed amplitude support,
clipped at the next attack or analysis end, with `reachesRegionEnd`; it is not
an annotated note offset or musical duration. A stable periodic signal can be
polyphonic: qualification does **not** classify monophony or guarantee correctness.

Input must be finite signed mono Float PCM, at a finite 8...192 kHz rate, with
finite nonnegative original time and a valid half-open sample range. The
selected region is bounded to 60 seconds. Rates outside the supported range,
nonfinite selected samples, invalid times/settings/ranges and oversized regions
throw distinct errors. Samples outside the requested region are not read. Empty
valid regions return empty results; short attacks return unknown pitch. Invalid
input never becomes an empty successful inference. Progress is monotonic 0...1;
1 is emitted only for a completed result, after the last cancellation check.
Callbacks are synchronous. Cancellation is checked at each <=4 ms input block,
each onset-envelope step, each YIN lag and each sustain-support step.

## Algorithm and frozen settings

Pitch uses the fixed-window squared difference, cumulative mean normalization,
first threshold trough and parabolic interpolation from de Cheveigné and
Kawahara, [YIN (2002), DOI 10.1121/1.1458024](https://www.ee.columbia.edu/~dpwe/papers/deChevK02-yin.pdf).
This implementation is independently written from the paper; it is not pYIN,
a trained detector or a claim of the paper's reported speech accuracy.

- Version: `native-mono-1`; amplitude floor 0.003 RMS, attack ratio 1.7.
- Input DC blocker at 20 Hz; boxcar decimation by `floor(rate/16000)` (at least
  one), with the exact reduced rate retained. This inexpensive prefilter is not
  a steep anti-alias filter; bright/noisy/inharmonic audio remains limited.
- Envelope blocks are `floor(rate*0.004)` samples; a local energy rise over the
  preceding five blocks, with a 1.12 immediate-rise ratio, searches backward
  up to three blocks; minimum attack separation is 80 ms. This misses legato,
  weak reattacks and some close repeats, and can propose fret/noise activity.
- Three 50 ms pitch frames start 20/40/60 ms after the attack, clipped at the
  next attack/region boundary. Frequency search is 65...1400 Hz, A4=440 Hz.
- A frame requires RMS >=0.003 and the first YIN CMNDF trough <=0.10
  (`periodicity = 1 - CMNDF`, >=0.90). Two valid frames must agree within
  0.35 semitones; the closest adjacent frequency pair wins, with ties choosing
  lower Hz, and their geometric mean provides the measured pitch. One unstable
  frame cannot veto two agreeing frames. Fewer than two consistent frames
  gives unknown pitch. This exact rule is also exported in engine metadata;
  its score is **not a calibrated probability**.
- Amplitude support ends after two quiet blocks below max(0.003, 10% of the
  early attack peak), at the next onset, or at the selected-region end.

The first synthetic implementation at ~8 kHz reduction exposed high-fret
subharmonic errors and a dominant-second-harmonic octave error. Increasing the
analysis rate and using a more conservative trough threshold corrected those
analytic failures. Moving the pitch frames beyond the attack transient and
using two-frame consensus improved the acoustic smoke results. These windows
were inspected during development; they are not unseen evaluation data.

## Reproduce headless export and public-reference evaluation

Only explicitly passed WAV/CAF files are opened; no file discovery, downloads,
GUI, audio playback or user library scan occurs. Mono files use their sole
channel; stereo files select L/R independently. Invalid inputs exit 2 without
writing a prediction file. Each case records the actual file SHA256, selected
channel, rate, original origin and timing. Engine metadata records actual DSP
and CLI source SHA256, settings, version, operating system and no weights.
The script compiles an optimized standalone CLI into a temporary directory and
removes it afterwards.

```sh
scripts/run-native-mono-evaluation.sh \
  --fixture guitarset-00_BN3-119-G_solo-clean_mono left 0 \
  /private/tmp/roughscore-issue10-guitarset-final/cases/guitarset-00_BN3-119-G_solo-clean_mono/input.wav \
  --fixture guitarset-00_BN1-129-Eb_comp-clean_chords left 0 \
  /private/tmp/roughscore-issue10-guitarset-final/cases/guitarset-00_BN1-129-Eb_comp-clean_chords/input.wav \
  --output /private/tmp/roughscore-native-mono-predictions.json
python3 scripts/evaluate-transcription.py \
  --manifest /private/tmp/roughscore-issue10-guitarset-final/evaluation-manifest.json \
  --predictions /private/tmp/roughscore-native-mono-predictions.json \
  --output /private/tmp/roughscore-native-mono-evaluation.json
```

Export uses PR25 schema version 1, rounding measured MIDI only for the evaluator's
integer-MIDI field; `measured_midi`, `frequency_hz` and cents preserve the physical
measurement. Unknown pitch exports JSON null and qualified false. Predictions
include every attack, even noise/unknown proposals, so precision does not hide
errors. The evaluator references are relative to the *derived WAV* (origin 0).
For original-recording proposals use `timeOrigin=16` for the solo window; do not
feed those shifted times to the local-reference evaluator. The acquired manifest
records `audio_origin_in_source_seconds=16` separately.

## Measured acoustic smoke results

GuitarSet 1.1.0, [official Zenodo record](https://zenodo.org/records/3371780),
CC-BY-4.0. Attribution: Qingyang Xi, Rachel M. Bittner, Johan Pauwels, Xuzhou Ye
and Juan P. Bello (2018), DOI 10.5281/zenodo.3371780. The acquisition receipt
and PR25 reference metadata retain original archive/member hashes and document
five-second cropping/MIDI rounding. References derive from published JAMS
note annotations, not independently verified hand labels.

| Acoustic performer-00 window | Clean solo | Clean chords (unsupported) |
| --- | ---: | ---: |
| Reference notes | 11 | 31 |
| All proposals (including unknown) | 14 | 19 |
| Exact-MIDI/lane matches within 50 ms | 6 | 0 |
| All-proposal precision | 42.86% | 0% |
| Recall | 54.55% | 0% |
| Qualified proposals / matches | 6 / 6 | 4 / 0 |
| Qualified precision | 100% | 0% |
| Qualified reference coverage | 54.55% | 0% |
| Onset-only recall | 90.91% | 45.16% |
| Matched onset mean / median / p95 absolute error | 18.61 / 17.44 / 24.34 ms | no pitch matches |
| Evaluator slice status | FAIL (coverage <75%) | FAIL |

These are two previously acquired acoustic smoke windows from one performer;
no representative/unseen real-guitar accuracy, electric/distortion, bends/slides,
dual-guitar or separation claims follow. Strong harmonics and clean periodicity
in chords can still yield qualified **wrong** pitches. No polyphonic or separation
feature should be enabled on the strength of this implementation. The clean-mono
release threshold remains qualified precision >=90% and reference coverage >=75%
on appropriate actual references; it is not lowered here.

## Validation and benchmark

The focused Swift suite contains nine tests with parameterized cases: analytic
harmonic plucks at MIDI 40/45/52/59/64/76/88 at 44.1/48 kHz (second harmonic
stronger than the fundamental), missing fundamentals at MIDI 40/57/76, phase
inversion, two reattacks, independent E2@1.0 s/A3@1.15 s channels cropped at0.8 s,
silence, empty/short regions, deterministic broadband noise, input failures,
monotonic progress and cancellation during preprocessing, onset scan and pitch
lags. All qualified isolated synthetic pitches are within one semitone and
attacks within 30 ms of analytic oscillator ground truth. This is synthetic
correctness evidence only.

To measure peak process memory separately from compilation:

```sh
xcrun swiftc -O -parse-as-library \
  Sources/RoughScoreCore/MonophonicTranscriber.swift \
  scripts/evaluate-native-mono.swift -o /private/tmp/roughscore-evaluate-native-mono
/usr/bin/time -l /private/tmp/roughscore-evaluate-native-mono \
  --benchmark --output /private/tmp/roughscore-native-mono-benchmark.json
swift test
swift build -c release
python3 -m unittest discover -s Tests/Evaluation
```

The benchmark explicitly generates 30 seconds of 48 kHz analytic harmonic plucks
(60 notes, MIDI40...88; 5,760,000 bytes of Float input). Record elapsed analysis
time and `/usr/bin/time -l` peak process RSS for the actual supported host; the
latter includes runtime, generation and input buffer, not DSP-only memory.

Measured on this worker's arm64 macOS27.0.1 (26A434), Swift6.4, 10 logical
CPUs, optimized standalone build: 19.65 ms analysis, 0.35 s total process wall
time including signal generation/runtime startup, peak RSS19,988,480 bytes
(19.06 MiB), peak process memory footprint12,780,072 bytes. All60 generated
notes qualified and met30 ms/one-semitone bounds. This is one host/run, not a
latency guarantee; cancellation timing is also emitted by the benchmark.
