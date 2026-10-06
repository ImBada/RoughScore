#!/usr/bin/env python3
"""Build a fresh, credentials-free developer app and checked ZIP in an explicit new output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

from bundle import BUNDLE_ID, metadata, run, sha256, validate_version, verify_archive, verify_bundle

REPO = Path(__file__).resolve().parents[2]


def source_snapshot(repo):
    commit = run(["git", "rev-parse", "HEAD"], cwd=repo)
    status = run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=repo)
    files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=repo).split(b"\0")
    digest = hashlib.sha256()
    names = sorted(set(name for name in files if name))
    for name in names:
        path = repo / os.fsdecode(name)
        # Git-owned/nonignored inventory only. A source symlink hashes its text, never its target.
        if path.is_symlink():
            kind, content = b"link", os.fsencode(os.readlink(path))
        elif path.is_file():
            kind, content = b"file:" + oct(path.stat().st_mode & 0o111).encode(), path.read_bytes()
        elif not path.exists():
            kind, content = b"deleted", b""
        else:
            raise ValueError("unsupported source inventory entry")
        for value in [name, kind, hashlib.sha256(content).digest()]:
            digest.update(len(value).to_bytes(8, "big")); digest.update(value)
    return dict(commit=commit, clean=not status, workingTreeSHA256=digest.hexdigest(), fileCount=len(names),
                provenance="clean-commit" if not status else "modified-source-snapshot")


def new_output(path, repo=REPO):
    repo = Path(repo).resolve(strict=True)
    path = Path(os.path.abspath(path))
    if os.path.lexists(path):
        raise ValueError("output already exists (including symlinks); refusing to overwrite")
    parent = path.parent.resolve(strict=True)
    if not parent.is_dir():
        raise ValueError("output parent must be an existing directory")
    path = parent / path.name
    if path == repo or repo in path.parents:
        raise ValueError("output must be outside the source checkout")
    # Atomic creation rejects a concurrent collision; no cleanup/deletion of old output.
    path.mkdir()
    return path


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, metavar="NEW_OUTPUT_DIRECTORY")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--allow-dirty", action="store_true", help="QA only: record a truthful modified-source snapshot")
    args = parser.parse_args(argv)
    validate_version(args.version, args.build)
    return args


def build(args):
    before = source_snapshot(REPO)
    if not before["clean"] and not args.allow_dirty:
        raise ValueError("source must be clean; commit first, or explicitly use --allow-dirty for QA")
    output = new_output(args.output)
    env = os.environ.copy()
    env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"), SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
               MACOSX_DEPLOYMENT_TARGET="15.0", PYTHONDONTWRITEBYTECODE="1")
    command = ["swift", "build", "--disable-sandbox", "--scratch-path", str(output / "build"),
               "--cache-path", str(output / "spm-cache"), "-c", "release", "-debug-info-format", "none"]
    with (output / "build.log").open("x") as log:
        subprocess.run(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = Path(run(command + ["--show-bin-path"], cwd=REPO, env=env)) / "RoughScore"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("SwiftPM did not produce an executable")
    probe = output / "sdk-capability.swift"
    probe.write_text('#if canImport(MusicUnderstanding)\nprint("enabled")\n#else\nprint("disabled")\n#endif\n')
    capability = run(["swift", str(probe)], cwd=REPO, env=env)
    if capability not in ["enabled", "disabled"]:
        raise ValueError("unexpected compile capability probe result")
    name = f'RoughScore-{args.version}-{args.build}-{before["commit"][:12]}'
    payload = output / name
    app = payload / "RoughScore.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy2(binary, app / "Contents/MacOS/RoughScore")
    with (app / "Contents/Info.plist").open("xb") as stream:
        plistlib.dump(metadata(args.version, args.build), stream)
    # This freshly copied compiler binary may already have a linker ad-hoc seal.
    # --force is restricted to this sole-owned NEW bundle, never an existing app.
    signing = run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", BUNDLE_ID, str(app)])
    (output / "signing.log").write_text(signing + "\n")
    bundle_result = verify_bundle(app, args.version, args.build)
    after = source_snapshot(REPO)
    if after != before:
        raise ValueError("source changed during build; artifact cannot claim the captured provenance")
    manifest = dict(schemaVersion=1, version=args.version, build=args.build, bundleIdentifier=BUNDLE_ID,
        source=before, signingMode="ad-hoc", deploymentTarget="15.0", analysisCompileCapability=capability,
        executableSHA256=bundle_result["executableSHA256"],
        toolchain=dict(swift=run(["swift", "--version"], env=env), xcode=run(["xcodebuild", "-version"], env=env),
                       sdk=run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], env=env),
                       os=run(["sw_vers", "-productVersion"]), architecture=run(["uname", "-m"])),
        options=dict(version=args.version, build=args.build, allowDirty=args.allow_dirty),
        reproducibility="Repeatable process and source provenance; byte-identical output not measured. Timestamps, signatures and build paths may vary.",
        limitations=["Ad-hoc developer testing; no Developer ID, notarization or Gatekeeper trust claim.",
                     "SDK capability is compile availability, not successful music analysis.",
                     "Minimum macOS 15 metadata is not a macOS 15 runtime/fallback SDK test."])
    (payload / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    shutil.copyfile(REPO / "docs/DEVELOPER-INSTALL.md", payload / "DEVELOPER-INSTALL.md")
    archive = output / (name + ".zip")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(payload.rglob("*")):
            if path.is_file():
                z.write(path, path.relative_to(output).as_posix())
    checksum = output / (archive.name + ".sha256")
    with checksum.open("x") as stream:
        stream.write(sha256(archive) + "  " + archive.name + "\n")
    result = verify_archive(archive, checksum)
    if source_snapshot(REPO) != before:
        raise ValueError("source changed during packaging; provenance verification failed")
    (output / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(dict(app=str(app), archive=str(archive), checksum=str(checksum), **result), indent=2))


def main():
    try:
        build(parse_args(sys.argv[1:]))
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
