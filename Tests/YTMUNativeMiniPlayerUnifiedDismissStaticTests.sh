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

# YouTube Music 9.14.2 renders the native mini-player across the child
# controller and YTMWatchView's container/gradient/shadow layers. Those watch
# compositor views can cover the whole screen, so the snapshot must be cropped
# to the semantic band between the mini-player top and the pivot-bar top. Each
# native layer may contribute only its intersection with that band.
assert_contains "$native_swipe" "YTMUResolveNativeMiniPlayerVisualContext" \
  "the complete native mini-player visual context is not resolved semantically"
assert_contains "$native_swipe" "NSClassFromString(@\"YTMWatchView\")" \
  "the verified watch view class is not version guarded"
assert_contains "$native_swipe" "_containerView" \
  "the native black mini-player shell owner is not included"
assert_contains "$native_swipe" "_gradientBackgroundView" \
  "the native mini-player background layer is not included"
assert_contains "$native_swipe" "_containerShadowView" \
  "the native mini-player shadow/separator layer is not included"
assert_contains "$native_swipe" "YTMUNativeMiniPlayerCardBandInWindow" \
  "the snapshot is not bounded by the native mini-player and pivot bar"
assert_contains "$native_swipe" "CGRectGetMinY(miniPlayerFrame)" \
  "the mini-player top does not define the snapshot's upper boundary"
assert_contains "$native_swipe" "CGRectGetMinY(pivotFrame)" \
  "the pivot-bar top does not define the snapshot's lower boundary"
assert_contains "$native_swipe" "CGRectIntersection(containerFrame, cardBand)" \
  "the native container is not clipped to the mini-player band"
assert_contains "$native_swipe" "CGRectIntersection(gradientFrame, cardBand)" \
  "the full-screen gradient can escape the mini-player band"
assert_contains "$native_swipe" "CGRectIntersection(shadowFrame, cardBand)" \
  "the native shadow is not clipped to the mini-player band"
assert_not_contains "$native_swipe" "CGRectUnion(containerFrame, gradientFrame)" \
  "full native compositor frames are still unioned before cropping"
assert_not_contains "$native_swipe" "CGRectUnion(cardFrame, controllerFrame)" \
  "the controller root can still expand the snapshot to the whole screen"
assert_contains "$native_swipe" "YTMUNativeMiniPlayerCardFrameIsSafe" \
  "the crop is not rejected when it matches a window or watch container"
assert_contains "$native_swipe" "YTMURectsEqualWithinTolerance(cardFrame, windowBounds)" \
  "a window-sized snapshot rectangle is not rejected"
assert_contains "$native_swipe" "CGRectIntersection(watchFrame, windowBounds)" \
  "a full YTMWatchView snapshot rectangle is not rejected"
assert_contains "$native_swipe" "CGRectIntersectsRect(cardFrame, headerFrame)" \
  "the snapshot can still overlap the native header"
assert_contains "$native_swipe" "CGRectIntersectsRect(cardFrame, pivotFrame)" \
  "the snapshot can still overlap the bottom tab bar"
assert_contains "$native_swipe" "resizableSnapshotViewFromRect:cardFrame" \
  "the complete composited card is not represented by one snapshot"
assert_contains "$native_swipe" "animationWindow" \
  "the unified snapshot does not use a non-clipping window overlay"
assert_contains "$native_swipe" "coveredNativeViews" \
  "the original shell and content are not covered atomically"
assert_contains "$native_swipe" "YTMUAppendCardParticipantIfContained" \
  "full-screen native views are not filtered out of the opacity participants"
assert_not_contains "$native_swipe" "YTMUAppendUniqueView(participants, gradientBackgroundView)" \
  "the full-screen watch gradient can still be hidden globally"
assert_not_contains "$native_swipe" "YTMUAppendUniqueView(participants, controllerRootView)" \
  "the full controller root can still be hidden globally"
assert_contains "$native_swipe" "excludedParticipants = @[window, watchView, pivotBarView]" \
  "screen, watch, and pivot containers are not explicitly excluded from opacity changes"
assert_not_contains "$native_swipe" "YTMUAppendUniqueView(participants, watchView)" \
  "the whole watch view can still be hidden during a mini-player swipe"
assert_not_contains "$native_swipe" "watchView.layer.opacity =" \
  "the whole watch view opacity changes during a mini-player swipe"
assert_not_contains "$native_swipe" "window.layer.opacity =" \
  "the whole window opacity changes during a mini-player swipe"
assert_not_contains "$native_swipe" "[visualRootView snapshotViewAfterScreenUpdates:NO]" \
  "the incomplete controller root is still used as the snapshot source"
assert_not_contains "$native_swipe" "UIView *containerView = visualRootView.superview;" \
  "the snapshot is still attached to the clipping immediate superview"
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

# The original card-scoped native views remain in YouTube Music's hierarchy and
# are merely covered while resetAndHide updates the hidden native layout.
# Playback teardown stays inside the existing adapter boundary and is requested
# once; full-screen compositor views are never part of this opacity set.
assert_contains "$native_swipe" "YTMUSetNativeMiniPlayerViewsLayerOpacity" \
  "the original shell and content can remain visible behind the snapshot"
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
assert_contains "$native_adapter" "NSSelectorFromString(@\"switchToLayout:animated:\")" \
  "the verified nonanimated layout-finalization command is missing"
assert_contains "$native_adapter" 'strcmp(switchLayoutEncoding, "v28@0:8q16B24")' \
  "the native nonanimated layout selector ABI is not verified"
assert_contains "$native_adapter" "nativeMiniPlayerVisualShellIsGeometricallyCollapsed" \
  "currentLayout alone is still treated as proof of visual collapse"
assert_contains "$native_adapter" "presentationLayer" \
  "an in-flight native collapse can be exposed before its presentation layer exits"
assert_contains "$native_adapter" "CGRectIntersection" \
  "the native shell's remaining visible height is not verified"
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
