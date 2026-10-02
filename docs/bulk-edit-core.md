# Pure bulk-edit core prerequisite (Related #8)

This prerequisite implements UUID selection, clipboard serialization and atomic
project-value edits. It does not implement UI selection gestures, the system
pasteboard, cursor commands, Workspace persistence or undo history. Full #8
remains open: its source owner must apply one returned changed project in exactly
one history transaction and provide the UI workflow. Existing sparse TAB entry
stays usable without this feature; no rests, required rhythm or quantization are
introduced.

## Interface

```swift
let selection = try TabSelection(ids: [firstID, secondID], primaryID: firstID)
let leftRange = try TabSelection.range(in: project, lane: .left, from: 2, to: 4)
let fragment = try TabFragment.copy(from: project, selection: selection)
let data = try fragment.encoded()
let decoded = try TabFragment.decode(data)
let result = try TabEditCommand.paste(fragment: decoded, at: cursor).apply(to: project)
// Owner applies result.project once only if result.changed.
// result.pastedSelection contains fresh UUIDs and the mapped primary note.
```

Other commands are `.move(selection:timeDelta:stringDelta:targetLane:)`,
`.delete(selection:)`, `.setLength(selection:length:)` (nil clears rhythm), and
`.setTentative(selection:value:)`. Zero offsets, empty selection/fragment and
already-equal length/tentative values report `changed=false`, empty `affectedIDs`,
and return the original project. Inputs and stale IDs are still validated for
no-op commands; a stale zero-delta move fails rather than hiding a deleted note.
The command has no mutable global state and neither reads nor writes files.

`ScoreProject` and events are value types. Each command validates the source,
prepares a separate candidate and validates that candidate before returning it.
Failures throw and cannot mutate the source. The Workspace owner supplies the
history snapshot, document dirtiness and selection updates; this core has no
undo stack or UI actor ownership. The result exposes only the changed project,
actual `affectedIDs`, and an optional new paste selection.

## Selection and clipboard semantics

- `TabSelection` is an immutable set of exact UUIDs with a primary UUID. An
  explicit primary must be selected; omitted primary chooses the least UUID
  string deterministically; empty selection has no primary. Coincident notes
  remain distinct, and resolution preserves project storage order.
- A lane range uses original seconds `[start,end)`. Start is inclusive, end is
  exclusive; end may equal project duration, and an empty range is valid. A range
  snapshots IDs: later inserted notes are not implicitly included. Missing IDs
  reject the whole operation with `staleSelection`, never silently drop them.
- Multi-copy anchors at the earliest current selected note. Range-copy anchors
  at the original range start, preserving leading silence before its first note.
  If selected notes move before that retained range origin, copying rejects with
  `invalidCopyOrigin`; reconstruct/reselect explicitly to choose a new anchor.
  Range boundaries do not quantize event times or manufacture silence/rest notes.
- Clipboard entries preserve relative original-seconds offsets, L/R, string,
  known or unknown fret, optional NoteLength, tentative flag and the exact memo.
  `primaryIndex` retains the primary note without retaining source UUIDs. Entry
  order is original project storage order, not a synthesized score ordering.
- Paste creates new UUIDs and appends entries, leaving every existing event and
  its order untouched. Existing overlaps/coincidences are valid. Default paste
  and move preserve each note's lane, including cross-lane multi-selections;
  mapping every selected/copied note to a chosen lane requires `targetLane`.
- A move uses the same finite time delta and integer string delta for every
  selected event and retains all UUIDs and nonedited annotations. Any invalid
  time/string rejects the whole group, with no per-note or group clamping.
- Time bounds use exactly `0 <= time < duration`, including positive durations
  smaller than common UI epsilons. No `duration - 0.001` or other margin is used.
  Offsets use ordinary IEEE Double addition/subtraction, without rounding or a
  musical grid. If precision loss would collapse two distinct instants into a
  new coincidence, the whole operation rejects with `unrepresentableTiming`.
  Existing coincident notes remain valid and separately identified.
- Delete removes only selected UUIDs. Length and tentative commands alter only
  the requested field on those UUIDs. Title, project version, source metadata,
  duration, tuning, analyses and all other project fields are copied unchanged.

A pasted fragment contains annotations, not an audio clip, inferred rests or an
invented phrase duration. Empty copy/paste does not create an event. Trailing
range silence is not represented as a synthetic rest or note length.

## Validation and format limits

The pasteboard type is `app.roughscore.tab-fragment+json`; the clipboard format's
`schemaVersion=1` is independent of project file versions. Its JSON has `events`
and `primaryIndex` (required/non-null for nonempty fragments, optional/null for
empty ones). Each event has `relativeTime`, `lane`, `string`, optional `fret` and
`length`, required Boolean `tentative`, and required String `memo`. Unknown JSON
keys follow standard Codable behavior and are ignored within this version;
known fields with the wrong type/value and unsupported enum strings fail.
Future/unsupported clipboard versions fail before entry decoding.

Limits are 4096 entries, 1 MiB encoded clipboard data and 16 KiB UTF-8 per memo.
The preferred untrusted entry point `TabFragment.decode(Data)` checks the byte
limit *before* parsing. Codable construction also bounds the array incrementally
and validates count, primary index, metadata and full canonical encoded size.
Typed construction/paste enforce the same limits, including JSON escaping and
aggregate size, rather than allowing a large typed payload to bypass decoding.
Finite nonnegative offsets are strictly less than86400 seconds; strings1...6 and frets0...24
follow the existing core contract. Unknown fret and unknown rhythm remain nil.
A malformed fragment cannot be constructed through the public initializer or
Codable initializer. Decoder errors and `TabEditError` cases are thrown; invalid
input is never substituted with an empty fragment or partially applied project.

All project-schema validation delegates to `ScoreProject.validated()`. Commands
neither hard-code a new document version nor migrate it; v1 legacy documents and
current-version documents use the existing decoder/validator's compatibility
rules. Tests cover an independently authored v1 JSON record and a current-schema
round trip. Unrecognized project versions and duplicate UUIDs fail the existing
validator before any edit. The accepted baseline is project schema v1 with optional asset, tuningDefinition
and analysis-provenance extensions from PR27. Tests use nondefault authored values
for these fields as well as a legacy v1 record without them; this prerequisite
does not modify Project.swift or introduce a file schema.

Paste validates every target time before generating IDs. The injectable UUID
factory defaults to `UUID()`; any collision with an existing ID or another new ID
rejects the entire paste with `generatedIDCollision`. Factory side effects are
caller-owned; only project mutation is transactional. UUID collisions cannot
replace an existing note, and coincident times do not imply identical IDs.

## Verification and remaining integration

`swift test --filter BulkEditTests` covers mixed sparse riff/chord copy/encode/
decode/paste round trips, exact dyadic original-second offsets and annotation
attributes, fresh UUIDs/primary mapping, default cross-lane preservation and
explicit lane transfer, half-open range boundaries/leading silence, distinct
coincident IDs, snapshot/stale-ID policy, atomic move/delete/length/tentative edits,
unrelated event/full document metadata preservation, time/string/overflow and
UUID collision failures, malformed clipboard versions/types/numbers/metadata,
byte/event/memo/escaped aggregate size limits, tiny positive durations, floating
point collapse rejection, zero/same-value no-ops, and v1/current schema handling.
Fixtures are authored data values only; no user audio, GUI or real library is used.

Run `swift test` and `swift build -c release` for regression/build validation.
Both actual SDK CI jobs and a different reviewer's approval of the exact head
are required before root merges. Later UI/history acceptance remains with #8,
including one-undo application, collision display/gesture integration, cursor
paste/duplicate commands and system pasteboard ownership.

Local validation on accepted maind6775e6cf4920a54dd23d91c0436e0bdcfaeb4b6:
136 Swift tests in15 suites, including16 BulkEditTests, passed; release build
passed;33 evaluator and7 CI-helper Python tests passed. Exact memo UTF-8 bytes
(including decomposed Unicode) and no-op negative-zero timestamp bits are checked.
This is core/schema verification only; GUI and actual one-undo behavior remain
for the #8 integration owner.
