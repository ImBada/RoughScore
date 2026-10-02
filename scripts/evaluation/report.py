"""Manifest/prediction validation and slice-level release gates."""
import hashlib
import json
import math
import struct
from pathlib import Path
from .metrics import EvaluationError, WavReader, note_metrics, percentile, source_metrics, validate_notes

NOTE_SLICES = ('clean_mono', 'clean_chords', 'distortion', 'bends_slides', 'dual_guitar_panning')
GATES = {'clean_mono': {'qualified_precision': 0.90, 'qualified_reference_coverage': 0.75},
         'clean_chords': {'precision': 0.80, 'recall': 0.70}}


def load_json(path):
    def reject(value):
        raise EvaluationError(f'nonstandard JSON number: {value}')
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'), parse_constant=reject)
    except (OSError, json.JSONDecodeError) as error:
        raise EvaluationError(str(error)) from error


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while block := stream.read(1024 * 1024):
            h.update(block)
    return h.hexdigest()


def artifact(root, descriptor):
    if not isinstance(descriptor, dict) or not isinstance(descriptor.get('path'), str):
        raise EvaluationError('missing reference/prediction artifact descriptor')
    root = root.resolve()
    path = (root / descriptor['path']).resolve()
    if not path.is_relative_to(root):
        raise EvaluationError('artifact path escapes manifest directory')
    expected = descriptor.get('sha256')
    if not isinstance(expected, str) or len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
        raise EvaluationError('artifact requires lowercase SHA256')
    if not path.is_file():
        raise FileNotFoundError(f'artifact not acquired: {descriptor["path"]}')
    if digest(path) != expected:
        raise EvaluationError(f'artifact hash mismatch: {descriptor["path"]}')
    return path


def aggregate_notes(cases):
    rows = [c['notes']['metrics'] for c in cases if c['notes']['status'] == 'MEASURED']
    if not rows:
        return None
    keys = ('reference_count', 'prediction_count', 'true_positives', 'false_positives', 'false_negatives',
            'qualified_count', 'qualified_true_positives', 'onset_true_positives_ignoring_pitch')
    result = {key: sum(r[key] for r in rows) for key in keys}
    ref, predicted, tp, qualified, qtp = (result[k] for k in ('reference_count', 'prediction_count', 'true_positives', 'qualified_count', 'qualified_true_positives'))
    errors = [e for r in rows for e in r['matched_onset_errors_seconds']]
    result.update(precision=tp / predicted if predicted else 0.0,
                  recall=tp / ref if ref else None,
                  qualified_precision=qtp / qualified if qualified else None,
                  qualified_reference_coverage=qtp / ref if ref else None,
                  quality_labels_complete=all(r['quality_labels_complete'] for r in rows),
                  onset_recall_ignoring_pitch=result['onset_true_positives_ignoring_pitch'] / ref if ref else None,
                  onset_error_mean_absolute_seconds=math.fsum(map(abs, errors)) / len(errors) if errors else None,
                  onset_error_median_absolute_seconds=percentile(list(map(abs, errors)), .5),
                  onset_error_p95_absolute_seconds=percentile(list(map(abs, errors)), .95))
    return result


def gate_notes(name, cases):
    metrics = aggregate_notes(cases)
    if not cases:
        return {'status': 'SKIPPED', 'reason': 'reference slice not acquired', 'metrics': None}
    if any(c['notes']['status'] != 'MEASURED' for c in cases):
        return {'status': 'BLOCKED', 'reason': 'one or more references/predictions are missing or invalid', 'metrics': metrics}
    if metrics['reference_count'] == 0:
        return {'status': 'BLOCKED', 'reason': 'slice contains no reference notes', 'metrics': metrics}
    thresholds = GATES.get(name)
    if thresholds is None:
        return {'status': 'MEASURED', 'reason': 'no numerical threshold defined for this slice in issue #10', 'metrics': metrics}
    if name == 'clean_mono' and not metrics['quality_labels_complete']:
        return {'status': 'BLOCKED', 'reason': 'engine must explicitly label qualified suggestions', 'metrics': metrics, 'thresholds': thresholds}
    passed = all(metrics[key] is not None and metrics[key] >= bound for key, bound in thresholds.items())
    return {'status': 'PASS' if passed else 'FAIL', 'metrics': metrics, 'thresholds': thresholds}


def db_value(record):
    if record['limit'] == 'positive_infinity':
        return math.inf
    if record['limit'] == 'negative_infinity':
        return -math.inf
    return record['value_db']


def evaluate(manifest_path, predictions_path=None):
    manifest_path = Path(manifest_path)
    manifest = load_json(manifest_path)
    if not isinstance(manifest, dict) or manifest.get('schema_version') != 1 or not isinstance(manifest.get('cases'), list):
        raise EvaluationError('expected evaluation manifest schema_version 1 and cases array')
    predictions = load_json(predictions_path) if predictions_path else None
    predicted = {}
    if predictions is not None:
        if not isinstance(predictions, dict) or predictions.get('schema_version') != 1 or not isinstance(predictions.get('engine'), dict) or not isinstance(predictions.get('cases'), list):
            raise EvaluationError('expected predictions schema_version 1, engine metadata and cases array')
        if not predictions['engine'].get('id') or not predictions['engine'].get('version'):
            raise EvaluationError('prediction provenance needs engine id/version')
        for case in predictions['cases']:
            if not isinstance(case, dict) or not isinstance(case.get('id'), str) or case['id'] in predicted:
                raise EvaluationError('invalid/duplicate prediction case ID')
            predicted[case['id']] = case
    result = []
    seen = set()
    for case in manifest['cases']:
        if not isinstance(case, dict):
            raise EvaluationError('reference case must be an object')
        identity = case.get('id')
        if not isinstance(identity, str) or not identity or identity in seen:
            raise EvaluationError('invalid/duplicate reference case ID')
        seen.add(identity)
        if case.get('material') not in ('real', 'synthetic') or case.get('slice') not in (*NOTE_SLICES, 'separation'):
            raise EvaluationError('case requires explicit real/synthetic material and a known slice')
        if not case.get('license') or not case.get('source') or not case.get('reference_method'):
            raise EvaluationError('case needs license/source/reference_method provenance')
        row = {'id': identity, 'material': case['material'], 'slice': case['slice'], 'source': case['source'], 'license': case['license'],
               'notes': {'status': 'SKIPPED', 'reason': 'no note reference for this case'},
               'separation': {'status': 'SKIPPED', 'reason': 'no aligned guitar/mixture reference pair'}}
        prediction = predicted.get(identity)
        if case.get('notes_reference'):
            try:
                # Also check the selected input file's identity when provided.
                input_duration = None
                if case.get('audio_input'):
                    input_reader = WavReader(artifact(manifest_path.parent, case['audio_input']))
                    input_duration = input_reader.frames / input_reader.sample_rate
                    input_reader.close()
                    if prediction is not None and prediction.get('input_sha256') != case['audio_input']['sha256']:
                        raise EvaluationError('prediction input_sha256 does not identify the selected input')
                reference = load_json(artifact(manifest_path.parent, case['notes_reference']))
                if not isinstance(reference, dict) or reference.get('schema_version') != 1:
                    raise EvaluationError('unknown note reference schema')
                reference_notes = validate_notes(reference.get('notes'))
                if input_duration is not None and any(n['onset'] >= input_duration for n in reference_notes):
                    raise EvaluationError('reference note onset outside selected audio')
                if prediction is None or 'notes' not in prediction:
                    row['notes'] = {'status': 'SKIPPED', 'reason': 'engine predictions not supplied'}
                else:
                    prediction_notes = validate_notes(prediction['notes'])
                    if input_duration is not None and any(n['onset'] >= input_duration for n in prediction_notes):
                        raise EvaluationError('prediction onset outside selected audio')
                    row['notes'] = {'status': 'MEASURED', 'metrics': note_metrics(reference_notes, prediction_notes)}
            except FileNotFoundError as error:
                row['notes'] = {'status': 'SKIPPED', 'reason': str(error)}
            except (EvaluationError, OSError, struct.error) as error:
                row['notes'] = {'status': 'BLOCKED', 'reason': str(error)}
        if case.get('guitar_reference') and case.get('mixture'):
            try:
                guitar = artifact(manifest_path.parent, case['guitar_reference'])
                mixture = artifact(manifest_path.parent, case['mixture'])
                if prediction is None or 'guitar_estimate' not in prediction:
                    row['separation'] = {'status': 'SKIPPED', 'reason': 'separation engine output not supplied'}
                else:
                    estimate = artifact(Path(predictions_path).parent, prediction['guitar_estimate'])
                    row['separation'] = {'status': 'MEASURED', 'metrics': source_metrics(guitar, mixture, estimate)}
            except FileNotFoundError as error:
                row['separation'] = {'status': 'SKIPPED', 'reason': str(error)}
            except (EvaluationError, OSError, struct.error) as error:
                row['separation'] = {'status': 'BLOCKED', 'reason': str(error)}
        result.append(row)
    if set(predicted) - seen:
        raise EvaluationError('predictions contain unknown reference case IDs')
    real = [c for c in result if c['material'] == 'real']
    slices = {name: gate_notes(name, [c for c in real if c['slice'] == name]) for name in NOTE_SLICES}
    separation_cases = [c for c in real if c['slice'] == 'separation' or c['separation']['status'] != 'SKIPPED' or c.get('id') in {x['id'] for x in manifest['cases'] if x.get('guitar_reference')}]
    if not separation_cases:
        separation_gate = {'status': 'SKIPPED', 'reason': 'real aligned guitar-reference mixtures not acquired'}
    elif any(c['separation']['status'] != 'MEASURED' for c in separation_cases):
        separation_gate = {'status': 'BLOCKED', 'reason': 'one or more separation references/outputs unavailable'}
    else:
        improvements = [db_value(c['separation']['metrics']['si_sdr_improvement']) for c in separation_cases]
        if any(v is None for v in improvements):
            separation_gate = {'status': 'BLOCKED', 'reason': 'undefined SI-SDR improvement'}
        else:
            ordered = sorted(improvements)
            middle = len(ordered) // 2
            median = ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2
            if math.isnan(median):
                separation_gate = {'status': 'BLOCKED', 'reason': 'opposite infinite improvements have undefined median'}
            else:
                from .metrics import json_db
                separation_gate = {'status': 'PASS' if median >= 3 else 'FAIL', 'median_si_sdr_improvement': json_db(median), 'threshold_db': 3.0}
    statuses = [g['status'] for g in slices.values()] + [separation_gate['status']]
    overall = 'FAIL' if 'FAIL' in statuses else ('BLOCKED' if any(s in ('SKIPPED', 'BLOCKED') for s in statuses) else 'PASS')
    return {'schema_version': 1, 'manifest_name': manifest.get('name'), 'manifest_sha256': digest(manifest_path),
            'predictions_sha256': digest(predictions_path) if predictions_path else None,
            'engine': predictions.get('engine') if predictions else None, 'cases': result,
            'real_slices': slices, 'real_separation_gate': separation_gate,
            'release_gate': {'status': overall, 'scope': 'issue #10 fixed numerical gates and required real slice coverage; not human/listening validation'},
            'synthetic_case_count': len(result) - len(real),
            'policy': {'onset_tolerance_seconds': .05, 'note_gates': GATES, 'separation_median_improvement_db': 3,
                       'confidence': 'qualified is an explicit engine rule, never a calibrated probability; mono gates use qualified precision and qualified reference coverage; all-suggestion recall is also reported',
                       'bleed': 'target-orthogonal known-interference projection/target projection energy in dB; lower is better, no invented bleed threshold'}}
