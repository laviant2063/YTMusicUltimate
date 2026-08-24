#include "YTMUNativeMiniPlayerVisibilityPolicy.h"

#include <stdio.h>
#include <stdlib.h>

static unsigned int failures = 0;

#define ASSERT_ACTION(expected, actual) do { \
    YTMUNativeMiniPlayerVisibilityAction expectedValue = (expected); \
    YTMUNativeMiniPlayerVisibilityAction actualValue = (actual); \
    if (expectedValue != actualValue) { \
        fprintf(stderr, "FAIL %s:%d: expected action %d, got %d\n", \
                __FILE__, __LINE__, (int)expectedValue, (int)actualValue); \
        failures++; \
    } \
} while (0)

static YTMUNativeMiniPlayerVisibilityAction actionFor(
    YTMUPlaybackOwner owner,
    YTMUPlaybackOwner targetOwner,
    bool nativeSessionActive,
    bool nativeSessionEndConfirmed,
    bool suppressionRequested,
    bool emptyShellCollapsed) {
    return YTMUNativeMiniPlayerVisibilityActionForState(
        owner,
        targetOwner,
        nativeSessionActive,
        nativeSessionEndConfirmed,
        suppressionRequested,
        emptyShellCollapsed);
}

static void testNativePlaybackStaysVisible(void) {
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionPreserve,
                  actionFor(YTMUPlaybackOwnerNative,
                            YTMUPlaybackOwnerNone,
                            true,
                            false,
                            false,
                            false));
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionRestoreForNativePlayback,
                  actionFor(YTMUPlaybackOwnerNative,
                            YTMUPlaybackOwnerNone,
                            true,
                            false,
                            false,
                            true));
}

static void testConfirmedIdleSessionEnsuresEmptyShellIsCollapsed(void) {
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed,
                  actionFor(YTMUPlaybackOwnerNone,
                            YTMUPlaybackOwnerNone,
                            false,
                            true,
                            false,
                            false));
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed,
                  actionFor(YTMUPlaybackOwnerNone,
                            YTMUPlaybackOwnerNone,
                            false,
                            true,
                            false,
                            true));
}

static void testUnconfirmedLaunchStateIsNotCollapsed(void) {
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionPreserve,
                  actionFor(YTMUPlaybackOwnerNone,
                            YTMUPlaybackOwnerNone,
                            false,
                            false,
                            false,
                            false));
}

static void testOfflineOwnershipKeepsSuppressionIndependent(void) {
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionSuppressForOffline,
                  actionFor(YTMUPlaybackOwnerOffline,
                            YTMUPlaybackOwnerNone,
                            false,
                            true,
                            false,
                            true));
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionSuppressForOffline,
                  actionFor(YTMUPlaybackOwnerTransitioning,
                            YTMUPlaybackOwnerOffline,
                            true,
                            false,
                            false,
                            false));
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionSuppressForOffline,
                  actionFor(YTMUPlaybackOwnerNone,
                            YTMUPlaybackOwnerNone,
                            false,
                            true,
                            true,
                            false));
}

static void testNativeRestartInvalidatesPriorCollapse(void) {
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionRestoreForNativePlayback,
                  actionFor(YTMUPlaybackOwnerTransitioning,
                            YTMUPlaybackOwnerNative,
                            false,
                            false,
                            false,
                            true));
    ASSERT_ACTION(YTMUNativeMiniPlayerVisibilityActionRestoreForNativePlayback,
                  actionFor(YTMUPlaybackOwnerNone,
                            YTMUPlaybackOwnerNone,
                            true,
                            false,
                            false,
                            true));
}

int main(void) {
    testNativePlaybackStaysVisible();
    testConfirmedIdleSessionEnsuresEmptyShellIsCollapsed();
    testUnconfirmedLaunchStateIsNotCollapsed();
    testOfflineOwnershipKeepsSuppressionIndependent();
    testNativeRestartInvalidatesPriorCollapse();

    if (failures != 0) {
        fprintf(stderr, "%u native mini-player visibility policy test(s) failed\n", failures);
        return EXIT_FAILURE;
    }
    puts("Native mini-player visibility policy tests passed");
    return EXIT_SUCCESS;
}
