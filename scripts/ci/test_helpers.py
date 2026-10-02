"""Contract tests for coverage reporting and generated fixture independence."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import wave

from generate_audio import generate
from verify_test_log import verify


class CoverageReportingTests(unittest.TestCase):
    def log(self, count=72, fixture=True):
        return ("Test realAudioFixtureWhenProvided() passed\n" +
                ("Real audio: 2.0s, 200 bins/channel\n" if fixture else "") +
                f"Test run with {count} tests in 9 suites passed\n")

    def test_zero_xctest_cases_are_not_swift_testing_coverage(self):
        with self.assertRaises(ValueError):
            verify("Executed 0 tests, with 0 failures\n")

    def test_silent_optional_fixture_pass_is_rejected(self):
        with self.assertRaises(ValueError):
            verify(self.log(fixture=False))

    def test_incomplete_suite_is_rejected(self):
        with self.assertRaises(ValueError):
            verify(self.log(count=1))

    def test_missing_fixture_test_result_is_rejected(self):
        with self.assertRaises(ValueError):
            verify(self.log().replace("Test realAudioFixtureWhenProvided() passed", ""))

    def test_generated_coverage_is_not_real_guitar_quality(self):
        result = verify(self.log(count=80))
        self.assertEqual(result["swiftTestingCases"], 80)
        self.assertEqual(result["generatedCompressedIntegration"], "passed")
        self.assertTrue(result["realGuitarEvaluation"].startswith("skipped:"))


class GeneratedFixtureTests(unittest.TestCase):
    def test_reproducible_stereo_pcm_without_recordings(self):
        with tempfile.TemporaryDirectory() as root:
            paths = [generate(Path(root) / name) for name in ["first", "second"]]
            self.assertEqual(paths[0].read_bytes(), paths[1].read_bytes())
            manifest = json.loads((paths[0].parent / "manifest.json").read_text())
            self.assertEqual(manifest["pcmSHA256"], hashlib.sha256(paths[0].read_bytes()).hexdigest())
            with wave.open(str(paths[0])) as audio:
                self.assertEqual((audio.getnchannels(), audio.getframerate(), audio.getnframes()),
                                 (2, 48_000, 96_000))

    def test_existing_fixture_directory_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "fixture"
            generate(path)
            with self.assertRaises(FileExistsError):
                generate(path)


if __name__ == "__main__":
    unittest.main()
