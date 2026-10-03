# Portable project package v1

This is the reusable collect-audio IO prerequisite for [#14](https://github.com/ImBada/RoughScore/issues/14), not Save As/Save Copy or playback integration. The package is a directory with extension `.roughscorepkg`. `project.json` is UTF-8 JSON with this envelope:

```json
{"format":"org.roughscore.portable-project","version":1,"project":{"version":1,"title":"…","duration":2,"tuning":["E","B","G","D","A","E"],"events":[],"analyses":{}}}
```

The embedded project uses the existing v1 ScoreProject/AudioAsset/AudioReference schema; package, project, and nested schema versions are independently validated. `Media/<asset UUID>.<extension>` contains verbatim collected encoded audio. Original and imported guitar stem assets retain independent UUIDs, roles, identities and original-time offsets (`original seconds = asset seconds + offset`; 250ms padding uses -0.25). Duplicate source filenames cannot collide. No external `audioPath` remains in the package. Readers require contained references to direct files in `Media/`, with identity on every asset, and reject undeclared entries. A notes-only package has neither assets nor `Media/`.

## Source integration API

```swift
let collected = try PortableProjectPackage.collect(project, to: newPackageURL,
    sourceRoot: existingPackageRoot, cancellation: { try Task.checkCancellation() })
let reopened = try PortableProjectPackage.read(at: relocatedPackageURL)
let originalURL = try reopened.resolve(assetID: reopened.project.originalAsset!.id)
```

`sourceRoot` defaults to nil and is required only for contained input references. The explicit root is never inferred from a former source path or process working directory. External references must be absolute paths. Collection is synchronous and can run on Source's cancellable background worker; Task cancellation and the caller's throwing cancellation closure are checked between bounded IO/decode operations and immediately before commit. A successful commit returns its snapshot without a later cancellation/error-producing step.

`Snapshot` exposes immutable `root` and value-type `project`; `resolve(assetID:cancellation:)` revalidates the requested asset's entire content identity before returning its contained URL. A snapshot never mutates the caller's project or activates an editor/autosave destination. Read/resolve reject missing, corrupt or changed bytes rather than returning a playable/offline placeholder. URL validation describes the instant of resolution: Source must still verify current content after player initialization, as its existing preparation logic does, because a filesystem URL cannot lock future playback opens against another process. There is no waveform, listening selection, stem mixing, Finder routing, or editor state transition in this API.

Manual UUIDs, seconds, L/R lanes, strings/frets, nil rhythm, tentative flags, multiline Korean memos, duration, tuning labels, numeric tuning and capo are preserved exactly. Legacy v1 `audioPath` is converted to a newly allocated original asset UUID and an identity proved from the copied bytes; no historical identity or numeric tuning is invented. Label-only nonstandard tuning remains unresolved. Legacy summaries without provenance are discarded. Proven summaries survive only when the full independent asset UUID/content identity matches; a replaced original does not invalidate an unchanged independently imported stem. Contradicted identities are replaced with verified current-byte identities and their summaries are removed. The input value is unchanged on success and on every error.

## IO and atomicity limits

Collection copies every declared source, never moves/deletes/writes it. Missing/unreadable/corrupt declared media fails the whole collection. A project with no declared media can be collected explicitly as notes-only; an offline linked project cannot silently become notes-only. Source may later provide a separate user-visible notes-only action.

The writer creates an exclusive UUID-named sibling staging directory on the destination volume, streams encoded bytes in chunks of at most 1 MiB, hashes SHA-256, decodes in 16,384-frame mono/stereo chunks, checks file metadata and rehashes source/staged bytes, writes bounded project JSON (maximum 16 MiB), then reads and validates the entire staged package. JSON and resources are flushed before commit. Darwin `renameatx_np(..., RENAME_EXCL)` commits a complete package with atomic visibility. An existing destination file/directory/symlink, including a destination created during collection, is rejected without touching it. **There is no replacement API.** Source must choose a new destination; it must not remove an existing package to emulate safe replacement. Atomic visibility is not a claim of transaction durability across power loss.

Traversal, absolute contained paths, empty/dot/parent components, backslashes and NUL are rejected. Directory roots/ancestors are checked by path components after symlink resolution, not string prefix. All contained components are opened with `openat`/`O_NOFOLLOW`; regular files are required, excluding directories, FIFOs, devices and symlinks. AudioToolbox reads the pinned descriptor through positional-read callbacks, never a package pathname. Readers reject even unused symlinks/foreign resources and recheck file/root identity before returning. A sibling named `package.roughscorepkg-sibling` is never considered contained.

On error/cancellation the writer removes only its own staging directory, checking its device/inode before cleanup; it does not scan or remove other staging directories. Cleanup is best effort if external filesystem permissions or directory ownership change during an operation. Existing destinations and sources are preserved; no partial package is committed. There is no archive library, external converter, model, or command-line tool dependency in the package implementation.

## Verification scope

`PortableProjectPackageTests` use real generated stereo/mono CAF/WAV originals and a padded stem, move the entire package to a different parent, delete only generated source fixtures, and reopen/resolve hashes, frames, channel counts, independent offsets, notes, tuning and provenance. They cover legacy conversion, explicit no-media/offline behavior, duplicate filenames, source replacement, malformed JSON/schema/resource content, missing resources, malicious paths, file/directory/root symlinks and prefix-sibling escape, real destination collision/final-commit race, readonly/missing parents, injected copy/JSON-write/validation/commit failures, mid-copy/final-fence cancellation, foreign staging preservation and a valid 64 MiB generated sparse WAV copied in 65 bounded chunks. Tests assert injection checkpoints were actually reached. Direct generated AAC collection verifies the same metadata as AVAudioFile, and read/resolve cancellation leaves the package unchanged.

The repository's existing CI additionally generates AAC, exercises app audio integration, runs all Swift/Python tests and builds the release executable on both configured SDK lanes. Full #14 remains open until Source's Save As/Save Copy/autosave, relocated playback/L/R and Finder integration are independently reviewed.
