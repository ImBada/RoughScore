"""Dependency-free, reference-based metrics; no transcription/separation engine."""
from collections import deque
from dataclasses import dataclass
import math
import struct
from pathlib import Path


class EvaluationError(ValueError):
    pass


def finite(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise EvaluationError(f'{name} must be a finite number')
    return value


def validate_notes(notes):
    if not isinstance(notes, list):
        raise EvaluationError('notes must be a list')
    result = []
    for note in notes:
        if not isinstance(note, dict):
            raise EvaluationError('note must be an object')
        onset = finite(note.get('onset'), 'onset')
        if onset < 0:
            raise EvaluationError('negative onset')
        midi = note.get('midi')
        if midi is not None and (type(midi) is not int or not 0 <= midi <= 127):
            raise EvaluationError('midi must be an integer 0..127 or null')
        lane = note.get('lane', 'left')
        if lane not in ('left', 'right'):
            raise EvaluationError('lane must be left or right')
        if 'qualified' in note and type(note['qualified']) is not bool:
            raise EvaluationError('qualified must be a boolean, not a probability')
        result.append(dict(note, onset=float(onset), midi=midi, lane=lane))
    return result


@dataclass
class Edge:
    to: int
    reverse: int
    capacity: int
    cost: float


def match_notes(reference, prediction, tolerance=0.05, pitch=True):
    """Maximum one-to-one cardinality, then minimum absolute onset error.

    Successive shortest augmenting paths include reverse edges so an earlier
    ambiguous match can be reassigned. Independent of prediction array order.
    """
    finite(tolerance, 'tolerance')
    if tolerance < 0:
        raise EvaluationError('negative tolerance')
    truth = sorted(enumerate(validate_notes(reference)), key=lambda n: (n[1]['onset'], n[1]['lane'], n[1]['midi'] or -1, n[0]))
    guessed = sorted(enumerate(validate_notes(prediction)), key=lambda n: (n[1]['onset'], n[1]['lane'], n[1]['midi'] or -1, n[0]))
    n, m = len(truth), len(guessed)
    source, sink = n + m, n + m + 1
    graph = [[] for _ in range(sink + 1)]

    def edge(a, b, cost):
        forward = Edge(b, len(graph[b]), 1, cost)
        graph[a].append(forward)
        graph[b].append(Edge(a, len(graph[a]) - 1, 0, -cost))
        return forward

    for i in range(n):
        edge(source, i, 0)
    for j in range(m):
        edge(n + j, sink, 0)
    candidates = []
    for i, (_, actual) in enumerate(truth):
        for j, (_, estimated) in enumerate(guessed):
            error = abs(actual['onset'] - estimated['onset'])
            if actual['lane'] != estimated['lane'] or error > tolerance + 1e-12:
                continue
            if pitch and (actual['midi'] is None or actual['midi'] != estimated['midi']):
                continue
            candidates.append((i, j, edge(i, n + j, error)))
    while True:
        distances = [math.inf] * len(graph)
        previous = [None] * len(graph)
        distances[source] = 0
        queue, queued = deque([source]), {source}
        while queue:
            a = queue.popleft()
            queued.remove(a)
            for index, e in enumerate(graph[a]):
                distance = distances[a] + e.cost
                if e.capacity and distance < distances[e.to] - 1e-12:
                    distances[e.to], previous[e.to] = distance, (a, index)
                    if e.to not in queued:
                        queue.append(e.to)
                        queued.add(e.to)
        if previous[sink] is None:
            break
        b = sink
        while b != source:
            a, index = previous[b]
            e = graph[a][index]
            e.capacity -= 1
            graph[b][e.reverse].capacity += 1
            b = a
    return sorted((truth[i][0], guessed[j][0]) for i, j, e in candidates if e.capacity == 0)


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    at = (len(ordered) - 1) * fraction
    lower = int(at)
    return ordered[lower] + (ordered[min(lower + 1, len(ordered) - 1)] - ordered[lower]) * (at - lower)


def note_metrics(reference, prediction, tolerance=0.05):
    reference, prediction = validate_notes(reference), validate_notes(prediction)
    if any(n['midi'] is None for n in reference):
        raise EvaluationError('pitched reference notes require MIDI ground truth')
    matched = match_notes(reference, prediction, tolerance)
    errors = [prediction[j]['onset'] - reference[i]['onset'] for i, j in matched]
    qualified = [n for n in prediction if n.get('qualified') is True]
    qualified_matches = match_notes(reference, qualified, tolerance)
    onset_matches = match_notes(reference, prediction, tolerance, pitch=False)
    tp, qtp = len(matched), len(qualified_matches)
    return {
        'reference_count': len(reference), 'prediction_count': len(prediction),
        'true_positives': tp, 'false_positives': len(prediction) - tp, 'false_negatives': len(reference) - tp,
        'precision': tp / len(prediction) if prediction else 0.0,
        'recall': tp / len(reference) if reference else None,
        'qualified_count': len(qualified), 'qualified_true_positives': qtp,
        'qualified_precision': qtp / len(qualified) if qualified else None,
        'qualified_reference_coverage': qtp / len(reference) if reference else None,
        'quality_labels_complete': all('qualified' in n for n in prediction),
        'onset_true_positives_ignoring_pitch': len(onset_matches),
        'onset_recall_ignoring_pitch': len(onset_matches) / len(reference) if reference else None,
        'matched_onset_errors_seconds': errors,
        'onset_error_mean_signed_seconds': math.fsum(errors) / len(errors) if errors else None,
        'onset_error_mean_absolute_seconds': math.fsum(map(abs, errors)) / len(errors) if errors else None,
        'onset_error_median_absolute_seconds': percentile(list(map(abs, errors)), 0.5),
        'onset_error_p95_absolute_seconds': percentile(list(map(abs, errors)), 0.95),
        'matching': 'maximum-cardinality/minimum-total-onset-error, exact MIDI and lane, one-to-one',
    }


class WavReader:
    """Read bounded RIFF WAV chunks (PCM 8/16/24/32, float 32/64).

    No resampling, lag search, mono downmix or gain fitting across channels.
    CAF/compressed media/RF64 must be exported to aligned WAV explicitly.
    """
    def __init__(self, path):
        self.stream = Path(path).open('rb')
        try:
            header = self.stream.read(12)
            if len(header) != 12 or header[:4] != b'RIFF' or header[8:] != b'WAVE':
                raise EvaluationError('expected RIFF WAV')
            declared_end = struct.unpack('<I', header[4:8])[0] + 8
            file_end = self.stream.seek(0, 2)
            if declared_end > file_end:
                raise EvaluationError('truncated RIFF')
            self.stream.seek(12)
            fmt, data = None, None
            while self.stream.tell() + 8 <= declared_end:
                chunk = self.stream.read(8)
                kind, size = chunk[:4], struct.unpack('<I', chunk[4:])[0]
                begin = self.stream.tell()
                if begin + size > declared_end:
                    raise EvaluationError('truncated WAV chunk')
                if kind == b'fmt ':
                    if size < 16 or size > 1024:
                        raise EvaluationError('invalid WAV format chunk')
                    fmt = self.stream.read(size)
                elif kind == b'data':
                    if data is not None:
                        raise EvaluationError('multiple WAV data chunks are unsupported')
                    data = (begin, size)
                self.stream.seek(begin + size + (size & 1))
            if fmt is None or data is None:
                raise EvaluationError('missing WAV format/data')
            code, self.channels, self.sample_rate, byte_rate, self.block_align, self.bits = struct.unpack('<HHIIHH', fmt[:16])
            if code == 0xFFFE:
                if len(fmt) < 40 or fmt[26:40] != bytes.fromhex('000000001000800000aa00389b71'):
                    raise EvaluationError('unsupported extensible WAV subformat')
                code = struct.unpack('<H', fmt[24:26])[0]
            self.format = code
            if not 1 <= self.channels <= 2 or self.sample_rate <= 0:
                raise EvaluationError('expected mono/stereo WAV with positive sample rate')
            if (code == 1 and self.bits not in (8, 16, 24, 32)) or (code == 3 and self.bits not in (32, 64)) or code not in (1, 3):
                raise EvaluationError('unsupported WAV sample format')
            if self.block_align != self.channels * self.bits // 8 or byte_rate != self.sample_rate * self.block_align:
                raise EvaluationError('inconsistent WAV format')
            self.data_start, self.data_size = data
            if self.data_size % self.block_align:
                raise EvaluationError('partial audio frame')
            self.frames = self.data_size // self.block_align
            if not self.frames:
                raise EvaluationError('empty WAV')
            self.stream.seek(self.data_start)
            self.remaining = self.frames
        except Exception:
            self.stream.close()
            raise

    def close(self):
        self.stream.close()

    def read(self, frames=16384):
        count = min(frames, self.remaining)
        if not count:
            return []
        data = self.stream.read(count * self.block_align)
        if len(data) != count * self.block_align:
            raise EvaluationError('truncated audio data')
        self.remaining -= count
        if self.format == 3:
            code = 'f' if self.bits == 32 else 'd'
            values = [item[0] for item in struct.iter_unpack('<' + code, data)]
        elif self.bits == 8:
            values = [(v - 128) / 128 for v in data]
        elif self.bits == 24:
            values = [int.from_bytes(data[i:i + 3], 'little', signed=True) / 8388608 for i in range(0, len(data), 3)]
        else:
            code = 'h' if self.bits == 16 else 'i'
            scale = 2 ** (self.bits - 1)
            values = [item[0] / scale for item in struct.iter_unpack('<' + code, data)]
        if not all(math.isfinite(v) for v in values):
            raise EvaluationError('nonfinite audio samples')
        return values


def db_ratio(numerator, denominator):
    if numerator <= 0 and denominator <= 0:
        return None
    if numerator <= 0:
        return -math.inf
    if denominator <= 0:
        return math.inf
    return 10 * math.log10(numerator / denominator)


def json_db(value):
    if value is None:
        return {'value_db': None, 'limit': 'undefined'}
    if math.isinf(value):
        return {'value_db': None, 'limit': 'positive_infinity' if value > 0 else 'negative_infinity'}
    return {'value_db': value, 'limit': None}


def source_from_moments(n, sums, products):
    # Per-channel DC removal, then a shared projection gain across both channels.
    ss = math.fsum(p[0] - s[0] * s[0] / n for s, p in zip(sums, products))
    ee = math.fsum(p[1] - s[1] * s[1] / n for s, p in zip(sums, products))
    mm = math.fsum(p[2] - s[2] * s[2] / n for s, p in zip(sums, products))
    se = math.fsum(p[3] - s[0] * s[1] / n for s, p in zip(sums, products))
    sm = math.fsum(p[4] - s[0] * s[2] / n for s, p in zip(sums, products))
    em = math.fsum(p[5] - s[1] * s[2] / n for s, p in zip(sums, products))
    if ss <= 1e-20 or ee <= 1e-20:
        raise EvaluationError('silent/DC-only reference or estimate has undefined SI-SDR')
    target_e, target_m = se * se / ss, sm * sm / ss
    if target_e <= 1e-20:
        estimated = -math.inf
    else:
        residual_e = max(0, ee - target_e)
        if residual_e < ee * 1e-12:
            residual_e = 0
        estimated = db_ratio(target_e, residual_e)
    residual_m = max(0, mm - target_m)
    if residual_m < mm * 1e-12:
        residual_m = 0
    if target_m <= 1e-20:
        raise EvaluationError('mixture target projection is zero; improvement is not a finite reference baseline')
    baseline = db_ratio(target_m, residual_m)
    if baseline is None or baseline == math.inf:
        raise EvaluationError('mixture has no measurable interference; improvement is undefined')
    improvement = estimated - baseline if not (estimated == -math.inf and baseline == -math.inf) else None
    # Residualize known interferer mixture-reference against target. Its span is
    # the same as residualizing mixture: i_perp = mixture - (sm/ss)*reference.
    interference_energy = residual_m
    leakage_dot = em - sm * se / ss
    leaked_energy = leakage_dot * leakage_dot / interference_energy if interference_energy > 1e-20 else 0
    bleed = db_ratio(leaked_energy, target_e)
    return {'si_sdr': json_db(estimated), 'mixture_si_sdr': json_db(baseline),
            'si_sdr_improvement': json_db(improvement), 'bleed_to_target': json_db(bleed)}


def source_metrics(reference_path, mixture_path, estimate_path):
    readers = []
    try:
        readers = [WavReader(reference_path)]
        readers.append(WavReader(mixture_path))
        readers.append(WavReader(estimate_path))
        ref = readers[0]
        if any((r.sample_rate, r.channels, r.frames) != (ref.sample_rate, ref.channels, ref.frames) for r in readers[1:]):
            raise EvaluationError('reference/mixture/estimate format or frame count mismatch; explicit alignment required')
        sums = [[0.0] * 3 for _ in range(ref.channels)]
        products = [[0.0] * 6 for _ in range(ref.channels)]
        while True:
            blocks = [r.read() for r in readers]
            if not blocks[0]:
                break
            for channel in range(ref.channels):
                vectors = [b[channel::ref.channels] for b in blocks]
                s, e, m = vectors[0], vectors[2], vectors[1]
                for index, vector in enumerate((s, e, m)):
                    sums[channel][index] = math.fsum((sums[channel][index], math.fsum(vector)))
                terms = ((s, s), (e, e), (m, m), (s, e), (s, m), (e, m))
                for index, (a, b) in enumerate(terms):
                    products[channel][index] = math.fsum((products[channel][index], math.fsum(x * y for x, y in zip(a, b))))
        metrics = source_from_moments(ref.frames, sums, products)
        channels = []
        for s, p in zip(sums, products):
            try:
                channels.append(dict(status='MEASURED', **source_from_moments(ref.frames, [s], [p])))
            except EvaluationError as error:
                channels.append({'status': 'BLOCKED', 'reason': str(error)})
        return dict(metrics, sample_rate=ref.sample_rate, frames=ref.frames, channels=channels,
                    definition='channel-DC-removed, shared stereo gain; bleed is projection onto known target-orthogonal mixture interference, lower is better')
    finally:
        for r in readers:
            r.close()
