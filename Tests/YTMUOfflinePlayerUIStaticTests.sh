#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
downloads="$repo_root/Source/Prefs/YTMDownloads.m"
mini_player="$repo_root/Source/Offline/YTMUOfflineMiniPlayerView.m"
now_playing="$repo_root/Source/Offline/YTMUOfflineNowPlayingViewController.m"
player_menu="$repo_root/Source/Offline/YTMUOfflinePlayerMenu.m"
other_settings="$repo_root/Source/OtherSettings.x"
playback_hooks="$repo_root/Source/Offline/YTMUOfflinePlaybackHooks.x"
native_adapter="$repo_root/Source/Offline/YTMUNativePlaybackAdapter.m"
native_swipe="$repo_root/Source/Offline/YTMUNativeMiniPlayerSwipeController.m"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  local message="$3"
  grep -Fq -- "$text" "$file" || fail "$message"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  local message="$3"
  if grep -Fq -- "$text" "$file"; then
    fail "$message"
  fi
}

assert_before() {
  local file="$1"
  local first="$2"
  local second="$3"
  local message="$4"
  local first_line second_line
  first_line="$(grep -nF -- "$first" "$file" | head -1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$file" | head -1 | cut -d: -f1 || true)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    fail "$message"
  fi
}

assert_unchanged_blob() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(git -C "$repo_root" hash-object --path="$path" "$repo_root/$path")"
  [[ "$actual" == "$expected" ]] || fail "protected playback file changed: $path"
}

# Downloads owns the clipped three-button header, so removing it must not touch
# the native Music header or the shared tab implementation.
assert_not_contains "$downloads" "YTMUDownloadsHeaderButton" \
  "Downloads still defines the clipped three-button header"
assert_not_contains "$downloads" "tableHeaderView = header" \
  "Downloads still installs the 72pt clipped table header"
assert_contains "$downloads" "YTMUDownloadsSectionPlaylists" \
  "offline playlist section was removed"
assert_contains "$downloads" "YTMUDownloadsSectionTracks" \
  "downloaded tracks section was removed"
assert_contains "$downloads" "YTMUDownloadsSectionFileActions" \
  "file actions section was removed"
assert_contains "$downloads" "handler:^(__unused UIAction *action) { [weakSelf createPlaylist:nil]; }" \
  "playlist creation became unreachable after removing the header buttons"
assert_contains "$downloads" "self.tableView.bottomAnchor constraintEqualToAnchor:self.miniPlayer.topAnchor" \
  "the list is no longer constrained above the mini player"

# The mini player must own an explicit collapsible height and retain the
# existing playback-manager commands.
assert_contains "$mini_player" "heightConstraint" \
  "mini player does not have an explicit collapsible height"
assert_contains "$mini_player" "YTMUOfflineMiniPlayerHeight" \
  "mini player visibility is not driven by the UI policy"
assert_contains "$mini_player" "systemBlueColor" \
  "offline badge is not blue"
assert_contains "$mini_player" "YTMUOfflineMinimumTouchDimension" \
  "mini player does not enforce 44pt controls"
assert_contains "$mini_player" "[YTMUOfflinePlaybackManager.sharedManager togglePlayback]" \
  "existing mini-player play/pause command was replaced"
assert_contains "$mini_player" "[YTMUOfflinePlaybackManager.sharedManager next]" \
  "existing mini-player next command was replaced"
assert_contains "$mini_player" "UIPanGestureRecognizer" \
  "offline mini-player swipe recognizer is missing"
assert_contains "$mini_player" "YTMUMiniPlayerSwipeCanBegin" \
  "offline mini-player eligibility is not delegated to the pure swipe policy"
assert_contains "$mini_player" "YTMUMiniPlayerSwipeShouldCommit" \
  "offline mini-player completion is not delegated to the pure swipe policy"
assert_contains "$mini_player" "endOfflineSessionWithReason:YTMUOfflineSessionEndReasonUserStop" \
  "offline swipe does not delegate complete teardown to the coordinator"
assert_contains "$mini_player" "YTMUPerformObjectiveCBlockSafely" \
  "offline swipe teardown is not contained at the host-app boundary"
assert_contains "$mini_player" "cancelsTouchesInView = NO" \
  "offline swipe can cancel existing mini-player controls"
assert_contains "$mini_player" "UIAccessibilityCustomAction" \
  "offline mini-player has no accessible session-ending alternative"
assert_not_contains "$mini_player" "replaceCurrentItemWithPlayerItem" \
  "offline mini-player directly manipulates AVPlayer teardown"
assert_not_contains "$mini_player" "MPNowPlaying" \
  "offline mini-player directly manipulates Now Playing state"

# YouTube Music 9.14's mini-player controller owns horizontal queue swipes, but
# its downward layout pan belongs to the ancestor watch page and is not a
# reliable mini-player dismissal surface. Install one guarded recognizer on the
# confirmed miniPlayerView and keep teardown inside the native adapter.
assert_contains "$other_settings" "resetMiniplayerRestrictions" \
  "native mini-player restrictions are no longer reset"
assert_contains "$playback_hooks" "%hook YTMMiniPlayerViewController" \
  "native mini-player registration hook is missing"
assert_contains "$playback_hooks" "YTMUInstallNativeMiniPlayerSwipeIfNeeded(self)" \
  "native mini-player hook does not install the guarded fallback"
assert_contains "$playback_hooks" "- (void)resetAndHide" \
  "native reset-and-hide session-end hook is missing"
assert_contains "$playback_hooks" "- (void)resetPlayer" \
  "native reset-player session-end hook is missing"
assert_contains "$playback_hooks" "[YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackSessionDidEnd]" \
  "native dismissal no longer clears playback ownership"
[[ -f "$native_swipe" ]] || fail "native mini-player swipe controller is missing"
assert_contains "$native_swipe" "objc_getAssociatedObject" \
  "native fallback recognizer installation is not idempotent"
assert_contains "$native_swipe" "NSSelectorFromString(@\"miniPlayerView\")" \
  "native fallback is not attached to the confirmed miniPlayerView"
assert_contains "$native_swipe" "YTMUMiniPlayerSwipeCanBegin" \
  "native fallback eligibility is not delegated to the pure swipe policy"
assert_contains "$native_swipe" "YTMUMiniPlayerSwipeShouldCommit" \
  "native fallback completion is not delegated to the pure swipe policy"
assert_contains "$native_swipe" "YTMUPlaybackOwnerNative" \
  "native fallback is not restricted to native ownership"
assert_contains "$native_swipe" "cancelsTouchesInView = NO" \
  "native fallback can cancel existing mini-player controls"
assert_contains "$native_swipe" "requestNativeSessionEndFromMiniPlayerController" \
  "native fallback bypasses the adapter termination boundary"
assert_contains "$native_swipe" "UIApplicationDidEnterBackgroundNotification" \
  "native fallback does not cancel safely when the app backgrounds"
assert_contains "$native_swipe" "YTMUPlaybackOwnershipDidChangeNotification" \
  "native fallback does not cancel when playback ownership changes"
assert_not_contains "$native_swipe" "resetAndHide" \
  "native fallback calls a private teardown selector directly"
assert_not_contains "$native_swipe" "AVPlayer" \
  "native fallback manipulates playback directly"
assert_not_contains "$native_swipe" "setHidden:" \
  "native fallback hides UI independently of native session teardown"
assert_contains "$native_adapter" "NSSelectorFromString(@\"resetAndHide\")" \
  "native adapter does not use the verified no-argument teardown selector"
assert_contains "$native_adapter" "YTMUPerformObjectiveCBlockSafely" \
  "native teardown selector is not exception-contained"

# Full-screen UI requirements: bounded asynchronous artwork palette, stale
# result protection, accessible controls, repeat-one state and queue metadata.
assert_contains "$now_playing" "<ImageIO/ImageIO.h>" \
  "artwork analysis is not using ImageIO"
assert_contains "$now_playing" "YTMUOfflineArtworkPaletteProvider" \
  "asynchronous artwork palette provider is missing"
assert_contains "$now_playing" "artworkRequestIdentifier" \
  "stale artwork result protection is missing"
assert_contains "$now_playing" "repeat.1" \
  "repeat-one icon state is missing"
assert_contains "$now_playing" "YTMUOfflineQueueCell" \
  "queue card cell is missing"
assert_contains "$now_playing" "durationLabel" \
  "queue duration UI is missing"
assert_contains "$now_playing" "@\"플레이어 축소\"" \
  "minimize VoiceOver label is missing"
assert_contains "$now_playing" "[YTMUOfflinePlaybackManager.sharedManager toggleShuffle]" \
  "existing shuffle command was replaced"
assert_contains "$now_playing" "[YTMUOfflinePlaybackManager.sharedManager previous]" \
  "existing previous command was replaced"
assert_contains "$now_playing" "[YTMUOfflinePlaybackManager.sharedManager togglePlayback]" \
  "existing full-player play/pause command was replaced"
assert_contains "$now_playing" "[YTMUOfflinePlaybackManager.sharedManager next]" \
  "existing next command was replaced"
assert_contains "$now_playing" "[YTMUOfflinePlaybackManager.sharedManager cycleRepeatMode]" \
  "existing repeat command was replaced"
assert_contains "$now_playing" "playQueueIndex:indexPath.row" \
  "existing queue-selection command was replaced"
assert_contains "$now_playing" "moveQueueItemFromIndex:sourceIndexPath.row" \
  "existing queue-reorder command was replaced"

# The custom menu provides icons, separation and a destructive row while still
# delegating complete teardown to the existing coordinator API.
assert_contains "$player_menu" "YTMUOfflinePlayerMenuViewController" \
  "custom offline player menu is missing"
assert_contains "$player_menu" "systemRedColor" \
  "offline stop row is not destructive red"
assert_contains "$player_menu" "OFFLINE_END_PRESERVES_DATA" \
  "offline data-preservation message is missing"
assert_contains "$player_menu" "endOfflineSessionWithReason:YTMUOfflineSessionEndReasonUserStop" \
  "menu no longer delegates teardown to the coordinator"
assert_before "$player_menu" "OFFLINE_PLAYBACK_SPEED" "OFFLINE_SLEEP_TIMER" \
  "playback speed must precede sleep timer"
assert_before "$player_menu" "OFFLINE_SLEEP_TIMER" "@\"AirPlay\"" \
  "sleep timer must precede AirPlay"
assert_before "$player_menu" "@\"AirPlay\"" "CURRENT_QUEUE" \
  "AirPlay must precede current queue"
assert_before "$player_menu" "CURRENT_QUEUE" "OFFLINE_END_PLAYBACK" \
  "current queue must precede offline stop"

# Pin the validated playback and persistence core. The adapter and hook hashes
# include the audited native mini-player snapshot/collapse additions while the
# playback manager, coordinator, policies and metadata remain unchanged.
assert_unchanged_blob "Source/Offline/YTMUOfflinePlaybackManager.m" "cda6af9a764448e9d5746a1584885fa125c4e7a4"
assert_unchanged_blob "Source/Offline/YTMUPlaybackCoordinator.m" "942f7c775831cf9bbdee7216943bf78186000603"
assert_unchanged_blob "Source/Offline/YTMUNativePlaybackAdapter.h" "dcdfb18b9f132c39ef3c242798f10399866eec9d"
assert_unchanged_blob "Source/Offline/YTMUNativePlaybackAdapter.m" "d4d580e179e071e62f9fb49eb9e4d3e0c1e1198b"
assert_unchanged_blob "Source/Offline/YTMUOfflinePlaybackHooks.x" "f9212ab416ea7c6ea2cc752387fc28ea997734db"
assert_unchanged_blob "Source/Offline/YTMUOfflinePlaybackPolicy.m" "a7f6ceb610a3104810321f8cfe86da449cd3dda4"
assert_unchanged_blob "Source/Offline/YTMUPlaybackCoordinatorPolicy.m" "8644aca7bbbcb04c87563dd2a5ff369d5d6d4a33"
assert_unchanged_blob "Source/Offline/YTMUOfflineModels.h" "98871b06ace3b25b16c3301c5476fe6db2705162"
assert_unchanged_blob "Source/Offline/YTMUOfflineModels.m" "3931eedf09672948e91a54405ed2fff26a7a7c91"
assert_unchanged_blob "Source/YTMTab.x" "8be6287651499e77565c40df4366eeeb8633c5f4"

printf 'Offline player UI static tests passed\n'
