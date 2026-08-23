#pragma once

#include <stdbool.h>

typedef enum {
    YTMUPlaybackOwnerNone = 0,
    YTMUPlaybackOwnerNative = 1,
    YTMUPlaybackOwnerOffline = 2,
    YTMUPlaybackOwnerTransitioning = 3,
} YTMUPlaybackOwner;

typedef struct {
    YTMUPlaybackOwner owner;
    YTMUPlaybackOwner targetOwner;
    YTMUPlaybackOwner fallbackOwner;
} YTMUPlaybackOwnershipState;

YTMUPlaybackOwnershipState YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwner owner);
YTMUPlaybackOwnershipState YTMUPlaybackBeginTransition(YTMUPlaybackOwnershipState state,
                                                       YTMUPlaybackOwner targetOwner);
YTMUPlaybackOwnershipState YTMUPlaybackCompleteTransition(YTMUPlaybackOwnershipState state,
                                                          bool succeeded);
YTMUPlaybackOwnershipState YTMUPlaybackEndOfflineSession(YTMUPlaybackOwnershipState state);
bool YTMUPlaybackOfflineControlsAreActive(YTMUPlaybackOwnershipState state);

