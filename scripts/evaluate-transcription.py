#!/usr/bin/env python3
"""Evaluate exported predictions; never runs an inference model."""
import argparse
import json
import sys
from pathlib import Path
from evaluation.metrics import EvaluationError
from evaluation.report import evaluate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[1] / 'Tests/Fixtures/evaluation-manifest.json')
    parser.add_argument('--predictions', type=Path, help='Exported engine notes/stems; absent means SKIPPED, not an empty prediction')
    parser.add_argument('--output', type=Path, help='JSON report (stdout if absent)')
    parser.add_argument('--require-real-gates', action='store_true', help='Exit 2 unless every required real slice/gate is satisfied')
    args = parser.parse_args()
    try:
        report = evaluate(args.manifest, args.predictions)
    except (EvaluationError, OSError) as error:
        report = {'schema_version': 1, 'release_gate': {'status': 'BLOCKED'}, 'error': str(error)}
        exit_code = 2
    else:
        exit_code = 2 if args.require_real_gates and report['release_gate']['status'] != 'PASS' else 0
    text = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n'
    if args.output:
        if args.output.resolve() in (args.manifest.resolve(), args.predictions.resolve() if args.predictions else args.manifest.resolve()):
            parser.error('report output must not overwrite evaluation inputs')
        args.output.write_text(text, encoding='utf-8')
    else:
        sys.stdout.write(text)
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
