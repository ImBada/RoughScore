# Pure reverse fingering core (related to issue #9)

`FingeringResolver.resolve(midi:project:preferredFret:context:)` enumerates and
ranks positions with advisory costs without changing the project. Only `midi` and
`project` are required. This core is a prerequisite checkpoint; issue #9 stays
open until the app integrates tuning editing, manual/detected pitch alternatives,
selection and undo, and the other issue acceptance requirements.

```swift
let result = FingeringResolver.resolve(midi: 64, project: project)
// Optional editing advice; no event construction, workflow, or mutation required:
let ranked = FingeringResolver.resolve(
    midi: 64, project: project, preferredFret: 9,
    context: FingeringContext(lane: event.lane, time: event.time,
                              excludingEventID: event.id))
```

## Numerical contract

String numbers are the **ordered indices 1...6** in `openMIDIPitches`, without
sorting or assuming a particular pitch order. Frets are **capo-relative 0...24**.
Fret zero means the open string at the capo, even with a nonzero capo. Sounding
MIDI is `openMIDIPitches[string - 1] + capo + fret`, limited to MIDI 0...127.
Capo 24 still allows relative frets through 24; there is no extra absolute-neck
limit beyond the existing project semantics and MIDI ceiling.

An explicit `TuningDefinition` must pass its existing `validated()` method:
version 1, exactly six MIDI values in 0...127, capo 0...24, and every open value
plus capo at most 127. Invalid numeric data never falls back to labels. Without
a numeric definition, only the exact legacy label array
`["E", "B", "G", "D", "A", "E"]` resolves to `[64, 59, 55, 50, 45, 40]`
with capo zero. Other labels, including octave labels or differing case/spacing,
return `unresolvedTuning`; they never imply an octave. With numeric tuning,
legacy display labels have no effect.

For each string, the resolver computes the one possible relative fret, rejects
values outside 0...24, and **inverse-checks every offered candidate through
`project.soundingMIDI(string:fret:)`**. Standard MIDI 64 therefore offers exactly
1/0, 2/5, 3/9, 4/14, 5/19, 6/24. Drop D low open MIDI 38 with capo 2 offers
MIDI 40 at 6/0. An empty `.resolved([])` means a valid resolved tuning but no
playable position; it differs from an unresolved or invalid input.

## Advisory ranking policy

`preferredFret`, when present, is an integer capo-relative hand-position hint in
0...24. Its cost is absolute fret distance, including **fret zero as zero**.
Open strings receive no special exemption from that hint. The hint takes priority
over movement; it is advice, never proof of playability of a phrase or chord.

`FingeringContext` supplies a lane, exact seconds, and optionally the edited
event's UUID. The resolver reads `project.events` and removes opposite-lane
events and all events with the excluded UUID before context validation. No
excluded or opposite-lane field can affect ranking, even malformed fields.
This API validates only the numerical tuning and requested ranking inputs;
project loading/saving must retain its separate whole-project validation.

Context requires finite project duration in (0, 86400], finite time in
[0, duration), unique relevant same-lane UUIDs, and relevant event times in that
interval, strings 1...6, and nil or 0...24 frets. Invalid relevant context returns
`invalidContext`, rather than silently producing a partial ranking. Nil frets
are valid but contribute no movement. Length, memo, tentative flag, analyses,
audio, and other project metadata never influence advice. Without context,
event and duration fields are not consumed or validated.

For known same-lane frets, choose the closest timestamp **strictly before** and
the closest timestamp **strictly after** the editing time. Include **all known
notes at each chosen timestamp**; multiple notes there each contribute equally.
Unknown frets cannot hide a more distant known neighbor. Exact coincident notes
at the editing time contribute nothing; comparison uses exact stored seconds,
without tolerance, quantization, or time snapping. If only one side exists, use
it; if neither exists, both movement costs are zero. This avoids making an
arbitrary single-note selection at a tied timestamp and does not claim that
simultaneous notes form a solvable chord.

Candidates sort ascending by this precise lexicographic tuple:

1. Absolute distance to `preferredFret`, or zero if the preference is absent.
2. Sum of absolute fret distance to every chosen neighbor.
3. Sum of absolute string-number distance to every chosen neighbor.
4. Relative fret.
5. String number.

No weights, time-gap penalties, UUID ordering, or input-array ordering enter the
tuple. Costs are exposed as `preferredFretDistance` (nil when absent),
`neighborFretDistance`, and `neighborStringDistance` on immutable candidates.
The two nonnegative movement sums saturate at `Int.max` on overflow; integer
saturation is independent of input permutation. Bounds are checked before
arithmetic, indexing, or absolute differences, including extreme hostile `Int`
inputs. The result exposes immutable ordered `candidates`; error cases expose
an empty array but retain their distinct enum case.

## Failures and preservation

Validation order is pitch, tuning, preference, then context. Cases are
`invalidPitch`, `invalidTuning`, `unresolvedTuning`, `invalidPreference`, and
`invalidContext`; the successful case is `resolved([FingeringCandidate])`.
The resolver does not throw, infer a candidate selection, create events, remap
TAB, rewrite rhythm or times, change UUIDs or L/R lanes, or modify tuning.
Sparse unknown notes, nil rhythm, exact manual seconds and memos remain intact.
UI/undo/engine integration, alternate per-lane tuning, automatic transcription
accuracy, chord solvability, physical fingering technique, and real-guitar
quality evaluation are outside this core.

## Verification scope

Tests independently enumerate all 150 string/fret pairs for MIDI 0...127 over
327 numerical definitions: standard, Drop D/capo 2, twelve deterministic custom
ordered tunings and an extreme-boundary tuning for each capo 0...24. This checks
41,856 pitch/tuning combinations against a forward equation using `Int64`,
including completeness, uniqueness, and the project inverse check. Focused
tests cover exact standard and Drop D results, custom order, MIDI/capo extremes,
hostile integers/invalid versions, unresolved labels, preference, previous/next
neighbors, timestamp groups, exclusion, coincident and unknown notes, all 24
permutations of a context array, opposite-lane changes, tie-breaks, invalid
context, and unchanged sorted JSON bytes and project fields.

Generated audio/AAC integration and release builds exercise existing local app
regressions, not automatic-transcription quality. Hosted checks on both SDKs,
independent exact-head review, integrated issue #9 UI, and guarded merge belong
to the later whole-issue PR; this local checkpoint makes no release claim.
