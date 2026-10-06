"""Format/guard unit tests; these do not substitute for a real release archive proof."""
import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

from build import REPO, new_output, parse_args, source_snapshot
from bundle import MODEL_RESOURCES, check_manifest, check_metadata, metadata, sha256, validate_version, verify_archive, verify_bundle


class DeliveryMetadataTests(unittest.TestCase):
    def test_both_document_types_are_editors_with_package_and_alternate_rank(self):
        info = metadata("1.2.3", "7")
        self.assertEqual([d["LSItemContentTypes"] for d in info["CFBundleDocumentTypes"]],
                         [["com.roughscore.project"], ["com.roughscore.portable-project"]])
        self.assertEqual([d["LSTypeIsPackage"] for d in info["CFBundleDocumentTypes"]], [False, True])
        self.assertTrue(all(d["CFBundleTypeRole"] == "Editor" and d["LSHandlerRank"] == "Alternate" for d in info["CFBundleDocumentTypes"]))
        check_metadata(plistlib.loads(plistlib.dumps(info)), "1.2.3", "7")

    def test_pinned_old_builder_metadata_reproduces_missing_document_registration(self):
        old = subprocess.check_output(["git", "show", "31c0fb768ec617d4707de9e8e7b0b6d14d37b414:scripts/build-app.sh"], cwd=REPO, text=True)
        xml = old.split("<<'PLIST'\n", 1)[1].split("\nPLIST", 1)[0]
        old_info = plistlib.loads(xml.encode())
        self.assertNotIn("CFBundleDocumentTypes", old_info)
        self.assertIn("UTExportedTypeDeclarations", old_info)
        with self.assertRaises(ValueError):
            check_metadata(old_info, "0.1.0", "1")

    def test_metadata_rejects_wrong_uti_role_package_rank_minimum_and_version(self):
        original = metadata("1.2.3", "7")
        mutations = [("LSMinimumSystemVersion", "27.0"), ("CFBundleVersion", 7), ("CFBundleExecutable", "Other")]
        for key, value in mutations:
            with self.subTest(key=key):
                info = copy.deepcopy(original); info[key] = value
                with self.assertRaises(ValueError): check_metadata(info, "1.2.3", "7")
        for key, value in [("LSTypeIsPackage", 1), ("CFBundleTypeRole", "Viewer"), ("LSItemContentTypes", ["public.json"]), ("LSHandlerRank", "Owner")]:
            with self.subTest(key=key):
                info = copy.deepcopy(original); info["CFBundleDocumentTypes"][1][key] = value
                with self.assertRaises(ValueError): check_metadata(info, "1.2.3", "7")

    def test_numeric_version_and_positive_build_validation(self):
        validate_version("0.1.0", "1")
        for version, build in [("1.2", "1"), ("v1.2.3", "1"), ("1.2.3-beta", "1"), ("1.2.3\n", "1"), ("1.2.3", "0"), ("1.2.3", "-1"), ("1.2.3", "1.0"), (1, "1"), ("1.2.3", True)]:
            with self.subTest(version=version, build=build):
                with self.assertRaises(ValueError): validate_version(version, build)


class DeliveryOutputTests(unittest.TestCase):
    def test_new_output_is_exclusively_created_and_old_data_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "new"
            new_output(output)
            marker = output / "keep"; marker.write_text("protected")
            with self.assertRaises(ValueError): new_output(output)
            self.assertEqual(marker.read_text(), "protected")

    def test_dangling_and_existing_symlinks_are_rejected_without_following(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, target in [("dangling", root / "absent"), ("existing", root)]:
                path = root / name; path.symlink_to(target, target_is_directory=True)
                with self.assertRaises(ValueError): new_output(path)
                self.assertTrue(path.is_symlink())

    def test_missing_parent_and_checkout_output_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(OSError): new_output(root / "missing" / "new")
            with self.assertRaises(ValueError): new_output(root / "inside", repo=root)
            self.assertFalse((root / "inside").exists())

    def test_cli_malformed_options_never_create_output(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "new"
            for options in [[], ["--version", "1.2" ,"--build", "1"], ["--version", "1.2.3", "--build", "0"], ["--version", "1.2.3", "--build", "1", "--unknown"]]:
                result = subprocess.run(["bash", str(REPO / "scripts/build-app.sh"), str(output), *options], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_cli_existing_output_and_symlink_preserve_collision(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            existing = root / "existing"; existing.mkdir(); (existing / "keep").write_text("original")
            dangling = root / "dangling"; dangling.symlink_to(root / "absent")
            for path in [existing, dangling]:
                result = subprocess.run(["bash", str(REPO / "scripts/build-app.sh"), str(path), "--version", "1.2.3", "--build", "1", "--allow-dirty"], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("output already exists", result.stderr)
            self.assertEqual((existing / "keep").read_text(), "original")
            self.assertTrue(dangling.is_symlink())

    def test_allow_dirty_is_explicit_and_clean_policy_is_default(self):
        args = parse_args(["/unused/new", "--version", "1.2.3", "--build", "1"])
        self.assertFalse(args.allow_dirty)
        self.assertTrue(parse_args(["/unused/new", "--version", "1.2.3", "--build", "1", "--allow-dirty"]).allow_dirty)


class DeliveryProvenanceTests(unittest.TestCase):
    def repository(self, root):
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / ".gitignore").write_text("ignored/\n")
        (root / "source.swift").write_text("let a = 1\n")
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], cwd=root, check=True)

    def test_clean_commit_and_modified_source_hash_are_truthful(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.repository(root)
            before = source_snapshot(root)
            self.assertTrue(before["clean"]); self.assertEqual(before["provenance"], "clean-commit")
            (root / "source.swift").write_text("let a = 2\n")
            after = source_snapshot(root)
            self.assertFalse(after["clean"]); self.assertEqual(after["commit"], before["commit"])
            self.assertNotEqual(after["workingTreeSHA256"], before["workingTreeSHA256"])
            self.assertEqual(after["provenance"], "modified-source-snapshot")

    def test_ignored_contents_are_not_read_or_hashed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.repository(root)
            before = source_snapshot(root)
            ignored = root / "ignored"; ignored.mkdir(); private = ignored / "private"; private.write_text("never an input")
            private.chmod(0)
            self.assertEqual(source_snapshot(root), before)
            private.chmod(0o600)

    def test_source_symlink_hashes_link_text_without_reading_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "repo"; root.mkdir(); self.repository(root)
            outside = Path(temp) / "outside"; outside.write_text("outside data")
            (root / "link").symlink_to(outside)
            before = source_snapshot(root); outside.write_text("changed outside data")
            self.assertEqual(source_snapshot(root), before)

    def test_invalid_manifest_cleanliness_and_missing_toolchain_are_rejected(self):
        manifest = dict(schemaVersion=1, version="1.2.3", build="1", bundleIdentifier="com.roughscore.sketch",
            source=dict(commit="a" * 40, clean=True, workingTreeSHA256="b" * 64, fileCount=1, provenance="clean-commit"),
            signingMode="ad-hoc", deploymentTarget="15.0", analysisCompileCapability="enabled", executableSHA256="c" * 64,
            toolchain=dict(swift="Swift", xcode="Xcode", sdk="27.0", os="27.0.1", architecture="arm64"))
        check_manifest(manifest)
        bad = copy.deepcopy(manifest); bad["source"]["provenance"] = "modified-source-snapshot"
        with self.assertRaises(ValueError): check_manifest(bad)
        bad = copy.deepcopy(manifest); del bad["toolchain"]["sdk"]
        with self.assertRaises(ValueError): check_manifest(bad)
        with self.assertRaises(ValueError): check_manifest([])


class DeliveryVerificationNegativeTests(unittest.TestCase):
    def test_plain_executable_never_passes_as_native_delivery(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "RoughScore.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/_CodeSignature").mkdir()
            executable = app / "Contents/MacOS/RoughScore"; executable.write_text("#!/bin/sh\nexit 0\n"); executable.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata("1.2.3", "1")))
            (app / "Contents/_CodeSignature/CodeResources").write_text("mock")
            for name in MODEL_RESOURCES:
                (app / name).parent.mkdir(parents=True, exist_ok=True); (app / name).write_text("mock")
            with self.assertRaisesRegex(ValueError, "not Mach-O"):
                verify_bundle(app, "1.2.3", "1")

    def test_checksum_and_unexpected_archive_members_fail_before_extraction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); archive = root / "bad.zip"; checksum = root / "bad.zip.sha256"
            with zipfile.ZipFile(archive, "x") as z: z.writestr("bad/../../outside", "not allowed")
            checksum.write_text("wrong checksum")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"): verify_archive(archive, checksum)
            checksum.write_text(sha256(archive) + "  " + archive.name + "\n")
            with self.assertRaisesRegex(ValueError, "unexpected archive contents"): verify_archive(archive, checksum)
            self.assertFalse((root / "outside").exists())


if __name__ == "__main__":
    unittest.main()
