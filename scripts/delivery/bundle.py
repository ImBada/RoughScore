#!/usr/bin/env python3
"""Typed developer-bundle contracts and headless, real Mach-O/ad-hoc verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile

BUNDLE_ID = "com.roughscore.sketch"
TYPES = [("com.roughscore.project", "RoughScore Project", "public.json", "roughscore", False),
         ("com.roughscore.portable-project", "RoughScore Collected Project", "com.apple.package", "roughscorepkg", True)]


def run(args, **kwargs):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, **kwargs).strip()


def sha256(path):
    with Path(path).open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def validate_version(version, build):
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("version must have three numeric components (e.g. 0.1.0)")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("build must be a positive integer")


def metadata(version, build):
    validate_version(version, build)
    return dict(CFBundleName="RoughScore", CFBundleDisplayName="RoughScore", CFBundleIdentifier=BUNDLE_ID,
                CFBundleExecutable="RoughScore", CFBundlePackageType="APPL", CFBundleShortVersionString=version,
                CFBundleVersion=build, LSMinimumSystemVersion="15.0", NSHighResolutionCapable=True,
                UTExportedTypeDeclarations=[dict(UTTypeIdentifier=uti, UTTypeDescription=name,
                    UTTypeConformsTo=[conforms], UTTypeTagSpecification={"public.filename-extension": [ext]})
                    for uti, name, conforms, ext, package in TYPES],
                CFBundleDocumentTypes=[dict(CFBundleTypeName=name, LSItemContentTypes=[uti],
                    CFBundleTypeRole="Editor", LSHandlerRank="Alternate", LSTypeIsPackage=package)
                    for uti, name, conforms, ext, package in TYPES])


def check_metadata(info, version, build):
    expected = metadata(version, build)
    # Equality alone would let bools impersonate integers. Check exact plist types as well.
    def same(actual, wanted):
        if type(actual) is not type(wanted):
            return False
        if isinstance(wanted, dict):
            return actual.keys() == wanted.keys() and all(same(actual[k], v) for k, v in wanted.items())
        if isinstance(wanted, list):
            return len(actual) == len(wanted) and all(same(a, b) for a, b in zip(actual, wanted))
        return actual == wanted
    if not same(info, expected):
        raise ValueError("bundle plist differs from typed document/version/deployment metadata contract")


def check_manifest(manifest):
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be an object")
    if manifest.get("schemaVersion") != 1 or type(manifest["schemaVersion"]) is not int:
        raise ValueError("unsupported manifest schema")
    validate_version(manifest.get("version", ""), manifest.get("build", ""))
    source = manifest.get("source", {})
    if not isinstance(source, dict):
        raise ValueError("source provenance must be an object")
    for key, length in [("commit", 40), ("workingTreeSHA256", 64)]:
        if not isinstance(source.get(key), str) or not re.fullmatch(r"[a-f0-9]{%d}" % length, source[key]):
            raise ValueError("missing source provenance: " + key)
    if type(source.get("clean")) is not bool or type(source.get("fileCount")) is not int or source["fileCount"] < 1:
        raise ValueError("missing source cleanliness/inventory")
    if source.get("provenance") != ("clean-commit" if source["clean"] else "modified-source-snapshot"):
        raise ValueError("source provenance disagrees with cleanliness")
    if manifest.get("signingMode") != "ad-hoc" or manifest.get("bundleIdentifier") != BUNDLE_ID or manifest.get("deploymentTarget") != "15.0":
        raise ValueError("unexpected identity/signing/deployment")
    if manifest.get("analysisCompileCapability") not in ["enabled", "disabled"]:
        raise ValueError("missing SDK capability proof")
    if not isinstance(manifest.get("executableSHA256"), str) or not re.fullmatch(r"[a-f0-9]{64}", manifest["executableSHA256"]):
        raise ValueError("missing executable digest")
    if not isinstance(manifest.get("toolchain"), dict):
        raise ValueError("missing toolchain provenance")
    for key in ["swift", "xcode", "sdk", "os", "architecture"]:
        if not isinstance(manifest.get("toolchain", {}).get(key), str) or not manifest["toolchain"][key]:
            raise ValueError("missing toolchain field: " + key)


def verify_bundle(app, version, build, manifest=None):
    app = Path(app)
    if not app.is_dir() or app.is_symlink():
        raise ValueError("expected a real app directory")
    files = {p.relative_to(app).as_posix() for p in app.rglob("*") if p.is_file()}
    expected = {"Contents/Info.plist", "Contents/MacOS/RoughScore", "Contents/_CodeSignature/CodeResources"}
    if files != expected or any(p.is_symlink() for p in app.rglob("*")):
        raise ValueError("unexpected bundle contents")
    run(["/usr/bin/plutil", "-lint", str(app / "Contents/Info.plist")])
    with (app / "Contents/Info.plist").open("rb") as stream:
        check_metadata(plistlib.load(stream), version, build)
    executable = app / "Contents/MacOS/RoughScore"
    if not stat.S_ISREG(executable.stat().st_mode) or not executable.stat().st_mode & 0o111:
        raise ValueError("app executable missing regular/executable permissions")
    if "Mach-O" not in run(["/usr/bin/file", "-b", str(executable)]):
        raise ValueError("app executable is not Mach-O")
    load_commands = run(["/usr/bin/otool", "-l", str(executable)])
    minimums = re.findall(r"\bminos\s+(\S+)", load_commands)
    if not minimums or any(v not in ["15.0", "15.0.0"] for v in minimums):
        raise ValueError("Mach-O deployment target must match Package.swift/macOS 15")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    signature = run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)])
    if "Signature=adhoc" not in signature or "Identifier=" + BUNDLE_ID + "\n" not in signature + "\n":
        raise ValueError("bundle must have the expected ad-hoc identifier")
    digest = sha256(executable)
    architectures = run(["/usr/bin/lipo", "-archs", str(executable)]).split()
    if manifest is not None:
        check_manifest(manifest)
        if manifest["version"] != version or manifest["build"] != build or manifest["executableSHA256"] != digest:
            raise ValueError("bundle/manifest disagreement")
        if architectures != [manifest["toolchain"]["architecture"]]:
            raise ValueError("Mach-O architecture/manifest disagreement")
    return dict(executableSHA256=digest, signature="ad-hoc strict seal verified", deploymentTarget="15.0")


def verify_archive(archive, checksum):
    archive, checksum = Path(archive), Path(checksum)
    expected_checksum = sha256(archive) + "  " + archive.name + "\n"
    if checksum.read_text() != expected_checksum:
        raise ValueError("archive checksum mismatch")
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        if len(names) != len(set(names)) or not names:
            raise ValueError("empty/duplicate archive members")
        roots = {name.split("/")[0] for name in names}
        if len(roots) != 1:
            raise ValueError("expected one versioned archive directory")
        root = roots.pop()
        if root + ".zip" != archive.name:
            raise ValueError("archive root/name disagreement")
        allowed = {root + "/" + name for name in ["DEVELOPER-INSTALL.md", "manifest.json",
            "RoughScore.app/Contents/Info.plist", "RoughScore.app/Contents/MacOS/RoughScore",
            "RoughScore.app/Contents/_CodeSignature/CodeResources"]}
        if set(names) != allowed:
            raise ValueError("unexpected archive contents")
        for member in z.infolist():
            if stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError("archive must not contain symlinks")
        manifest = json.loads(z.read(root + "/manifest.json"))
        check_manifest(manifest)
        wanted_name = f'RoughScore-{manifest["version"]}-{manifest["build"]}-{manifest["source"]["commit"][:12]}'
        if root != wanted_name:
            raise ValueError("manifest/versioned archive name disagreement")
        # Extract only allowlisted files into a new owned temporary directory; never launch the app.
        with tempfile.TemporaryDirectory(prefix="roughscore-archive-verify-", dir=archive.parent) as temp:
            for member in z.infolist():
                path = Path(temp) / member.filename
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("xb") as stream:
                    stream.write(z.read(member))
                os.chmod(path, stat.S_IMODE(member.external_attr >> 16))
            result = verify_bundle(Path(temp) / root / "RoughScore.app", manifest["version"], manifest["build"], manifest)
    return dict(archiveSHA256=sha256(archive), sourceCommit=manifest["source"]["commit"], **result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="kind", required=True)
    bundle = sub.add_parser("bundle")
    bundle.add_argument("app", type=Path); bundle.add_argument("--version", required=True); bundle.add_argument("--build", required=True)
    archive = sub.add_parser("archive")
    archive.add_argument("archive", type=Path); archive.add_argument("checksum", type=Path)
    args = parser.parse_args()
    try:
        result = verify_bundle(args.app, args.version, args.build) if args.kind == "bundle" else verify_archive(args.archive, args.checksum)
        print(json.dumps(result, indent=2))
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
