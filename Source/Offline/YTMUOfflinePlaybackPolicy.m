#include "YTMUOfflinePlaybackPolicy.h"

static uint64_t YTMUOfflineNextRandom(uint64_t *state) {
    uint64_t value = *state;
    if (value == 0) {
        value = 0x9e3779b97f4a7c15ULL;
    }
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    *state = value;
    return value * 0x2545f4914f6cdd1dULL;
}

size_t YTMUOfflineNextIndex(size_t count, size_t currentIndex, YTMUOfflineRepeatMode repeatMode) {
    if (count == 0 || currentIndex >= count) {
        return YTMUOfflineNoIndex;
    }
    if (repeatMode == YTMUOfflineRepeatModeOne) {
        return currentIndex;
    }
    if (currentIndex + 1 < count) {
        return currentIndex + 1;
    }
    return repeatMode == YTMUOfflineRepeatModeAll ? 0 : YTMUOfflineNoIndex;
}

size_t YTMUOfflinePreviousIndex(size_t count, size_t currentIndex, YTMUOfflineRepeatMode repeatMode) {
    if (count == 0 || currentIndex >= count) {
        return YTMUOfflineNoIndex;
    }
    if (repeatMode == YTMUOfflineRepeatModeOne) {
        return currentIndex;
    }
    if (currentIndex > 0) {
        return currentIndex - 1;
    }
    return repeatMode == YTMUOfflineRepeatModeAll ? count - 1 : 0;
}

size_t YTMUOfflineAdjustedIndexAfterRemoval(size_t countBeforeRemoval, size_t currentIndex, size_t removedIndex) {
    if (countBeforeRemoval == 0 || currentIndex >= countBeforeRemoval || removedIndex >= countBeforeRemoval) {
        return YTMUOfflineNoIndex;
    }

    size_t countAfterRemoval = countBeforeRemoval - 1;
    if (countAfterRemoval == 0) {
        return YTMUOfflineNoIndex;
    }
    if (removedIndex < currentIndex) {
        return currentIndex - 1;
    }
    if (removedIndex > currentIndex) {
        return currentIndex;
    }
    return currentIndex < countAfterRemoval ? currentIndex : countAfterRemoval - 1;
}

void YTMUOfflineBuildSequentialOrder(size_t count, size_t *order) {
    if (order == NULL) {
        return;
    }
    for (size_t index = 0; index < count; index++) {
        order[index] = index;
    }
}

void YTMUOfflineBuildShuffledOrder(size_t count, size_t currentOriginalIndex, uint64_t seed, size_t *order) {
    if (count == 0 || order == NULL) {
        return;
    }

    YTMUOfflineBuildSequentialOrder(count, order);
    if (currentOriginalIndex >= count) {
        currentOriginalIndex = 0;
    }

    size_t currentValue = order[currentOriginalIndex];
    order[currentOriginalIndex] = order[0];
    order[0] = currentValue;

    for (size_t upperBound = count - 1; upperBound > 1; upperBound--) {
        size_t randomIndex = 1 + (size_t)(YTMUOfflineNextRandom(&seed) % upperBound);
        size_t value = order[upperBound];
        order[upperBound] = order[randomIndex];
        order[randomIndex] = value;
    }
}

size_t YTMUOfflineFindOrderPosition(const size_t *order, size_t count, size_t originalIndex) {
    if (order == NULL) {
        return YTMUOfflineNoIndex;
    }
    for (size_t index = 0; index < count; index++) {
        if (order[index] == originalIndex) {
            return index;
        }
    }
    return YTMUOfflineNoIndex;
}

bool YTMUOfflineOrderIsPermutation(const size_t *order, size_t count) {
    if (count > 0 && order == NULL) {
        return false;
    }
    for (size_t index = 0; index < count; index++) {
        if (order[index] >= count) {
            return false;
        }
        for (size_t previous = 0; previous < index; previous++) {
            if (order[previous] == order[index]) {
                return false;
            }
        }
    }
    return true;
}
