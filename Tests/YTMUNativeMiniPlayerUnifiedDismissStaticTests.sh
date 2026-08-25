#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
native_swipe="$repo_root/Source/Offline/YTMUNativeMiniPlayerSwipeController.m"
native_adapter="$repo_root/Source/Offline/YTMUNativePlaybackAdapter.m"
playback_hooks="$repo_root/Source/Offline/YTMUOfflinePlaybackHooks.x"

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

# The dedicated YTMMiniPlayerViewController view is only a snapshot source. It
# must contain the verified miniPlayerView, and only the transient snapshot may
# be translated or faded during the gesture.
assert_contains "$native_swipe" "YTMUResolveNativeMiniPlayerVisualRoot" \
  "native mini-player visual root is not resolved semantically"
assert_contains "$native_swipe" "[miniPlayerView isDescendantOfView:visualRoot]" \
  "the snapshot root is not verified to own the native mini-player contents"
assert_contains "$native_swipe" "snapshotViewAfterScreenUpdates:NO" \
  "the complete native mini-player is not represented by one snapshot"
assert_contains "$native_swipe" "[visualRootView snapshotViewAfterScreenUpdates:NO]" \
  "the snapshot does not render the dedicated controller root"
assert_contains "$native_swipe" "animationSnapshot" \
  "the unified dismissal snapshot is missing"
assert_contains "$native_swipe" "animationView.transform" \
  "the pan does not move a single animation owner"
assert_contains "$native_swipe" "animationView.alpha" \
  "the unified animation owner does not own the fade"
assert_contains "$native_swipe" "interactionBlocker" \
  "the covered native controls can receive input during the finish animation"
assert_not_contains "$native_swipe" "miniPlayerView.transform =" \
  "the internal native mini-player still receives its own transform"
assert_not_contains "$native_swipe" "self.visualRootView.transform =" \
  "the original native container is transformed alongside the snapshot"
if grep -Eq '(^|[[:space:]])(view|miniPlayerView|visualRootView)\.transform[[:space:]]*=[[:space:]]*CGAffineTransformTranslate' \
    "$native_swipe"; then
  fail "a native child or container is translated in addition to the snapshot"
fi

# The original controller view remains in YouTube Music's hierarchy and is
# merely covered while resetAndHide updates the hidden native layout. Playback
# teardown stays inside the existing adapter boundary and is requested once.
assert_contains "$native_swipe" "YTMUSetNativeMiniPlayerLayerOpacity(visualRootView, 0.0f)" \
  "the original native layers can remain visible behind the snapshot"
assert_contains "$native_swipe" "finishCommittedDismissalForGeneration" \
  "the single-card finish animation is missing"
assert_contains "$native_swipe" "collapseNativeMiniPlayerVisualShellAfterConfirmedSessionEnd" \
  "confirmed native teardown does not collapse the empty shell"
assert_contains "$native_swipe" "interactionDisabledAfterFailedCollapse" \
  "a visually covered shell can remain hit-testable after collapse failure"
[[ "$(grep -Fc 'requestNativeSessionEndFromMiniPlayerController:' "$native_swipe")" -eq 1 ]] \
  || fail "native session end is not requested exactly once from the swipe handler"
assert_contains "$native_swipe" "swipeGeneration" \
  "stale animation completions are not generation-guarded"
assert_contains "$native_swipe" "YTMUNativePlaybackWillStartNotification" \
  "a Native-to-Native song start cannot invalidate an older swipe completion"
assert_contains "$native_adapter" "prepareNativeMiniPlayerForPlaybackStart" \
  "native playback start does not invalidate an older shell-collapse generation"
assert_contains "$playback_hooks" "YTMUNativePlaybackWillStart" \
  "native play entry points do not announce playback before %orig"

# Empty-shell removal must use the verified 9.14.2 layout controller API, not
# translated labels, arbitrary child indices, or removal of native views.
assert_contains "$native_adapter" "_watchPageLayoutController" \
  "the verified watch layout controller is not used"
assert_contains "$native_adapter" "NSClassFromString(@\"YTMWatchPageLayoutControllerImpl\")" \
  "the native layout controller class is not version guarded"
assert_contains "$native_adapter" "NSSelectorFromString(@\"dismiss\")" \
  "the verified dismissed-layout command is missing"
assert_contains "$native_adapter" "NSSelectorFromString(@\"currentLayout\")" \
  "the dismissed native layout is not confirmed"
assert_not_contains "$native_adapter" "layoutController.class" \
  "the id-typed private layout controller uses unsupported property syntax"
assert_contains "$native_adapter" 'strcmp(dismissEncoding, "v16@0:8")' \
  "the native dismiss selector ABI is not verified"
assert_contains "$native_adapter" 'strcmp(currentLayoutEncoding, "q16@0:8")' \
  "the native currentLayout selector ABI is not verified"
assert_not_contains "$native_adapter" "Nothing is playing" \
  "empty-shell collapse depends on localized UI text"
assert_not_contains "$native_swipe" "Nothing is playing" \
  "swipe animation depends on localized UI text"
if grep -Eq 'subviews\[[0-9]+\]' "$native_swipe" "$native_adapter"; then
  fail "native mini-player selection depends on a subview index"
fi
assert_not_contains "$native_swipe" "[self.miniPlayerView removeFromSuperview]" \
  "the native mini-player view is removed from YouTube Music's hierarchy"
assert_not_contains "$native_swipe" "[self.visualRootView removeFromSuperview]" \
  "the native mini-player root is removed from YouTube Music's hierarchy"
if grep -F 'removeFromSuperview' "$native_swipe" \
    | grep -Fv '[snapshot removeFromSuperview]' \
    | grep -Fv '[interactionBlocker removeFromSuperview]' >/dev/null; then
  fail "a view other than the handler-owned transient snapshot is removed"
fi

printf 'Native mini-player unified-dismiss static tests passed\n'
