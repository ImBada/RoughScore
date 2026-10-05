# RoughScore developer archive

This ZIP is a local, ad-hoc signed developer build. It does not establish Developer ID signing, notarization, or Gatekeeper trust. Trusted distribution is a separate issue (#19). The builder does not install, launch, register a default handler, or publish anything.

## Verify and extract

Keep the ZIP and its `.zip.sha256` file together. In that folder run:

```sh
shasum -a 256 -c RoughScore-VERSION-BUILD-SOURCE.zip.sha256
```

Replace the placeholder with the exact delivered filename. A checksum detects changed bytes; it does not authenticate the sender. Only use an archive from a source you trust. Extract into a **new folder you chose**, without replacing a prior app. The versioned folder contains `RoughScore.app`, `manifest.json`, and this guide. Keep older developer builds deliberately, or rename them before manually copying the new app to a chosen install location. A copy to your own Applications folder is optional; this process needs no installer or privileged command.

On macOS with the source checkout available, verify the actual extracted Mach-O, executable permissions, typed plist, deployment metadata, and strict ad-hoc seal without launching:

```sh
python3 scripts/delivery/bundle.py bundle /chosen/fresh/folder/RoughScore.app --version VERSION --build BUILD
# Or verify the ZIP, checksum, extracted bundle and manifest together:
python3 scripts/delivery/bundle.py archive /chosen/archive.zip /chosen/archive.zip.sha256
```

macOS may prevent opening an ad-hoc developer app. Follow your organization's policy and macOS's displayed security controls. No trusted-distribution claim or automatic security-settings change is included here.

## Open projects explicitly

Choose a single generated or backed-up project in Finder, then **Open With → Other… → this RoughScore.app**. Leave **Always Open With** unchecked. The app advertises an alternate editor for `.roughscore` and `.roughscorepkg`; this does not prove or request a default association. The same window handles cold and warm URL delivery, including reopening its closed window. Actual Finder delivery must be verified on the target Mac.

- `.roughscore` is a linked JSON project. Its audio references point to external files: move those files separately or expect offline TAB editing when they are unavailable.
- `.roughscorepkg` is a collected directory package. It carries collected media; move the whole package. Missing media in an otherwise valid project can still allow offline TAB editing.
- Native requests accept exactly **one local project**, with case-insensitive extensions. Empty, multiple, missing, unsupported, remote, and wrong-kind requests are rejected visibly. A regular file is required for `.roughscore`; a directory package is required for `.roughscorepkg`.
- Before the window is ready, the first structurally valid request wins. Additional requests, including duplicates, show a retry message. That explicit request supersedes automatic CLI/last-project/demo startup. A failed or cancelled explicit open never restarts automatic fallback.
- During ordinary loading, analysis, save, export, a native modal, or another external confirmation, finish the current operation and retry. Those operations are not cancelled by a new Finder request. Only automatic startup may be superseded.
- Unsaved work uses **Save and Continue / Cancel / Discard**. Save cancellation/failure keeps the old work. Discard permission belongs to that exact request and document. Cancel preserves an uncommitted drag preview; after authorization a load reservation cancels the preview without committing it. Failed loads retain the document/history/resources, although reservation may flush local session state and close memo coalescing.
- Successful activation restores bounded document-local view settings, resets transient editor state/history, and leaves incoming players paused. A failed open does not request TAB focus. Rejection feedback appears separately from save/load error alerts.

The command-line argument parser is legacy convenience: it picks the first argument with a project extension and keeps the existing automatic-startup fallback behavior. It is separate from the strict native URL policy.

## Platform and provenance

The package and bundle declare macOS **15.0** minimum. Music Understanding requires an SDK with that framework and macOS **27+** at runtime. `analysisCompileCapability` in the manifest records the actual enabled/disabled compile probe, not successful analysis, transcription quality, or fallback/macOS 15 runtime verification.

The manifest records the full source commit, source cleanliness, a digest of tracked/nonignored source inputs, toolchain/SDK/OS/architecture, version/build, deployment target, executable digest, and ad-hoc signing mode. The builder requires clean source by default. Explicit `--allow-dirty` is for local QA and labels a modified-source snapshot honestly.

This is a repeatable process with input provenance, **not a measured byte-identical build**. ZIP timestamps, linker output, build paths and signatures can vary. Generated AAC checks cover codec/channel behavior; they do not establish music-model quality. GitHub CI remains disabled; this archive is built and checked locally. Finder/dirty-dialog/native UI, macOS 15/fallback SDK, spoken VoiceOver, trusted signing and notarization require their own evidence.
