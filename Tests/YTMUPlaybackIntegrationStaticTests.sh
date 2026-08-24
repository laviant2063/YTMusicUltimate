#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hooks="$repo_root/Source/Offline/YTMUOfflinePlaybackHooks.x"
manager="$repo_root/Source/Offline/YTMUOfflinePlaybackManager.m"
adapter="$repo_root/Source/Offline/YTMUNativePlaybackAdapter.m"
guard="$repo_root/Source/Offline/YTMUObjectiveCExceptionGuard.m"

if grep -Fq '%hook AVPlayer' "$hooks"; then
  echo "Global AVPlayer playback detection must not be used" >&2
  exit 1
fi

grep -Fq '%hook YTPlayerViewController' "$hooks"
grep -Fq '%hook YTMWatchViewController' "$hooks"
grep -Fq 'nativePlaybackWillStart' "$hooks"
grep -Fq 'playbackControllerDidPlay' "$hooks"
grep -Fq 'playbackControllerDidPause' "$hooks"
grep -Fq 'MPNowPlayingSession' "$manager"
grep -Fq 'endOfflineSessionWithReason:' "$manager"

if grep -Fq 'removeTarget:nil' "$manager"; then
  echo "Remote command teardown must remove only owned handler tokens" >&2
  exit 1
fi

grep -Fq '[command removeTarget:token]' "$manager"
grep -Fq '@catch (NSException *' "$guard"
grep -Fq 'YTMUPerformObjectiveCBlockSafely' "$manager"
grep -Fq 'fallBackToSharedMediaControls' "$manager"
grep -Fq 'loadCurrentTrackAndPlayUnchecked' "$manager"
grep -Fq 'YTMUPerformObjectiveCBlockSafely' "$adapter"
echo "Playback integration static tests passed"
