#pragma once

#include <stdbool.h>

#include "YTMUPlaybackCoordinatorPolicy.h"

typedef enum {
    YTMUNativeMiniPlayerVisibilityActionPreserve = 0,
    YTMUNativeMiniPlayerVisibilityActionSuppressForOffline = 1,
    YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed = 2,
    YTMUNativeMiniPlayerVisibilityActionRestoreForNativePlayback = 3,
} YTMUNativeMiniPlayerVisibilityAction;

YTMUNativeMiniPlayerVisibilityAction YTMUNativeMiniPlayerVisibilityActionForState(
    YTMUPlaybackOwner owner,
    YTMUPlaybackOwner targetOwner,
    bool nativeSessionActive,
    bool nativeSessionEndConfirmed,
    bool suppressionRequested,
    bool emptyShellCollapsed);
