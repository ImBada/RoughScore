#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || ( "$2" != enabled && "$2" != disabled ) ]]; then
  printf '%s\n' 'usage: run.sh NEW_OUTPUT_DIRECTORY enabled|disabled' >&2
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output_root="$1"
expected_analysis="$2"
if [[ -e "$output_root" ]]; then
  printf '%s\n' 'Output directory must not exist; refusing to overwrite data.' >&2
  exit 2
fi
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"
cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="$output_root/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export PYTHONDONTWRITEBYTECODE=1
unset ROUGH_SCORE_AUDIO_FIXTURE

{
  sw_vers
  uname -m
  xcodebuild -version
  swift --version
  xcrun --sdk macosx --show-sdk-version
} 2>&1 | tee "$output_root/environment.log"
swift scripts/ci/sdk_capability.swift "$expected_analysis" 2>&1 | tee "$output_root/sdk-capability.log"
python3 scripts/ci/generate_audio.py "$output_root/fixture"
/usr/bin/afconvert "$output_root/fixture/stereo-tones.wav" "$output_root/fixture/stereo-tones.m4a" -f m4af -d aac -b 128000
swift scripts/ci/verify_audio.swift "$output_root/fixture/stereo-tones.m4a" > "$output_root/compressed-smoke.json"

# Always use our generated file; inherited human fixture paths are never read.
# This executes the existing optional integration assertions instead of their
# silent early-return path. The log verifier rejects absent/empty coverage.
env ROUGH_SCORE_AUDIO_FIXTURE="$output_root/fixture/stereo-tones.m4a" \
  swift test --disable-sandbox --scratch-path "$output_root/build" --cache-path "$output_root/spm-cache" \
  2>&1 | tee "$output_root/tests.log"
python3 scripts/ci/verify_test_log.py "$output_root/tests.log" > "$output_root/test-coverage.json"
swift build --disable-sandbox --scratch-path "$output_root/build" --cache-path "$output_root/spm-cache" \
  -c release -debug-info-format none 2>&1 | tee "$output_root/release.log"
bin_path="$(swift build --disable-sandbox --scratch-path "$output_root/build" --cache-path "$output_root/spm-cache" -c release --show-bin-path)"
test -x "$bin_path/RoughScore"

{
  printf '%s\n' '## RoughScore CI foundation' ''
  printf '%s\n' "MusicUnderstanding SDK compile path: **$expected_analysis**." ''
  printf '%s\n' 'Generated AAC decode, stereo activity, app integration assertions and release executable build passed.' ''
  printf '%s\n' '```json'
  cat "$output_root/test-coverage.json"
  printf '%s\n' '```' ''
  printf '%s\n' 'Real guitar/model quality evaluation: **SKIPPED** (no licensed/labeled dataset).' ''
  printf '%s\n' 'Finder routing, final app bundle/archive metadata and signing/notarization are outside this CI-foundation subset of #18.'
} > "$output_root/summary.md"
