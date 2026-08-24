#include "YTMUOfflinePlayerVisualPolicy.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define ASSERT_TRUE(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

#define ASSERT_NEAR(expected, actual) do { \
    double actualValue = (actual); \
    if (fabs((expected) - actualValue) > 0.0001) { \
        fprintf(stderr, "FAIL %s:%d: expected %.4f, got %.4f\n", \
                __FILE__, __LINE__, (double)(expected), actualValue); \
        failures++; \
    } \
} while (0)

static void testMiniPlayerHeightRequiresAnActiveTrack(void) {
    ASSERT_NEAR(0.0, YTMUOfflineMiniPlayerHeight(false, false));
    ASSERT_NEAR(0.0, YTMUOfflineMiniPlayerHeight(true, false));
    ASSERT_NEAR(0.0, YTMUOfflineMiniPlayerHeight(false, true));
    ASSERT_NEAR(82.0, YTMUOfflineMiniPlayerHeight(true, true));
}

static void testArtworkPaletteIsDarkAndBounded(void) {
    YTMUOfflinePaletteColor bright = YTMUOfflineDarkPaletteColor(255, 255, 255);
    ASSERT_NEAR(0.30, bright.red);
    ASSERT_NEAR(0.30, bright.green);
    ASSERT_NEAR(0.34, bright.blue);
    ASSERT_TRUE(YTMUOfflinePaletteLuminance(bright) <= 0.31);

    YTMUOfflinePaletteColor black = YTMUOfflineDarkPaletteColor(0, 0, 0);
    ASSERT_NEAR(0.055, black.red);
    ASSERT_NEAR(0.065, black.green);
    ASSERT_NEAR(0.10, black.blue);
    ASSERT_TRUE(YTMUOfflinePaletteLuminance(black) < 0.10);

    YTMUOfflinePaletteColor saturated = YTMUOfflineDarkPaletteColor(255, 40, 20);
    ASSERT_TRUE(saturated.red <= 0.30);
    ASSERT_TRUE(saturated.green <= 0.30);
    ASSERT_TRUE(saturated.blue <= 0.34);
}

int main(void) {
    testMiniPlayerHeightRequiresAnActiveTrack();
    testArtworkPaletteIsDarkAndBounded();

    if (failures != 0) {
        fprintf(stderr, "%d offline player visual policy test(s) failed\n", failures);
        return EXIT_FAILURE;
    }
    puts("Offline player visual policy tests passed");
    return EXIT_SUCCESS;
}
