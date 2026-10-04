#!/bin/bash
set -euo pipefail
# Generated media only; explicit new report directory, no user-media environment input.
if [[ $# -ne 1 || -e "$1" ]]; then
  printf '%s\n' 'usage: profile-prepared-cache.sh NEW_REPORT_DIRECTORY' >&2
  exit 2
fi
mkdir -p "$1"
report_root="$(cd "$1" && pwd)"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
swift test -c release --disable-sandbox --filter OwnedArtifactCacheTests > "$report_root/build-and-core-tests.log" 2>&1
for duration in 180 3600; do
  for channels in 1 2; do
    env ROUGH_SCORE_CACHE_PROFILE_SECONDS="$duration" ROUGH_SCORE_CACHE_PROFILE_CHANNELS="$channels" \
      ROUGH_SCORE_CACHE_PROFILE_OUTPUT="$report_root/${duration}s-${channels}ch.json" \
      /usr/bin/time -l swift test -c release --disable-sandbox --skip-build --filter generatedColdWarmProfile \
      > "$report_root/${duration}s-${channels}ch.log" 2>&1
  done
done
