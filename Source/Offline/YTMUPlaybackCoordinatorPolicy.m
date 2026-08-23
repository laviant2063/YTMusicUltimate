#import "YTMUPlaybackCoordinatorPolicy.h"

YTMUPlaybackOwnershipState YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwner owner) {
    return (YTMUPlaybackOwnershipState){
        .owner = owner,
        .targetOwner = YTMUPlaybackOwnerNone,
        .fallbackOwner = YTMUPlaybackOwnerNone,
    };
}

YTMUPlaybackOwnershipState YTMUPlaybackBeginTransition(YTMUPlaybackOwnershipState state,
                                                       YTMUPlaybackOwner targetOwner) {
    YTMUPlaybackOwner fallbackOwner = state.owner;
    if (fallbackOwner == YTMUPlaybackOwnerTransitioning) {
        fallbackOwner = state.fallbackOwner;
    }
    return (YTMUPlaybackOwnershipState){
        .owner = YTMUPlaybackOwnerTransitioning,
        .targetOwner = targetOwner,
        .fallbackOwner = fallbackOwner,
    };
}

YTMUPlaybackOwnershipState YTMUPlaybackCompleteTransition(YTMUPlaybackOwnershipState state,
                                                          bool succeeded) {
    if (state.owner != YTMUPlaybackOwnerTransitioning) {
        return state;
    }
    return YTMUPlaybackOwnershipStateMake(succeeded ? state.targetOwner : state.fallbackOwner);
}

YTMUPlaybackOwnershipState YTMUPlaybackEndOfflineSession(YTMUPlaybackOwnershipState state) {
    if (state.owner == YTMUPlaybackOwnerOffline) {
        return YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwnerNone);
    }
    if (state.owner == YTMUPlaybackOwnerTransitioning
        && state.targetOwner == YTMUPlaybackOwnerOffline) {
        return YTMUPlaybackOwnershipStateMake(state.fallbackOwner);
    }
    if (state.owner == YTMUPlaybackOwnerTransitioning
        && state.fallbackOwner == YTMUPlaybackOwnerOffline) {
        state.fallbackOwner = YTMUPlaybackOwnerNone;
    }
    return state;
}

bool YTMUPlaybackOfflineControlsAreActive(YTMUPlaybackOwnershipState state) {
    return state.owner == YTMUPlaybackOwnerOffline;
}
