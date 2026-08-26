#import "YTMUMiniPlayerSwipePolicy.h"

#include <math.h>

const double YTMUMiniPlayerSwipeVerticalDominanceRatio = 1.2;
const double YTMUMiniPlayerSwipeDistanceRatio = 0.35;
const double YTMUMiniPlayerSwipeFastVelocity = 900.0;

static bool YTMUMiniPlayerCropRectIsFiniteAndVisible(YTMUMiniPlayerCropRect rect) {
    return isfinite(rect.x)
        && isfinite(rect.y)
        && isfinite(rect.width)
        && isfinite(rect.height)
        && rect.width > 0.0
        && rect.height > 0.0;
}

static bool YTMUMiniPlayerCropRectIntersection(YTMUMiniPlayerCropRect lhs,
                                                YTMUMiniPlayerCropRect rhs,
                                                YTMUMiniPlayerCropRect *intersection) {
    double minimumX = fmax(lhs.x, rhs.x);
    double minimumY = fmax(lhs.y, rhs.y);
    double maximumX = fmin(lhs.x + lhs.width, rhs.x + rhs.width);
    double maximumY = fmin(lhs.y + lhs.height, rhs.y + rhs.height);
    YTMUMiniPlayerCropRect result = {
        minimumX,
        minimumY,
        maximumX - minimumX,
        maximumY - minimumY,
    };
    if (!YTMUMiniPlayerCropRectIsFiniteAndVisible(result)) return false;
    if (intersection != NULL) *intersection = result;
    return true;
}

bool YTMUNativeMiniPlayerResolveCardCrop(
    YTMUMiniPlayerCropRect windowRect,
    YTMUMiniPlayerCropRect nativeContainerRect,
    YTMUMiniPlayerCropRect pivotBarRect,
    double nativeMinimizedHeight,
    double geometryTolerance,
    YTMUMiniPlayerCropRect *resolvedCrop) {
    if (resolvedCrop == NULL
        || !YTMUMiniPlayerCropRectIsFiniteAndVisible(windowRect)
        || !YTMUMiniPlayerCropRectIsFiniteAndVisible(nativeContainerRect)
        || !YTMUMiniPlayerCropRectIsFiniteAndVisible(pivotBarRect)
        || !isfinite(nativeMinimizedHeight)
        || nativeMinimizedHeight <= 0.0
        || !isfinite(geometryTolerance)
        || geometryTolerance < 0.0) {
        return false;
    }

    // A native mini-player is a small bottom card. This independent ratio
    // guard rejects a bad private-API value before it can authorize a
    // screen-sized or almost-screen-sized snapshot.
    double maximumCardHeight = windowRect.height * 0.25;
    if (nativeMinimizedHeight > maximumCardHeight) return false;

    YTMUMiniPlayerCropRect visibleContainer;
    YTMUMiniPlayerCropRect visiblePivot;
    if (!YTMUMiniPlayerCropRectIntersection(nativeContainerRect,
                                             windowRect,
                                             &visibleContainer)
        || !YTMUMiniPlayerCropRectIntersection(pivotBarRect,
                                                windowRect,
                                                &visiblePivot)
        || fabs(visibleContainer.height - nativeMinimizedHeight) > geometryTolerance
        || visibleContainer.height > maximumCardHeight) {
        return false;
    }

    double containerBottom = visibleContainer.y + visibleContainer.height;
    double pivotTop = visiblePivot.y;
    if (!isfinite(containerBottom)
        || !isfinite(pivotTop)
        || fabs(pivotTop - containerBottom) > geometryTolerance) {
        return false;
    }

    // A sub-pixel native overlap is clipped at the pivot boundary. The crop
    // can therefore never contain tab-bar pixels even when UIKit rounds the
    // two native frames differently.
    double cropBottom = fmin(containerBottom, pivotTop);
    YTMUMiniPlayerCropRect crop = {
        visibleContainer.x,
        visibleContainer.y,
        visibleContainer.width,
        cropBottom - visibleContainer.y,
    };
    if (!YTMUMiniPlayerCropRectIsFiniteAndVisible(crop)
        || fabs(crop.height - nativeMinimizedHeight) > geometryTolerance
        || crop.height > maximumCardHeight
        || crop.y < windowRect.y
        || crop.y + crop.height > pivotTop) {
        return false;
    }

    *resolvedCrop = crop;
    return true;
}

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
