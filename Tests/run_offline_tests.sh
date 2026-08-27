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
  -std=c11 \
  -Wall -Wextra -Werror \
  -x c \
  "$repo_root/Source/Offline/YTMUOfflinePlayerVisualPolicy.m" \
  "$repo_root/Tests/YTMUOfflinePlayerVisualPolicyTests.c" \
  -I"$repo_root/Source/Offline" \
  -o "$build_root/offline-player-visual-policy-tests"

"$build_root/offline-player-visual-policy-tests"

xcrun clang \
  -std=c11 \
  -Wall -Wextra -Werror \
  -x c \
  "$repo_root/Source/Offline/YTMUMiniPlayerSwipePolicy.m" \
  "$repo_root/Tests/YTMUMiniPlayerSwipePolicyTests.c" \
  -I"$repo_root/Source/Offline" \
  -o "$build_root/mini-player-swipe-policy-tests"

"$build_root/mini-player-swipe-policy-tests"

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

xcrun clang \
  -fobjc-arc \
  -Wall -Wextra -Werror \
  -framework Foundation \
  "$repo_root/Source/Offline/YTMUPlaybackCoordinatorPolicy.m" \
  "$repo_root/Source/Offline/YTMUPlaybackCoordinator.m" \
  "$repo_root/Tests/YTMUPlaybackCoordinatorTests.m" \
  -I"$repo_root/Source/Offline" \
  -o "$build_root/playback-coordinator-tests"

"$build_root/playback-coordinator-tests"

xcrun clang \
  -fobjc-arc \
  -Wall -Wextra -Werror \
  -framework Foundation \
  "$repo_root/Source/Offline/YTMUObjectiveCExceptionGuard.m" \
  "$repo_root/Tests/YTMUObjectiveCExceptionGuardTests.m" \
  -I"$repo_root/Source/Offline" \
  -o "$build_root/objective-c-exception-guard-tests"

"$build_root/objective-c-exception-guard-tests"

python3 "$repo_root/Tests/build_native_visual_state_test.py" \
  "$repo_root/Source/Offline/YTMUNativeMiniPlayerSwipeController.m" \
  "$repo_root/Tests/YTMUNativeMiniPlayerVisualStateTests.m" \
  "$build_root/native-visual-state-tests.m"

xcrun clang \
  -fobjc-arc \
  -Wall -Wextra -Werror \
  -framework Foundation -framework CoreGraphics \
  "$build_root/native-visual-state-tests.m" \
  -I"$repo_root/Source/Offline" \
  -o "$build_root/native-visual-state-tests"

"$build_root/native-visual-state-tests"

bash "$repo_root/Tests/YTMUPlaybackIntegrationStaticTests.sh"
bash "$repo_root/Tests/YTMUOfflinePlayerUIStaticTests.sh"
bash "$repo_root/Tests/YTMUNativeMiniPlayerUnifiedDismissStaticTests.sh"
