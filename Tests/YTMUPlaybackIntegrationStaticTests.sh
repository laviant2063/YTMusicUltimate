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
grep -Fq 'requestNativeSessionEndFromMiniPlayerController:' "$adapter"
grep -Fq 'prepareNativeMiniPlayerForPlaybackStart' "$adapter"
grep -Fq 'collapseEmptyNativeMiniPlayerAfterConfirmedSessionEnd' "$adapter"
grep -Fq 'applyNativeMiniPlayerVisibilityState' "$adapter"
grep -Fq 'nativeEmptyMiniPlayerCollapsed' "$adapter"
grep -Fq 'nativeSessionEndConfirmed' "$adapter"
grep -Fq 'nativeMiniPlayerVisibilityGeneration' "$adapter"
grep -Fq 'NSClassFromString(@"YTMWatchViewController")' "$adapter"
grep -Fq 'NSClassFromString(@"YTMWatchPageLayoutControllerImpl")' "$adapter"
grep -Fq 'NSSelectorFromString(@"resetAndHide")' "$adapter"
grep -Fq 'NSSelectorFromString(@"dismiss")' "$adapter"
grep -Fq 'NSSelectorFromString(@"currentLayout")' "$adapter"
grep -Fq 'class_getInstanceVariable(watch.class, "_watchPageLayoutController")' "$adapter"
grep -Fq 'ivar_getTypeEncoding' "$adapter"
grep -Fq 'method_getTypeEncoding' "$adapter"
grep -Fq '"v16@0:8"' "$adapter"
grep -Fq '"q16@0:8"' "$adapter"
grep -Fq 'void (*sendVoid)(id, SEL) = (void *)objc_msgSend;' "$adapter"
grep -Fq 'long long (*sendInteger)(id, SEL) = (void *)objc_msgSend;' "$adapter"
grep -Fq 'YTMUNativeMiniPlayerDismissedLayout' "$adapter"
grep -Fq 'collapsed = currentLayout == YTMUNativeMiniPlayerDismissedLayout;' "$adapter"
grep -Fq 'dispatch_async(dispatch_get_main_queue()' "$adapter"
grep -Fq 'YTMUNativePlaybackWillStart' "$hooks"
grep -Fq 'prepareNativeMiniPlayerForPlaybackStart' "$hooks"
if grep -Fq 'performSelector:' "$adapter"; then
  echo "Private native teardown must use an ABI-typed objc_msgSend call" >&2
  exit 1
fi
if grep -Fqi 'Nothing is playing' "$adapter" "$hooks"; then
  echo "Native empty-shell handling must not depend on display text" >&2
  exit 1
fi
if grep -Eq 'subviews\[[0-9]+\]|removeFromSuperview|removeFromParentViewController' "$adapter" "$hooks"; then
  echo "Native empty-shell handling must use the verified layout API" >&2
  exit 1
fi
echo "Playback integration static tests passed"
