#include "YTMUOfflinePlaybackPolicy.h"

#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define ASSERT_TRUE(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

#define ASSERT_INDEX(expected, actual) do { \
    size_t actualValue = (actual); \
    if ((expected) != actualValue) { \
        fprintf(stderr, "FAIL %s:%d: expected %zu, got %zu\n", __FILE__, __LINE__, (size_t)(expected), actualValue); \
        failures++; \
    } \
} while (0)

static void testSequentialTransitions(void) {
    ASSERT_INDEX(1, YTMUOfflineNextIndex(3, 0, YTMUOfflineRepeatModeOff));
    ASSERT_INDEX(YTMUOfflineNoIndex, YTMUOfflineNextIndex(3, 2, YTMUOfflineRepeatModeOff));
    ASSERT_INDEX(0, YTMUOfflineNextIndex(3, 2, YTMUOfflineRepeatModeAll));
    ASSERT_INDEX(1, YTMUOfflineNextIndex(3, 1, YTMUOfflineRepeatModeOne));
    ASSERT_INDEX(YTMUOfflineNoIndex, YTMUOfflineNextIndex(0, 0, YTMUOfflineRepeatModeAll));
}

static void testPreviousTransitions(void) {
    ASSERT_INDEX(1, YTMUOfflinePreviousIndex(3, 2, YTMUOfflineRepeatModeOff));
    ASSERT_INDEX(0, YTMUOfflinePreviousIndex(3, 0, YTMUOfflineRepeatModeOff));
    ASSERT_INDEX(2, YTMUOfflinePreviousIndex(3, 0, YTMUOfflineRepeatModeAll));
    ASSERT_INDEX(1, YTMUOfflinePreviousIndex(3, 1, YTMUOfflineRepeatModeOne));
}

static void testShufflePreservesCurrentTrack(void) {
    size_t first[6] = {0};
    size_t second[6] = {0};
    YTMUOfflineBuildShuffledOrder(6, 3, 0x12345678ULL, first);
    YTMUOfflineBuildShuffledOrder(6, 3, 0x12345678ULL, second);

    ASSERT_INDEX(3, first[0]);
    ASSERT_TRUE(YTMUOfflineOrderIsPermutation(first, 6));
    for (size_t index = 0; index < 6; index++) {
        ASSERT_INDEX(first[index], second[index]);
    }

    size_t sequential[6] = {0};
    YTMUOfflineBuildSequentialOrder(6, sequential);
    ASSERT_INDEX(3, YTMUOfflineFindOrderPosition(sequential, 6, first[0]));
}

static void testRemovalIndexCorrection(void) {
    ASSERT_INDEX(1, YTMUOfflineAdjustedIndexAfterRemoval(4, 2, 0));
    ASSERT_INDEX(2, YTMUOfflineAdjustedIndexAfterRemoval(4, 2, 2));
    ASSERT_INDEX(2, YTMUOfflineAdjustedIndexAfterRemoval(4, 3, 3));
    ASSERT_INDEX(YTMUOfflineNoIndex, YTMUOfflineAdjustedIndexAfterRemoval(1, 0, 0));
    ASSERT_INDEX(YTMUOfflineNoIndex, YTMUOfflineAdjustedIndexAfterRemoval(0, 0, 0));
}

int main(void) {
    testSequentialTransitions();
    testPreviousTransitions();
    testShufflePreservesCurrentTrack();
    testRemovalIndexCorrection();

    if (failures != 0) {
        fprintf(stderr, "%d offline playback policy test(s) failed\n", failures);
        return EXIT_FAILURE;
    }

    puts("Offline playback policy tests passed");
    return EXIT_SUCCESS;
}
