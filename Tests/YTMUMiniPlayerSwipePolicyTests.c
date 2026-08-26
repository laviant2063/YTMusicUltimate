#include "YTMUMiniPlayerSwipePolicy.h"

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

static YTMUMiniPlayerCropRect cropRect(double x,
                                       double y,
                                       double width,
                                       double height) {
    YTMUMiniPlayerCropRect rect = {x, y, width, height};
    return rect;
}

static void assertCropRect(YTMUMiniPlayerCropRect expected,
                           YTMUMiniPlayerCropRect actual) {
    ASSERT_NEAR(expected.x, actual.x);
    ASSERT_NEAR(expected.y, actual.y);
    ASSERT_NEAR(expected.width, actual.width);
    ASSERT_NEAR(expected.height, actual.height);
}

static void testEligibilityRequiresTheExpectedStableOwner(void) {
    ASSERT_TRUE(YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerOffline,
                                             YTMUPlaybackOwnerOffline,
                                             true,
                                             true,
                                             false,
                                             100.0,
                                             500.0));
    ASSERT_TRUE(YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerNative,
                                             YTMUPlaybackOwnerNative,
                                             true,
                                             true,
                                             false,
                                             0.0,
                                             300.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerNative,
                                              YTMUPlaybackOwnerOffline,
                                              true,
                                              true,
                                              false,
                                              0.0,
                                              300.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerTransitioning,
                                              YTMUPlaybackOwnerOffline,
                                              true,
                                              true,
                                              false,
                                              0.0,
                                              300.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerNone,
                                              YTMUPlaybackOwnerNone,
                                              true,
                                              true,
                                              false,
                                              0.0,
                                              300.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerOffline,
                                              YTMUPlaybackOwnerOffline,
                                              false,
                                              true,
                                              false,
                                              0.0,
                                              300.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerOffline,
                                              YTMUPlaybackOwnerOffline,
                                              true,
                                              false,
                                              false,
                                              0.0,
                                              300.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerOffline,
                                              YTMUPlaybackOwnerOffline,
                                              true,
                                              true,
                                              true,
                                              0.0,
                                              300.0));
}

static void testEligibilityRequiresAClearlyDownwardVerticalPan(void) {
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerOffline,
                                              YTMUPlaybackOwnerOffline,
                                              true,
                                              true,
                                              false,
                                              0.0,
                                              -300.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerOffline,
                                              YTMUPlaybackOwnerOffline,
                                              true,
                                              true,
                                              false,
                                              300.0,
                                              300.0));
    ASSERT_TRUE(YTMUMiniPlayerSwipeCanBegin(YTMUPlaybackOwnerOffline,
                                             YTMUPlaybackOwnerOffline,
                                             true,
                                             true,
                                             false,
                                             100.0,
                                             120.0));
}

static void testDistanceAndVelocityCommitThresholds(void) {
    ASSERT_TRUE(YTMUMiniPlayerSwipeShouldCommit(100.0, 0.0, 35.0, 0.0, 0.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeShouldCommit(100.0, 0.0, 34.99, 0.0, 0.0));
    ASSERT_TRUE(YTMUMiniPlayerSwipeShouldCommit(100.0, 0.0, 5.0, 0.0, 900.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeShouldCommit(100.0, 0.0, 5.0, 0.0, 899.0));
}

static void testInvalidDirectionsAlwaysCancel(void) {
    ASSERT_TRUE(!YTMUMiniPlayerSwipeShouldCommit(100.0, 0.0, -40.0, 0.0, -1000.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeShouldCommit(100.0, 60.0, 40.0, 1000.0, 1000.0));
    ASSERT_TRUE(!YTMUMiniPlayerSwipeShouldCommit(0.0, 0.0, 40.0, 0.0, 1000.0));
}

static void testVisualProgressIsClamped(void) {
    ASSERT_NEAR(0.0, YTMUMiniPlayerSwipeProgress(100.0, -10.0));
    ASSERT_NEAR(0.25, YTMUMiniPlayerSwipeProgress(100.0, 25.0));
    ASSERT_NEAR(1.0, YTMUMiniPlayerSwipeProgress(100.0, 120.0));
    ASSERT_NEAR(0.0, YTMUMiniPlayerSwipeProgress(0.0, 25.0));
}

static void testNativeCropUsesTheVerifiedContainerInsteadOfAFullScreenView(void) {
    YTMUMiniPlayerCropRect resolved = cropRect(0.0, 0.0, 0.0, 0.0);
    ASSERT_TRUE(YTMUNativeMiniPlayerResolveCardCrop(
        cropRect(0.0, 0.0, 390.0, 844.0),
        cropRect(0.0, 720.0, 390.0, 64.0),
        cropRect(0.0, 784.0, 390.0, 60.0),
        64.0,
        1.0,
        &resolved));
    assertCropRect(cropRect(0.0, 720.0, 390.0, 64.0), resolved);
    ASSERT_TRUE(resolved.y > 100.0);
    ASSERT_TRUE(resolved.height < 844.0 * 0.25);
}

static void testNativeCropRejectsScreenSizedAndAlmostScreenSizedContainers(void) {
    YTMUMiniPlayerCropRect resolved = cropRect(1.0, 1.0, 1.0, 1.0);
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        cropRect(0.0, 0.0, 390.0, 844.0),
        cropRect(0.0, 0.0, 390.0, 844.0),
        cropRect(0.0, 784.0, 390.0, 60.0),
        64.0,
        1.0,
        &resolved));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        cropRect(0.0, 0.0, 390.0, 844.0),
        cropRect(0.0, 80.0, 390.0, 704.0),
        cropRect(0.0, 784.0, 390.0, 60.0),
        64.0,
        1.0,
        &resolved));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        cropRect(0.0, 0.0, 390.0, 844.0),
        cropRect(0.0, 84.0, 390.0, 700.0),
        cropRect(0.0, 784.0, 390.0, 60.0),
        700.0,
        1.0,
        &resolved));
}

static void testNativeCropRequiresNativeHeightAndPivotAdjacency(void) {
    YTMUMiniPlayerCropRect window = cropRect(0.0, 0.0, 390.0, 844.0);
    YTMUMiniPlayerCropRect pivot = cropRect(0.0, 784.0, 390.0, 60.0);
    YTMUMiniPlayerCropRect resolved = cropRect(0.0, 0.0, 0.0, 0.0);

    ASSERT_TRUE(YTMUNativeMiniPlayerResolveCardCrop(
        window,
        cropRect(0.0, 719.0, 390.0, 65.0),
        pivot,
        64.0,
        1.0,
        &resolved));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        window,
        cropRect(0.0, 718.0, 390.0, 66.0),
        pivot,
        64.0,
        1.0,
        &resolved));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        window,
        cropRect(0.0, 700.0, 390.0, 64.0),
        pivot,
        64.0,
        1.0,
        &resolved));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        window,
        cropRect(0.0, 730.0, 390.0, 64.0),
        pivot,
        64.0,
        1.0,
        &resolved));
}

static void testNativeCropRejectsInvalidGeometry(void) {
    YTMUMiniPlayerCropRect window = cropRect(0.0, 0.0, 390.0, 844.0);
    YTMUMiniPlayerCropRect container = cropRect(0.0, 720.0, 390.0, 64.0);
    YTMUMiniPlayerCropRect pivot = cropRect(0.0, 784.0, 390.0, 60.0);
    YTMUMiniPlayerCropRect resolved = cropRect(0.0, 0.0, 0.0, 0.0);

    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        window, container, pivot, 64.0, 1.0, NULL));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        cropRect(0.0, 0.0, 0.0, 844.0), container, pivot, 64.0, 1.0, &resolved));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        window, container, pivot, NAN, 1.0, &resolved));
    ASSERT_TRUE(!YTMUNativeMiniPlayerResolveCardCrop(
        window, container, pivot, 64.0, -1.0, &resolved));
}

int main(void) {
    testEligibilityRequiresTheExpectedStableOwner();
    testEligibilityRequiresAClearlyDownwardVerticalPan();
    testDistanceAndVelocityCommitThresholds();
    testInvalidDirectionsAlwaysCancel();
    testVisualProgressIsClamped();
    testNativeCropUsesTheVerifiedContainerInsteadOfAFullScreenView();
    testNativeCropRejectsScreenSizedAndAlmostScreenSizedContainers();
    testNativeCropRequiresNativeHeightAndPivotAdjacency();
    testNativeCropRejectsInvalidGeometry();

    if (failures != 0) {
        fprintf(stderr, "%d mini player swipe policy test(s) failed\n", failures);
        return EXIT_FAILURE;
    }
    puts("Mini player swipe policy tests passed");
    return EXIT_SUCCESS;
}
