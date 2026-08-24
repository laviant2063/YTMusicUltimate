#pragma once

#include <stdbool.h>

#include "YTMUPlaybackCoordinatorPolicy.h"

extern const double YTMUMiniPlayerSwipeVerticalDominanceRatio;
extern const double YTMUMiniPlayerSwipeDistanceRatio;
extern const double YTMUMiniPlayerSwipeFastVelocity;

bool YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwner owner,
                                 YTMUPlaybackOwner expectedOwner,
                                 bool sessionActive,
                                 bool hasCurrentItem,
                                 bool beganOnControl,
                                 double velocityX,
                                 double velocityY);

bool YTMUMiniPlayerSwipeShouldCommit(double cardHeight,
                                     double translationX,
                                     double translationY,
                                     double velocityX,
                                     double velocityY);

double YTMUMiniPlayerSwipeProgress(double cardHeight, double translationY);
