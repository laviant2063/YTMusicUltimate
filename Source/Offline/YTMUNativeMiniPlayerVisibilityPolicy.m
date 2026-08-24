#import "YTMUNativeMiniPlayerVisibilityPolicy.h"

YTMUNativeMiniPlayerVisibilityAction YTMUNativeMiniPlayerVisibilityActionForState(
    YTMUPlaybackOwner owner,
    YTMUPlaybackOwner targetOwner,
    bool nativeSessionActive,
    bool nativeSessionEndConfirmed,
    bool suppressionRequested,
    bool emptyShellCollapsed) {
    bool transitioningToOffline = owner == YTMUPlaybackOwnerTransitioning
        && targetOwner == YTMUPlaybackOwnerOffline;
    if (suppressionRequested
        || owner == YTMUPlaybackOwnerOffline
        || transitioningToOffline) {
        return YTMUNativeMiniPlayerVisibilityActionSuppressForOffline;
    }

    bool transitioningToNative = owner == YTMUPlaybackOwnerTransitioning
        && targetOwner == YTMUPlaybackOwnerNative;
    bool nativePlaybackExpected = owner == YTMUPlaybackOwnerNative
        || transitioningToNative
        || nativeSessionActive;
    if (nativePlaybackExpected) {
        return emptyShellCollapsed
            ? YTMUNativeMiniPlayerVisibilityActionRestoreForNativePlayback
            : YTMUNativeMiniPlayerVisibilityActionPreserve;
    }

    if (owner == YTMUPlaybackOwnerNone && nativeSessionEndConfirmed) {
        return YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed;
    }
    return YTMUNativeMiniPlayerVisibilityActionPreserve;
}
