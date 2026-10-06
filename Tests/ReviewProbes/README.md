# Saved independent issue15 R1 probes

`IndependentIssue15R1Probes.swift` is preserved byte-for-byte from independent
review of `25a66b67896aac45509c40923c5b5661c2bcb56f`.
SHA-256: `aafc9107a6bd0f8618a139b441c4cd85caaa9be96465d9f7843fd82a246e5f97`.

It originally reproduced stale active-package protection after reentrant Save As
and task cancellation during the export destination callback. Its range/lane and
control-byte test passed. Normal `NativeExportWorkflowTests` also cover these
boundaries without requiring the independent runner's evidence environment.

To replay unchanged probes, copy this file into `Tests/RoughScoreTests` of a
disposable exact-commit `git archive`, create a task-owned evidence directory and
run `swift test --filter IndependentIssue15R1Probes` with
`ROUGH_SCORE_INDEPENDENT_PROBE_ROOT` set to that directory. Use isolated build/cache
paths. The probes generate their own audio; no human audio or print jobs are used.
This file stays outside the normal SwiftPM test target because its original
runner deliberately requires an explicit evidence path. Do not weaken assertions
or modify the preserved probe to accommodate a source fix.
