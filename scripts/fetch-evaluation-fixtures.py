#!/usr/bin/env python3
"""Explicitly fetch pinned, licensed GuitarSet references (never model weights)."""
import argparse
import json
from pathlib import Path
import sys
import zipfile
from evaluation.fixtures import acquire
from evaluation.metrics import EvaluationError


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec', type=Path, default=Path(__file__).resolve().parents[1] / 'Tests/Fixtures/guitarset-acquisition.json')
    parser.add_argument('--destination', type=Path, required=True, help='Fresh owned/empty directory; large archives stay outside Git')
    parser.add_argument('--download', action='store_true', help='Explicitly authorize up to 800 MB of official audio/annotation downloads')
    args = parser.parse_args()
    try:
        result = acquire(args.spec, args.destination, args.download)
    except (EvaluationError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        result = {'status': 'BLOCKED', 'reason': str(error)}
    print(json.dumps(result, indent=2, allow_nan=False), flush=True)
    return 2 if result['status'] == 'BLOCKED' else 0


if __name__ == '__main__':
    sys.exit(main())
