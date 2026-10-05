# CI foundation

`bash scripts/ci/run.sh /private/tmp/roughscore-ci-unique enabled` runs the same
headless checks as GitHub Actions with the currently selected Xcode. Use a new,
nonexistent output directory; `disabled` selects the older-SDK expectation.
`DEVELOPER_DIR` selects a toolchain per command without changing global Xcode
settings. Logs, caches, fixtures and build products stay under that output root.
No app GUI or audio playback is launched.

The workflow uses `macos-15` / Xcode 16.4 for the analysis fallback and the official
`xcode-27` public-preview runner / Xcode 27 for analysis-enabled compilation. The
SDK probe fails if the installed capability differs from the selected lane.
Image availability is recorded, not inferred as passing coverage; preview runner
outages require a real replacement verification, not a skipped success.

Sources checked when selecting these lanes:

- [GitHub runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [macOS 15 image software](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)
- [Xcode 27 image software](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)

The original fixture is two seconds of deterministic mathematical tones. Its
generated data is CC0-1.0; no song, recording, user audio or downloaded sample is
included. Native `afconvert` encodes stereo AAC/M4A. A headless AVFoundation check
verifies duration, sample rate and distinct left/right activity, then the entire
Swift test suite uses that M4A as its integration fixture. No fixture environment
variable from the caller is trusted. Compressed bytes may differ across Apple
encoder versions; the PCM source hash and encoding settings are recorded.

Coverage verification rejects zero/missing Swift Testing cases, incomplete
baseline coverage, the optional audio test's silent early return, and absent
external-intake suite/case pass markers. The existing
test calls its message `Real audio`; in this job that means **generated compressed
codec input**, not a real guitar quality measurement. Licensed/labeled real guitar
evaluation is explicitly **SKIPPED** in the summary. This subset does not edit the
existing optional test or implement the quality gates in #10.

`python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v` checks these reporting
contracts and fixture reproducibility. The workflow installs no app dependencies,
uses read-only PR permissions and pinned official actions, and has no release,
signing secret or `pull_request_target` path. It uploads only logs, reports and the
fixture manifest, not build products or recordings.

Validate workflow expressions with
`actionlint -config-file scripts/ci/actionlint.yaml .github/workflows/ci.yml`.
The explicit label configuration permits the documented `xcode-27` hosted
preview because actionlint 1.7.12's built-in runner list predates that label.
No other unknown labels or expression errors are suppressed.

For #18, `scripts/build-app.sh NEW_OUTPUT_DIRECTORY --version 0.1.0 --build 1`
separately builds and verifies a fresh native app, document metadata, ad-hoc seal,
versioned ZIP, checksum and source/toolchain manifest. See
[`docs/DEVELOPER-INSTALL.md`](../../docs/DEVELOPER-INSTALL.md). Unit/hosted tests
exercise the actual URL callback and transaction lifecycle; actual Finder cold/warm
and dirty-dialog delivery still need native QA. A release executable or ad-hoc
bundle is not a notarized distribution. GitHub CI remains disabled by user choice;
do not enable/dispatch it or add publishing workflows to run these local checks.
