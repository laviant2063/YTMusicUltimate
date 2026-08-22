#ifndef YTMUOfflinePlaybackPolicy_h
#define YTMUOfflinePlaybackPolicy_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    YTMUOfflineRepeatModeOff = 0,
    YTMUOfflineRepeatModeAll = 1,
    YTMUOfflineRepeatModeOne = 2,
} YTMUOfflineRepeatMode;

#define YTMUOfflineNoIndex ((size_t)-1)

size_t YTMUOfflineNextIndex(size_t count, size_t currentIndex, YTMUOfflineRepeatMode repeatMode);
size_t YTMUOfflinePreviousIndex(size_t count, size_t currentIndex, YTMUOfflineRepeatMode repeatMode);
size_t YTMUOfflineAdjustedIndexAfterRemoval(size_t countBeforeRemoval, size_t currentIndex, size_t removedIndex);
void YTMUOfflineBuildSequentialOrder(size_t count, size_t *order);
void YTMUOfflineBuildShuffledOrder(size_t count, size_t currentOriginalIndex, uint64_t seed, size_t *order);
size_t YTMUOfflineFindOrderPosition(const size_t *order, size_t count, size_t originalIndex);
bool YTMUOfflineOrderIsPermutation(const size_t *order, size_t count);

#endif
