# Tuning, capo and optional fingering choices

The title area opens the tuning editor. Standard and Drop D presets fill the six
open-string MIDI values, in string order 1 through 6. Custom values may be entered
individually. Apply validates all six MIDI integers (0–127), capo (0–24), and each
open MIDI + capo (at most 127) together. Invalid drafts never change the project,
its dirty state, or its undo/redo history. Settings are shared by Guitar L and R;
there are no per-lane overrides in this MVP. Frets are relative to the capo.

Applying tuning changes the sounding pitch interpretation only. It never remaps
existing string, fret, time, UUID, lane, tentative flag, nil rhythm, or memo. The
setting change is one project undo transaction and retains bulk selection/cursor
state. Numeric settings save and reopen in the accepted optional v1 schema.
Legacy exact E/B/G/D/A/E labels retain the existing standard resolver. Other
legacy labels remain unresolved until the user explicitly chooses a preset or
enters all six MIDI values; opening a document never invents octaves.

The note inspector has a collapsed optional “음고 / 다른 운지” control. MIDI input
and an optional preferred relative fret show ranked candidate buttons. The pure
resolver inverse-checks each offered position against `ScoreProject.soundingMIDI`.
Ranking uses only the strict nearest previous/next known timestamps in the edited
lane, excludes the edited UUID and coincident notes, and is deterministic under
permutation. It advises position, fret movement, then string movement; it does
not solve chords or prove physical technique. Invalid/unresolved inputs and
playable-but-empty results are explained separately. Choosing a button changes
only that note's string/fret and can be undone in one step; stale selection or
now-invalid tuning cannot apply an old candidate.

An optional selected-position button estimates clean monophonic pitch from a
bounded 350 ms crop of the selected lane's already prepared PCM. It uses the
existing experimental monophonic DSP and never mixes L/R, creates TAB, assigns
rhythm, or accepts a fingering. A separate “MIDI … 후보 보기” click uses the nearest
semitone of a finite qualified estimate. Polyphonic, unstable, silent, and short
regions may have no estimate. Selection, edit, tuning, load, or shutdown changes
invalidate late results. This is generated-signal regression coverage, not a
claim about real guitar transcription accuracy.

Headers, open-string labels, inspector pitches, demo synthesis, and text/PDF
export all derive sounding pitches from the numeric project resolver. Export
also lists the original open MIDI values and capo and identifies unresolved
legacy settings. The existing click + digit workflow, 0.9 s two-digit entry,
unknown notes, optional rhythm, free position editing, and Shift-only 10-point
magnet remain available without using the pitch controls.

`FingeringResolverTests` retain the independent 41,856-combination numeric oracle.
`TuningIntegrationTests` exercise the actual Workspace and disposable hidden
SwiftUI/AppKit hosts: atomic tuning rejection/application, save/reopen, legacy
resolution, candidate selection/undo, native text composition/history, real
preset/apply/candidate button actions, bulk cursor/history coexistence, late
asynchronous rejection, and generated Drop D/capo audio estimation. These are
hidden native control probes; visible GUI routing and real-guitar quality are
not claimed. The full generated AAC/release/Python CI contract runs on the final
source and the manual-only hosted matrix must pass both SDK lanes before Root's
independent review and guarded merge.
