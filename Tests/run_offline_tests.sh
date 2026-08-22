#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ytmu-offline-tests"
mkdir -p "$build_root"

xcrun clang \
  -std=c11 \
  -Wall -Wextra -Werror \
  -x c \
  "$repo_root/Source/Offline/YTMUOfflinePlaybackPolicy.m" \
  "$repo_root/Tests/YTMUOfflinePlaybackPolicyTests.c" \
  -I"$repo_root/Source/Offline" \
  -o "$build_root/offline-policy-tests"

"$build_root/offline-policy-tests"

xcrun clang \
  -fobjc-arc \
  -Wall -Wextra -Werror \
  -framework Foundation \
  "$repo_root/Source/Offline/YTMUOfflineModels.m" \
  "$repo_root/Source/Offline/YTMUOfflineLibrary.m" \
  "$repo_root/Tests/YTMUOfflineLibraryTests.m" \
  -I"$repo_root/Source/Offline" \
  -o "$build_root/offline-library-tests"

"$build_root/offline-library-tests"
