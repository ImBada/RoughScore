#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/roughscore-native-mono.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -O -parse-as-library \
    "$repo_dir/Sources/RoughScoreCore/MonophonicTranscriber.swift" \
    "$repo_dir/scripts/evaluate-native-mono.swift" \
    -o "$build_dir/evaluate-native-mono"
"$build_dir/evaluate-native-mono" "$@"
