#import "YTMUMiniPlayerSwipePolicy.h"

#include <math.h>

const double YTMUMiniPlayerSwipeVerticalDominanceRatio = 1.2;
const double YTMUMiniPlayerSwipeDistanceRatio = 0.35;
const double YTMUMiniPlayerSwipeFastVelocity = 900.0;

static bool YTMUMiniPlayerSwipeIsClearlyDownward(double horizontal, double vertical) {
    return vertical > 0.0
        && fabs(vertical) >= fabs(horizontal) * YTMUMiniPlayerSwipeVerticalDominanceRatio;
}

bool YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwner owner,
                                 YTMUPlaybackOwner expectedOwner,
                                 bool sessionActive,
                                 bool hasCurrentItem,
                                 bool beganOnControl,
                                 double velocityX,
                                 double velocityY) {
    bool supportedOwner = expectedOwner == YTMUPlaybackOwnerNative
        || expectedOwner == YTMUPlaybackOwnerOffline;
    return supportedOwner
        && owner == expectedOwner
        && owner != YTMUPlaybackOwnerTransitioning
        && sessionActive
        && hasCurrentItem
        && !beganOnControl
        && YTMUMiniPlayerSwipeIsClearlyDownward(velocityX, velocityY);
}

bool YTMUMiniPlayerSwipeShouldCommit(double cardHeight,
                                     double translationX,
                                     double translationY,
                                     double velocityX,
                                     double velocityY) {
    if (cardHeight <= 0.0
        || !YTMUMiniPlayerSwipeIsClearlyDownward(translationX, translationY)) {
        return false;
    }

    bool crossedDistanceThreshold = translationY >= cardHeight * YTMUMiniPlayerSwipeDistanceRatio;
    bool crossedVelocityThreshold = velocityY >= YTMUMiniPlayerSwipeFastVelocity
        && YTMUMiniPlayerSwipeIsClearlyDownward(velocityX, velocityY);
    return crossedDistanceThreshold || crossedVelocityThreshold;
}

double YTMUMiniPlayerSwipeProgress(double cardHeight, double translationY) {
    if (cardHeight <= 0.0 || translationY <= 0.0) return 0.0;
    return fmin(1.0, translationY / cardHeight);
}
