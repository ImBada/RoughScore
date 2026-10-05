# Sparse export core prerequisite (Related #15)

This core produces actual six-string sparse TAB, a lossless versioned event table,
and static paginated A4/Letter PDF documents. It reads model values only: no audio,
user library, window/view snapshot, transport controls or editor state participates.
The app integration now presents independent range/lane/format/paper options,
native PDFKit preview/printing, and optional prepared L/R waveform overviews.
No rests, missing notes, lengths, pitches, meter or tuning octaves are invented.

`SparseTabExporter.AnalysisContext` explicitly selects the original or imported
Stem's stored bar keys. `ScoreRenderPlan.WaveformInput` copies already prepared,
original-time-aligned envelopes; waveform elements use their own time axis rather
than the score's ordinal annotation columns. Offline exports omit waveforms.
Print settings are copied from NSPrintInfo; project/session/editor state remains
independent. The historical prerequisite evidence below is not approval of this
new integration. GitHub CI remains disabled by the user's current instruction.

## Interface

```swift
let selection = SparseTabExporter.Selection(
    range: TimeSpan(start: 2, end: 12), lanes: [.left, .right]
)
let tab = try SparseTabExporter.tab(project, selection: selection, columnsPerSystem: 6)
let table = try SparseTabExporter.eventTable(project, selection: selection)
let decoded = try SparseTabExporter.parseEventTable(Data(table.utf8))
let plan = try ScoreRenderPlan(project: project, selection: selection,
    settings: .init(paper: .a4, margin: 40, minimumColumnWidth: 64,
                    fontSize: 9, showRhythm: true))
let pdf = try ScorePDFExporter.data(for: plan)
try ScorePDFExporter.write(plan, to: destinationPDFURL)
```

The exporter validates `ScoreProject.validated()` and copies exact event values.
Selection uses original-song seconds `[start,end)` and explicitly chosen lanes;
full/both is the default. Empty valid selections produce an explicitly untranscribed
page, not a rest. Ties preserve source storage order; chronological presentation
never changes times, UUIDs, L/R, string, known/unknown fret, optional rhythm,
tentative flag or memo. No API changes the source or Workspace/history state.

`ScoreRenderPlan.events` contains each selected event once. `placedEventIndices`
partitions that snapshot into exactly one six-string system per event. Pages contain
reusable system/text elements, geometry and exact source events; the native renderer
contains no SwiftUI/AppKit view or print-dialog dependency. Every note receives an
independent column, including simultaneous and same-string notes. Numbered columns
connect to complete event details, where full UUIDs appear once. Width, density,
page size, margins and rhythm visibility affect presentation only.

The score's compact column time labels use three decimals for readability; each
event detail and the table also print exact round-trippable original seconds.
An event just before10s remains just before10s; a compact10.000 label never changes
its model time or clipping-boundary selection. Rows use ordinal spacing to keep
all dense notes visible, rather than pretending uniform columns are a rhythmic
grid or proportionally timed waveform. Dashes/blank strings mean untranscribed
space; `?` is an unknown fret, and `~` identifies tentative annotations. Optional
rhythm labels appear only when requested; nil remains unspecified.

## Tuning, bars and metadata

An explicit numeric `TuningDefinition` takes precedence over legacy labels. Headers
show standard/custom open MIDI pitches and octave names in string1...6 order,
actual capo and sounding open pitches; frets stay capo-relative. Without a numeric
definition, the exact legacy standard labels use the existing project's standard/
capo0 resolver. Other label-only tunings are explicitly unresolved: their labels
are retained, and numeric pitches/octaves/capo remain unknown.

Actual per-lane analysis bar starts (or Stereo fallback) are printed in event
anchors as `analysis-bar=N@seconds`. Bars are not synthesized when analysis is
absent; original seconds remain the anchor. This labels stored analysis as analysis,
not ground truth. Export neither activates audio nor recalculates/invalidate caches.
The table records title, original duration, chosen range/lanes, actual tuning labels
and optional numeric definition; it is an event interchange, not a full project
file or an audio/source-asset container.

## Event table version1

UTF-8 line format:

```text
#roughscore-event-table<TAB>1
#meta<TAB>{JSON metadata, events:[]}
id<TAB>time<TAB>lane<TAB>string<TAB>fret<TAB>length<TAB>tentative<TAB>memo
{JSON UUID}<TAB>{Double}<TAB>{JSON lane}<TAB>{Int}<TAB>{Int|null}<TAB>{JSON length|null}<TAB>{Bool}<TAB>{JSON String}
```

Every data cell is a JSON scalar, separated by literal tabs. Memo/title/tuning
Unicode is retained; literal newline, tab, carriage return, quotes and backslashes
are escaped by JSON, so a memo occupies one physical table row and round-trips
without flattened lines or ambiguous literal `\\n`. Fret/rhythm null preserve
unknown/unspecified values. Numeric Double text round-trips original values,
including negative-zero bits. Headers/schema, field counts, source note constraints,
UUID uniqueness, tuning, finite bounds and range/lane membership are validated
on parsing; future versions and malformed cells throw, never silently drop notes.
The source event table always carries optional rhythm even when the score/PDF
presentation hides rhythm. No UUID regeneration or cross-lane remapping occurs.

## Native PDF rendering and safety limits

CoreText measures wrapping and renders system fonts with native font substitution;
CoreGraphics produces actual PDF bytes with embedded font subsets. Korean text,
Unicode memos and long paragraphs are wrapped rather than truncated. Tabs/control
bytes in PDF memos are made visibly escaped; newline creates a real paragraph
break. Exact memo bytes remain in the event table and plan snapshot. Each text draw
saves/restores graphics state; the raster regression covers independently rendered
first/last page title glyphs, since text extraction alone could miss a font-state
rendering defect. A native PDFKit/CoreGraphics renderer and independent bundled
Poppler renderer were used for page-image QA.

Limits:10000 selected events,32KiB UTF-8 per memo/title,1024bytes per legacy tuning
label,8MiB aggregate memo/text table budget,512 planned pages and64MiB rendered PDF.
Settings must be finite: margins24...90pt, minimum column width48...160pt,
font size7...14pt, text-TAB columns1...16, with enough remaining page content area.
An overly tall title/tuning header rejects rather than clipping or hiding metadata.
The plan rejects invalid ranges/empty lane sets and unsafe settings; project errors
remain errors. PDF is rendered completely before an atomic destination write;
only file URLs with `.pdf` extension are accepted. The caller owns destination
selection and overwrite policy. No global font installation or setting changes
are required; no licensed/trained model or weights are used.

## Reproduction and actual visual evidence

Tests use authored model values only, including a mixed both-lane sparse phrase,
known/unknown fret, nil/explicit length, tentative notes, multiline/tab/quote/
backslash/Korean/decomposed-Unicode memo, actual custom DropD/capo definition,
unresolved legacy labels, same-string coincidence, tiny positive durations,
malformed tables and a generated720-event three-minute dense score. A4/Letter
page partitions retain every note once and all element bounds are checked.
Actual PDF text verification finds every UUID once and Korean memo/title text,
while raster verification checks real header glyph pixels on independent pages.

```sh
swift test --filter ExportCoreTests
swift test
swift build -c release
python3 -m unittest discover -s Tests/Evaluation
python3 -m unittest discover -s scripts/ci -p 'test_*.py'
```

Generated task-owned examples and builders are under
`/private/tmp/roughscore-export-core-artifacts` (no user content):

- `output/pdf/representative-a4.pdf`:5 mixed sparse notes,1 A4 page.
- `output/pdf/dense-letter.pdf`:720 dense notes over180s,62 Letter pages,
  custom DropD/capo2, rhythm display off; table still preserves original rhythm.
- `output/pdf/unresolved-selected-a4.pdf`:2 right-lane notes in a selected range,
  unresolved legacy tuning,1 A4 page.
- Matching `.tab.txt` and `.events.tsv` outputs, `artifact-receipt.json`, and
  `tmp/pdfs` representative/first/middle/last native and Poppler PNGs.

The bundled `pdftoppm` executable has a build-time CMap path from its build host;
its initial output omitted Korean-font glyphs. A small task-local C++ adapter uses
that same bundled Poppler library with `GlobalParamsIniter::setCustomDataDir` pointed
at its existing bundled `share/poppler`, yielding fully readable embedded-font
page images without installation, global config edits or product runtime changes.
The temporary adapter is QA tooling, not a shipped dependency; the actual exporter
is native CoreGraphics/CoreText only. Native PDFKit rendering also verifies the
same pages. The inspected latest pages contain no hidden collisions, glyph boxes,
string/fret clipping, transport chrome or header/footer overlap.

Both actual SDK CI jobs and independent exact-head/base approval are required
before the authorized source integration owner or root merges. Menu/system
clipboard/print integration, selection gestures, live waveform rendering and full
#15 UI acceptance remain open and are not claimed by this prerequisite.

Final local verification on accepted main280592964ae21c970c199b1e934f28c3e63ea22f:
159 Swift tests in20 suites passed, including11 focused ExportCoreTests; release
build passed;33 evaluator and7 CI-helper Python tests passed. Only the five new
reserved core/test/doc files changed. The three final generated PDFs and latest
page-image QA are recorded in the task report with hashes; they are examples,
not a shipped fixture or new product/media library.


## App integration validation (issue15)

The File menu and toolbar now share sparse TAB, escaped event table and native
PDF export settings. Command-P routes the same immutable document snapshot to
PDFKit's native print panel. Full/selected/custom original-second ranges, L/R,
A4/Letter, margin, recorded rhythm and optional prepared waveform overview are
sheet-local values. Rendering runs off the main actor; cancelled or stale requests
cannot publish after generation or a destination modal. Export does not initiate
analysis/audio preparation or modify project/session/history values.

New regressions exercise all request formats, exact boundary selection and memo
round-trip, document bytes and session/write counters, cancelled destinations,
failed output writes, native menu dispatch, copied print settings, active Stem
analysis and aligned waveform ranges. Three-minute 720-note full/selected PDFs
on both paper sizes retain every selected UUID once. Their first/middle/last
pages were rendered with official Poppler and all twelve samples visually checked
for Korean text, fret/string/details and header/footer clipping. The native app
was separately checked with generated task-owned audio/project data for PDF
preview/save, TSV save and native print cancellation; no physical print job ran.
Interactive edits during that GUI check are recorded separately, so that run is
not evidence of unchanged project/session state. The modal cancellation guard
added afterward is covered by an explicit regression and the final local CI.

Independent R1 additionally reproduced stale protection after reentrant Save As
and Task cancellation during destination selection. Successful Save As now
invalidates the export snapshot; ordinary active save and Save Copy retain it.
The final write checks current as well as captured protected paths/package roots
and checks Task cancellation after the modal. The original independent probes
are preserved unchanged under `Tests/ReviewProbes` and pass after these fixes;
the normal suite covers package readability, collected-media bytes and silent
Task cancellation too. These parent results do not substitute for a new review.

Exact-commit independent review and inherited PR40 approval remain separate gates.
GitHub workflows stay disabled as instructed. Local current-SDK success is not
macOS15 runtime validation, signing/notarization or model/audio quality approval.
