import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from evaluation.metrics import EvaluationError, WavReader, match_notes, note_metrics, source_metrics
from evaluation.report import digest, evaluate
from evaluation.fixtures import acquire, choose_window, jams_notes, safe_member, selected_member, verify_archive


def note(onset, midi=40, lane='left', qualified=True):
    return dict(onset=onset, midi=midi, lane=lane, qualified=qualified)


def write_wav(path, channels, floating=True, rate=8000):
    data = bytearray()
    for frame in zip(*channels):
        for v in frame:
            data += struct.pack('<f', v) if floating else struct.pack('<h', round(v * 32767))
    code, bits = (3, 32) if floating else (1, 16)
    align = len(channels) * bits // 8
    fmt = struct.pack('<HHIIHH', code, len(channels), rate, rate * align, align, bits)
    path.write_bytes(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<I', 16) + fmt + b'data' + struct.pack('<I', len(data)) + data)


class NoteTests(unittest.TestCase):
    def test_ambiguous_assignment_requires_reassigning_a_prior_match(self):
        truth = [note(.10), note(.16)]
        guesses = [note(.13), note(.08)]
        m = note_metrics(truth, guesses)
        self.assertEqual(m['true_positives'], 2)
        self.assertAlmostEqual(m['onset_error_mean_absolute_seconds'], .025)

    def test_maximum_cardinality_uses_minimum_total_error(self):
        m = note_metrics([note(1), note(1.04)], [note(1.01), note(1.035)])
        self.assertAlmostEqual(m['onset_error_mean_absolute_seconds'], .0075)
        self.assertEqual(m['matched_onset_errors_seconds'], [1.01 - 1, 1.035 - 1.04])

    def test_duplicates_and_wrong_lane_pitch_are_false_positives(self):
        m = note_metrics([note(1)], [note(1), note(1), note(1, 41), note(1, lane='right')])
        self.assertEqual((m['true_positives'], m['false_positives']), (1, 3))
        self.assertEqual(m['precision'], .25)

    def test_tolerance_inclusive_and_just_outside(self):
        self.assertEqual(len(match_notes([note(1)], [note(1.05)])), 1)
        self.assertEqual(len(match_notes([note(1)], [note(1.050001)])), 0)

    def test_unknown_pitch_reports_onset_without_inventing_pitch(self):
        m = note_metrics([note(1)], [note(1, midi=None, qualified=False)])
        self.assertEqual(m['true_positives'], 0)
        self.assertEqual(m['onset_true_positives_ignoring_pitch'], 1)
        self.assertIsNone(m['qualified_precision'])

    def test_precision_is_not_inflated_by_abstention(self):
        m = note_metrics([note(1), note(2)], [note(1)])
        self.assertEqual(m['qualified_precision'], 1)
        self.assertEqual(m['qualified_reference_coverage'], .5)
        self.assertEqual(m['recall'], .5)

    def test_invalid_notes_are_not_silently_filtered(self):
        for bad in [note(-1), note(float('nan')), note(1, midi=40.5), note(1, lane='stereo'), dict(onset=1, midi=True)]:
            with self.subTest(bad=bad), self.assertRaises(EvaluationError):
                note_metrics([note(1)], [bad])

    def test_prediction_order_does_not_change_match_metrics(self):
        truth = [note(1), note(1.04), note(2, 64)]
        guesses = [note(1.01), note(1.035), note(2.02, 64), note(3)]
        first, second = note_metrics(truth, guesses), note_metrics(truth, list(reversed(guesses)))
        for key in ('precision', 'recall', 'onset_error_mean_absolute_seconds', 'onset_error_p95_absolute_seconds'):
            self.assertEqual(first[key], second[key])


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        # Exactly orthogonal, zero-mean references with known analytic ratios.
        self.target = [1, -1, 1, -1] * 100
        self.interference = [1, 1, -1, -1] * 100
        self.paths = [self.root / x for x in ('target.wav', 'mixture.wav', 'estimate.wav')]

    def tearDown(self):
        self.temp.cleanup()

    def run_metric(self, target, mixture, estimate):
        for path, channels in zip(self.paths, (target, mixture, estimate)):
            write_wav(path, channels)
        return source_metrics(*self.paths)

    def test_six_db_improvement_and_minus_six_db_bleed(self):
        s, i = self.target, self.interference
        m = self.run_metric([s], [[a + b for a, b in zip(s, i)]], [[a + .5 * b for a, b in zip(s, i)]])
        self.assertAlmostEqual(m['si_sdr']['value_db'], 10 * math.log10(4))
        self.assertAlmostEqual(m['si_sdr_improvement']['value_db'], 10 * math.log10(4))
        self.assertAlmostEqual(m['bleed_to_target']['value_db'], -10 * math.log10(4))

    def test_gain_and_dc_are_removed_per_channel(self):
        s, i = self.target, self.interference
        m = self.run_metric([s, s], [[a + b for a, b in zip(s, i)]] * 2,
                            [[2 * a + b + 10 for a, b in zip(s, i)], [2 * a + b - 3 for a, b in zip(s, i)]])
        self.assertAlmostEqual(m['si_sdr_improvement']['value_db'], 10 * math.log10(4))
        self.assertEqual(len(m['channels']), 2)

    def test_stereo_swap_is_not_hidden_by_downmix(self):
        s, i = self.target, self.interference
        m = self.run_metric([s, i], [[a + b for a, b in zip(s, i)], [a - b for a, b in zip(i, s)]], [i, s])
        self.assertEqual(m['si_sdr']['limit'], 'negative_infinity')

    def test_perfect_output_has_json_safe_infinity(self):
        s, i = self.target, self.interference
        m = self.run_metric([s], [[a + b for a, b in zip(s, i)]], [[2 * a for a in s]])
        self.assertEqual(m['si_sdr']['limit'], 'positive_infinity')
        json.dumps(m, allow_nan=False)

    def test_missing_interference_or_silent_estimate_is_undefined(self):
        for mixture, estimate in [(self.target, self.target), ([a + b for a, b in zip(self.target, self.interference)], [0] * len(self.target))]:
            with self.subTest(estimate=estimate[:2]), self.assertRaises(EvaluationError):
                self.run_metric([self.target], [mixture], [estimate])

    def test_mismatched_frame_count_and_nonfinite_pcm_rejected(self):
        with self.assertRaises(EvaluationError):
            self.run_metric([self.target], [self.interference], [self.target[:-1]])
        values = self.target.copy()
        values[10] = float('nan')
        with self.assertRaises(EvaluationError):
            self.run_metric([self.target], [self.interference], [values])

    def test_zero_target_projection_baseline_cannot_manufacture_infinite_gain(self):
        with self.assertRaises(EvaluationError):
            self.run_metric([self.target], [self.interference], [self.target])

    def test_pcm16_decode_and_truncation(self):
        write_wav(self.paths[0], [[.25, -.5]], floating=False)
        r = WavReader(self.paths[0])
        self.assertAlmostEqual(r.read()[0], .25, places=4)
        r.close()
        self.paths[0].write_bytes(self.paths[0].read_bytes()[:-1])
        with self.assertRaises(EvaluationError):
            WavReader(self.paths[0])


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest, self.predictions = self.root / 'manifest.json', self.root / 'predictions.json'
        self.reference = self.root / 'notes.json'
        self.reference.write_text(json.dumps({'schema_version': 1, 'notes': [note(1), note(2)]}))
        self.case = {'id': 'clean', 'slice': 'clean_mono', 'material': 'real', 'license': 'test-only', 'source': 'generated test oracle (label real only to exercise gate logic)',
                     'reference_method': 'hand specified metric test', 'notes_reference': {'path': 'notes.json', 'sha256': digest(self.reference)}}
        self.write_manifest([self.case])

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self, cases):
        self.manifest.write_text(json.dumps({'schema_version': 1, 'name': 'test', 'cases': cases}))

    def write_predictions(self, notes):
        self.predictions.write_text(json.dumps({'schema_version': 1, 'engine': {'id': 'metric-test-oracle', 'version': '1'}, 'cases': [{'id': 'clean', 'notes': notes}]}))

    def test_missing_engine_predictions_are_blocked_not_pass(self):
        r = evaluate(self.manifest)
        self.assertEqual(r['cases'][0]['notes']['status'], 'SKIPPED')
        self.assertEqual(r['real_slices']['clean_mono']['status'], 'BLOCKED')
        self.assertEqual(r['release_gate']['status'], 'BLOCKED')

    def test_explicit_empty_predictions_fail_and_bad_hash_blocks(self):
        self.write_predictions([])
        self.assertEqual(evaluate(self.manifest, self.predictions)['real_slices']['clean_mono']['status'], 'FAIL')
        self.reference.write_text('{}')
        self.assertEqual(evaluate(self.manifest, self.predictions)['cases'][0]['notes']['status'], 'BLOCKED')

    def test_high_precision_low_qualified_coverage_cannot_pass(self):
        self.write_predictions([note(1), note(2, qualified=False)])
        r = evaluate(self.manifest, self.predictions)
        self.assertEqual(r['real_slices']['clean_mono']['status'], 'FAIL')
        self.assertEqual(r['real_slices']['clean_mono']['metrics']['recall'], 1)

    def test_missing_quality_labels_block_mono_gate(self):
        self.write_predictions([{'onset': 1, 'midi': 40}, {'onset': 2, 'midi': 40}])
        self.assertEqual(evaluate(self.manifest, self.predictions)['real_slices']['clean_mono']['status'], 'BLOCKED')

    def test_synthetic_success_never_passes_real_release_gate(self):
        self.write_manifest([dict(self.case, material='synthetic')])
        self.write_predictions([note(1), note(2)])
        r = evaluate(self.manifest, self.predictions)
        self.assertEqual(r['synthetic_case_count'], 1)
        self.assertEqual(r['real_slices']['clean_mono']['status'], 'SKIPPED')
        self.assertEqual(r['release_gate']['status'], 'BLOCKED')

    def test_missing_case_is_not_hidden_by_other_success(self):
        self.write_manifest([self.case, dict(self.case, id='second')])
        self.write_predictions([note(1), note(2)])
        self.assertEqual(evaluate(self.manifest, self.predictions)['real_slices']['clean_mono']['status'], 'BLOCKED')

    def test_all_real_slice_gates_and_separation_median(self):
        cases, predictions = [], []
        for slice_name in ('clean_mono', 'clean_chords', 'distortion', 'bends_slides', 'dual_guitar_panning'):
            cases.append(dict(self.case, id=slice_name, slice=slice_name))
            predictions.append({'id': slice_name, 'notes': [note(1), note(2)]})
        signal, interference = [1, -1, 1, -1] * 10, [1, 1, -1, -1] * 10
        for name, values in [('guitar', signal), ('mixture', [a+b for a,b in zip(signal, interference)]),
                             ('estimate-good', [a+.5*b for a,b in zip(signal, interference)]),
                             ('estimate-bad', [a+b for a,b in zip(signal, interference)])]:
            write_wav(self.root / (name+'.wav'), [values])
        def desc(name):
            path = self.root / (name+'.wav')
            return {'path': path.name, 'sha256': digest(path)}
        for index in range(3):
            cases.append(dict(self.case, id='source'+str(index), slice='separation', notes_reference=None,
                              guitar_reference=desc('guitar'), mixture=desc('mixture')))
            predictions.append({'id': 'source'+str(index), 'guitar_estimate': desc('estimate-good')})
        self.write_manifest(cases)
        self.predictions.write_text(json.dumps({'schema_version':1, 'engine':{'id':'metric-test-oracle','version':'1'}, 'cases':predictions}))
        first = evaluate(self.manifest, self.predictions)
        self.assertEqual(first['release_gate']['status'], 'PASS')
        self.assertAlmostEqual(first['real_separation_gate']['median_si_sdr_improvement']['value_db'], 10*math.log10(4))
        # Two failed outputs cannot be hidden by a single good source estimate.
        for prediction in predictions[-2:]:
            prediction['guitar_estimate'] = desc('estimate-bad')
        self.predictions.write_text(json.dumps({'schema_version':1, 'engine':{'id':'metric-test-oracle','version':'1'}, 'cases':predictions}))
        self.assertEqual(evaluate(self.manifest, self.predictions)['release_gate']['status'], 'FAIL')

    def test_input_fingerprint_is_required_for_real_input_case(self):
        input_file = self.root / 'input.wav'
        write_wav(input_file, [[.1, -.1]])
        self.write_manifest([dict(self.case, audio_input={'path': input_file.name, 'sha256': digest(input_file)})])
        self.write_predictions([note(1), note(2)])
        self.assertEqual(evaluate(self.manifest, self.predictions)['cases'][0]['notes']['status'], 'BLOCKED')

    def test_reference_outside_selected_audio_is_blocked(self):
        input_file = self.root / 'input.wav'
        write_wav(input_file, [[.1, -.1]], rate=8000)
        self.write_manifest([dict(self.case, audio_input={'path':input_file.name,'sha256':digest(input_file)})])
        r = evaluate(self.manifest)
        self.assertEqual(r['cases'][0]['notes']['status'], 'BLOCKED')
        self.assertIn('outside selected audio', r['cases'][0]['notes']['reason'])

    def test_invalid_json_numbers_and_unknown_prediction_ids_are_rejected(self):
        self.predictions.write_text('{"schema_version":1,"engine":{"id":"test","version":"1"},"cases":[{"id":"clean","notes":[{"onset":NaN,"midi":40}]}]}')
        with self.assertRaises(EvaluationError):
            evaluate(self.manifest, self.predictions)
        self.predictions.write_text(json.dumps({'schema_version':1,'engine':{'id':'test','version':'1'},'cases':[{'id':'not-in-dataset','notes':[]}]}))
        with self.assertRaises(EvaluationError):
            evaluate(self.manifest, self.predictions)

    def test_reference_path_traversal_is_blocked(self):
        self.write_manifest([dict(self.case, notes_reference={'path': '../outside.json', 'sha256': 'a' * 64})])
        self.assertEqual(evaluate(self.manifest)['cases'][0]['notes']['status'], 'BLOCKED')

    def test_cli_missing_slices_exit_two_in_required_mode(self):
        run = subprocess.run([sys.executable, str(ROOT / 'scripts/evaluate-transcription.py'), '--manifest', str(self.manifest), '--require-real-gates'], capture_output=True, text=True)
        self.assertEqual(run.returncode, 2)
        self.assertEqual(json.loads(run.stdout)['release_gate']['status'], 'BLOCKED')


class FixtureTests(unittest.TestCase):
    def test_fetch_without_explicit_download_does_not_create_destination(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'absent'
            result = acquire(ROOT / 'Tests/Fixtures/guitarset-acquisition.json', target)
            self.assertEqual(result['status'], 'SKIPPED')
            self.assertFalse(target.exists())

    def test_zip_traversal_symlink_and_crc_are_checked(self):
        for name in ('../user.wav', '/absolute.wav', 'folder\\user.wav'):
            with self.assertRaises(EvaluationError):
                safe_member(name)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'bad.zip'
            with zipfile.ZipFile(path, 'w') as out:
                info = zipfile.ZipInfo('link.wav')
                info.external_attr = 0o120777 << 16
                out.writestr(info, b'target')
            with zipfile.ZipFile(path) as archive, self.assertRaises(EvaluationError):
                selected_member(archive, 'link.wav')

    def test_publisher_checksum_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'archive'
            path.write_bytes(b'known')
            spec = {'size_bytes': 5, 'md5': hashlib.md5(b'known', usedforsecurity=False).hexdigest()}
            verify_archive(path, spec)
            with self.assertRaises(EvaluationError):
                verify_archive(path, dict(spec, sha256='f' * 64))
            path.write_bytes(b'other')
            with self.assertRaises(EvaluationError):
                verify_archive(path, spec)

    def test_jams_conversion_preserves_references_not_model_guesses(self):
        data = {'annotations': [{'namespace': 'note_midi', 'data': [{'time': .25, 'duration': .5, 'value': 40.02}]}]}
        notes = jams_notes(data)
        self.assertEqual(notes[0]['midi'], 40)
        self.assertEqual(notes[0]['onset'], .25)
        self.assertEqual(notes[0]['annotated_midi'], 40.02)
        with self.assertRaises(EvaluationError):
            jams_notes({'annotations': []})

    def test_mono_window_selection_cannot_relabel_a_chord(self):
        notes = [{'onset': .5, 'end': 1, 'midi': 40}, {'onset': .5, 'end': 1, 'midi': 44},
                 {'onset': 2, 'end': 3, 'midi': 47}, {'onset': 4, 'end': 4.5, 'midi': 50}]
        self.assertIsNone(choose_window(notes, 5, chord=False))
        self.assertEqual(choose_window(notes, 5, chord=True), (0, 5))


if __name__ == '__main__':
    unittest.main()
