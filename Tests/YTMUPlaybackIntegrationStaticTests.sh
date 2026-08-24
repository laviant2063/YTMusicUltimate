#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hooks="$repo_root/Source/Offline/YTMUOfflinePlaybackHooks.x"
manager="$repo_root/Source/Offline/YTMUOfflinePlaybackManager.m"
adapter="$repo_root/Source/Offline/YTMUNativePlaybackAdapter.m"
guard="$repo_root/Source/Offline/YTMUObjectiveCExceptionGuard.m"
mini_player="$repo_root/Source/Offline/YTMUOfflineMiniPlayerView.m"
now_playing="$repo_root/Source/Offline/YTMUOfflineNowPlayingViewController.m"
visual_policy="$repo_root/Source/Offline/YTMUOfflinePlayerVisualPolicy.m"
downloads="$repo_root/Source/Prefs/YTMDownloads.m"

if [[ ! -f "$visual_policy" ]]; then
  echo "Offline player visual policy is required" >&2
  exit 1
fi

if grep -Fq '%hook AVPlayer' "$hooks"; then
  echo "Global AVPlayer playback detection must not be used" >&2
  exit 1
fi

grep -Fq '%hook YTPlayerViewController' "$hooks"
grep -Fq '%hook YTMWatchViewController' "$hooks"
grep -Fq 'prepareForNativePlayback' "$hooks"
grep -Fq 'if (!YTMUPrepareForNativePlayback(self)) return;' "$hooks"
grep -Fq 'MPRemoteCommandHandlerStatusCommandFailed' "$hooks"
grep -Fq 'YTMUPerformObjectiveCBlockSafely' "$hooks"
grep -Fq 'playbackControllerDidPlay' "$hooks"
grep -Fq 'playbackControllerDidPause' "$hooks"

if grep -Fq 'pageLayout:(id)layout' "$hooks"; then
  echo "YTMWatchViewController pageLayout must match the 9.14 long long ABI" >&2
  exit 1
fi
if grep -Fq -- '- (void)handlePlayCommand:' "$hooks" \
  || grep -Fq -- '- (void)handleTogglePlayPauseCommand:' "$hooks"; then
  echo "Native remote command hooks must preserve their long long return ABI" >&2
  exit 1
fi

grep -Fq 'pageLayout:(long long)layout' "$hooks"
grep -Fq -- '- (long long)handlePlayCommand:(id)command' "$hooks"
grep -Fq -- '- (long long)handleTogglePlayPauseCommand:(id)command' "$hooks"
grep -Fq -- '- (void)replayWithSeekSource:(int)source' "$hooks"
grep -Fq -- '- (void)pauseWithStoppageReason:(int)reason' "$hooks"
if [[ "$(grep -Fc 'return %orig(command);' "$hooks")" -ne 2 ]]; then
  echo "Native remote command hooks must return both original results" >&2
  exit 1
fi

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
grep -Fq 'if (self.miniPlayerSuppressed == suppressed) return;' "$adapter"
grep -Fq 'showNativeTransitionFailureWithMessage:' "$adapter"
grep -Fq 'YTMUOfflineMiniPlayerHeight' "$mini_player"
grep -Fq 'heightConstraint.constant' "$mini_player"
grep -Fq 'YTMUOfflineArtworkPaletteProvider' "$now_playing"
grep -Fq 'NSCache' "$now_playing"
grep -Fq 'dispatch_get_global_queue' "$now_playing"
grep -Fq 'accessibilityLabel = @"플레이어 축소"' "$now_playing"
grep -Fq 'YTMUOfflinePlaybackDidChangeNotification' "$downloads"
grep -Fq 'YTMUDownloadsSectionPlaylists' "$downloads"
grep -Fq 'YTMUDownloadsSectionTracks' "$downloads"
grep -Fq 'YTMUDownloadsSectionFileActions' "$downloads"
grep -Fq 'YTMUOfflineDiagnostics' "$manager"
echo "Playback integration static tests passed"
