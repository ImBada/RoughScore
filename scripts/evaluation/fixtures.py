"""Explicit, bounded GuitarSet acquisition and reference conversion."""
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import struct
import tempfile
import time
import urllib.request
import zipfile
from .metrics import EvaluationError, WavReader, finite
from .report import digest


def download(artifact, directory):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / artifact['name']
    if Path(artifact['name']).name != artifact['name']:
        raise EvaluationError('archive name must be a basename')
    if path.exists():
        verify_archive(path, artifact)
        return path
    url = artifact['url']
    if not url.startswith('https://zenodo.org/'):
        raise EvaluationError('only pinned official Zenodo downloads are allowed')
    request = urllib.request.Request(url, headers={'User-Agent': 'RoughScore-evaluation-fixtures/1'})
    temp_path = None
    try:
        with urllib.request.urlopen(request, timeout=30) as response, tempfile.NamedTemporaryFile(dir=directory, suffix='.part', delete=False) as out:
            temp_path = Path(out.name)
            count, last_progress = 0, time.monotonic()
            while block := response.read(1024 * 1024):
                count += len(block)
                if count > artifact['size_bytes']:
                    raise EvaluationError('download exceeds pinned archive size')
                out.write(block)
                if time.monotonic() - last_progress > 10:
                    print(f'{artifact["name"]}: {count}/{artifact["size_bytes"]} bytes', flush=True)
                    last_progress = time.monotonic()
        verify_archive(temp_path, artifact)
        if path.exists():
            raise EvaluationError('archive appeared during download; refusing overwrite')
        temp_path.rename(path)
        print(f'{artifact["name"]}: verified {count} bytes', flush=True)
        return path
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()


def verify_archive(path, artifact):
    if path.stat().st_size != artifact['size_bytes']:
        raise EvaluationError('archive size mismatch')
    h = hashlib.md5(usedforsecurity=False)  # publisher checksum, not a security assertion
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            h.update(block)
    if h.hexdigest() != artifact['md5']:
        raise EvaluationError('publisher archive checksum mismatch')
    if artifact.get('sha256') and digest(path) != artifact['sha256']:
        raise EvaluationError('pinned archive SHA256 mismatch')


def safe_member(name):
    part = PurePosixPath(name)
    if part.is_absolute() or '..' in part.parts or '\\' in name:
        raise EvaluationError('unsafe ZIP member')
    return part


def selected_member(archive, name):
    safe_member(name)
    info = archive.getinfo(name)
    if info.file_size > 50_000_000 or (info.external_attr >> 16) & 0o170000 == 0o120000:
        raise EvaluationError('oversized or symlink ZIP member')
    # ZipFile.read verifies CRC; extraction never trusts an archive path on disk.
    return archive.read(info)


def jams_notes(jams):
    notes = []
    for annotation in jams.get('annotations', []):
        if annotation.get('namespace') != 'note_midi':
            continue
        for observation in annotation.get('data', []):
            start = finite(observation.get('time'), 'reference onset')
            duration = finite(observation.get('duration'), 'reference duration')
            pitch = finite(observation.get('value'), 'reference MIDI')
            if start < 0 or duration <= 0 or not 0 <= pitch <= 127:
                raise EvaluationError('invalid GuitarSet note annotation')
            notes.append({'onset': float(start), 'end': float(start + duration), 'midi': int(math.floor(pitch + .5)),
                          'annotated_midi': float(pitch), 'lane': 'left'})
    if not notes:
        raise EvaluationError('no note_midi annotations; cannot invent references')
    # Preserve all annotations, including coincident pitches from different strings.
    return sorted(notes, key=lambda n: (n['onset'], n['midi'], n['end']))


def choose_window(notes, duration, chord, length=5.0):
    """Choose a reproducible window using reference polyphony only, not predictions."""
    for step in range(max(0, int(math.floor(duration - length)) + 1)):
        start, end = float(step), step + length
        active = [n for n in notes if n['onset'] < end and n['end'] > start]
        selected = [n for n in active if start + .1 <= n['onset'] < end - .1]
        if len(selected) < 3 or any(n['onset'] < start for n in active):
            continue  # avoid a sustained boundary note with no onset in the crop
        changes = sorted([(max(start, n['onset']), 1) for n in active] + [(min(end, n['end']), -1) for n in active])
        count, maximum = 0, 0
        for _, delta in changes:
            count += delta
            maximum = max(maximum, count)
        if (maximum >= 2) == chord:
            return start, end
    return None


def crop_wav(source, destination, start, end):
    reader = WavReader(source)
    try:
        first, last = round(start * reader.sample_rate), round(end * reader.sample_rate)
        if first < 0 or last > reader.frames or first >= last:
            raise EvaluationError('crop outside source')
        reader.stream.seek(reader.data_start + first * reader.block_align)
        count = (last - first) * reader.block_align
        fmt = struct.pack('<HHIIHH', reader.format, reader.channels, reader.sample_rate,
                          reader.sample_rate * reader.block_align, reader.block_align, reader.bits)
        header = b'RIFF' + struct.pack('<I', 36 + count) + b'WAVEfmt ' + struct.pack('<I', 16) + fmt + b'data' + struct.pack('<I', count)
        with destination.open('xb') as out:
            out.write(header)
            remaining = count
            while remaining:
                block = reader.stream.read(min(1024 * 1024, remaining))
                if not block:
                    raise EvaluationError('truncated crop source')
                out.write(block)
                remaining -= len(block)
        return first / reader.sample_rate, last / reader.sample_rate
    finally:
        reader.close()


def acquire(spec_path, destination, allow_download=False):
    spec = json.loads(Path(spec_path).read_text())
    if not isinstance(spec, dict) or spec.get('schema_version') != 1 or spec.get('dataset') != 'GuitarSet' or spec.get('license') != 'CC-BY-4.0':
        raise EvaluationError('unsupported acquisition specification')
    if not allow_download:
        return {'status': 'SKIPPED', 'reason': 'explicit --download required', 'dataset': spec['dataset'], 'source': spec['source']}
    if sum(a['size_bytes'] for a in spec['archives']) > 800_000_000:
        raise EvaluationError('acquisition exceeds bounded 800 MB download budget')
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    marker = destination / '.roughscore-evaluation-owned'
    if any(destination.iterdir()) and not marker.is_file():
        raise EvaluationError('destination is not empty/owned; refusing to write into unrelated files')
    marker.touch(exist_ok=True)
    receipt_path = destination / 'acquisition-receipt.json'
    manifest_path = destination / 'evaluation-manifest.json'
    if manifest_path.exists():
        raise EvaluationError('fixture manifest already exists; use a fresh destination to regenerate')
    paths = {a['name']: download(a, destination / 'archives') for a in spec['archives']}
    receipt = {'schema_version': 1, 'dataset': spec['dataset'], 'version': spec['version'], 'license': spec['license'],
               'source': spec['source'], 'attribution': spec['attribution'],
               'archives': [dict(a, sha256=digest(paths[a['name']]), publisher_checksum_verified=True) for a in spec['archives']],
               'members': [], 'excluded_tracks': spec['excluded_tracks']}
    cases, unavailable = [], []
    with zipfile.ZipFile(paths['annotation.zip']) as annotations, zipfile.ZipFile(paths['audio_mono-mic.zip']) as audio:
        annotation_names = {Path(n).stem: n for n in annotations.namelist() if n.endswith('.jams') and not n.startswith('__MACOSX/')}
        audio_names = {Path(n).stem.removesuffix('_mic'): n for n in audio.namelist() if n.endswith('.wav') and not n.startswith('__MACOSX/')}
        for chord, slice_name, suffix in [(False, 'clean_mono', '_solo'), (True, 'clean_chords', '_comp')]:
            acquired = False
            for track in sorted(annotation_names):
                if not track.startswith('00_') or not track.endswith(suffix) or track in spec['excluded_tracks'] or track not in audio_names:
                    continue
                raw_jams = selected_member(annotations, annotation_names[track])
                notes = jams_notes(json.loads(raw_jams))
                raw_audio = selected_member(audio, audio_names[track])
                with tempfile.TemporaryDirectory(dir=destination) as temporary:
                    source = Path(temporary) / 'source.wav'
                    source.write_bytes(raw_audio)
                    reader = WavReader(source)
                    duration = reader.frames / reader.sample_rate
                    reader.close()
                    window = choose_window(notes, duration, chord)
                    if window is None:
                        continue
                    identity = f'guitarset-{track}-{slice_name}'
                    case_dir = destination / 'cases' / identity
                    case_dir.mkdir(parents=True, exist_ok=False)
                    start, end = crop_wav(source, case_dir / 'input.wav', *window)
                selected = [dict(n, onset=n['onset'] - start, end=min(n['end'], end) - start) for n in notes if start <= n['onset'] < end]
                reference_path = case_dir / 'notes.json'
                reference_path.write_text(json.dumps({'schema_version': 1, 'notes': selected}, indent=2) + '\n')
                (case_dir / 'source.jams').write_bytes(raw_jams)
                def desc(path):
                    return {'path': str(path.relative_to(destination)), 'sha256': digest(path)}
                cases.append({'id': identity, 'slice': slice_name, 'material': 'real', 'source': spec['source'], 'license': spec['license'],
                              'reference_method': 'GuitarSet v1.1.0 note_midi JAMS annotations; MIDI rounded to nearest semitone; onset/end preserved; reference-only 5 s polyphony selection, first valid performer-00 track',
                              'audio_origin_in_source_seconds': start, 'audio_input': desc(case_dir / 'input.wav'),
                              'notes_reference': desc(reference_path), 'source_annotations': desc(case_dir / 'source.jams'),
                              'limitations': 'Acoustic microphone recording only; one deterministic window is smoke/reference coverage, not a representative frozen benchmark or unseen-data claim.'})
                receipt['members'].append({'track': track, 'annotation_member': annotation_names[track], 'annotation_sha256': hashlib.sha256(raw_jams).hexdigest(),
                                           'audio_member': audio_names[track], 'audio_member_sha256': hashlib.sha256(raw_audio).hexdigest(),
                                           'derived_input_sha256': digest(case_dir / 'input.wav'), 'reference_sha256': digest(reference_path), 'crop_seconds': [start, end]})
                acquired = True
                break
            if not acquired:
                unavailable.append({'slice': slice_name, 'status': 'BLOCKED', 'reason': 'no valid performer-00 reference window found; do not relabel polyphonic material as mono'})
    manifest = {'schema_version': 1, 'name': 'GuitarSet 1.1.0 acoustic reference smoke windows', 'cases': cases,
                'acquisition_receipt': 'acquisition-receipt.json', 'unavailable': unavailable,
                'dataset': spec, 'benchmark_status': 'SMOKE_REFERENCE_ONLY; not representative quality-release evidence'}
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    return {'status': 'ACQUIRED' if cases else 'BLOCKED', 'manifest': str(manifest_path), 'receipt': str(receipt_path),
            'case_count': len(cases), 'unavailable': unavailable,
            'still_missing': ['distortion', 'bends_slides', 'dual_guitar_panning', 'aligned real guitar-reference mixture/stems', 'engine predictions']}
