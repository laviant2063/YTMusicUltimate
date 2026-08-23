#import <Foundation/Foundation.h>

#import "YTMUPlaybackCoordinator.h"

static NSUInteger failures = 0;

#define ASSERT_TRUE(condition) do { \
    if (!(condition)) { \
        NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

#define ASSERT_EQUAL_INTEGER(expected, actual) do { \
    NSInteger expectedValue = (NSInteger)(expected); \
    NSInteger actualValue = (NSInteger)(actual); \
    if (expectedValue != actualValue) { \
        NSLog(@"FAIL %s:%d: expected %ld, got %ld", __FILE__, __LINE__, (long)expectedValue, (long)actualValue); \
        failures++; \
    } \
} while (0)

@interface YTMUTestNativeAdapter : NSObject <YTMUNativePlaybackControlling>
@property (nonatomic, assign, getter=isNativePlaybackAudible) BOOL nativePlaybackAudible;
@property (nonatomic, assign) BOOL pauseRequestSucceeds;
@property (nonatomic, assign) BOOL pauseCompletesImmediately;
@property (nonatomic, assign) BOOL nativeMiniPlayerSuppressed;
@property (nonatomic, assign) NSUInteger pauseRequestCount;
@property (nonatomic, assign) NSUInteger toastCount;
@end

@implementation YTMUTestNativeAdapter
- (BOOL)requestNativePauseForOfflinePlayback:(NSError **)error {
    self.pauseRequestCount++;
    if (!self.pauseRequestSucceeds) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"YTMUPlaybackCoordinatorTests" code:1 userInfo:nil];
        }
        return NO;
    }
    if (self.pauseCompletesImmediately) {
        self.nativePlaybackAudible = NO;
    }
    return YES;
}
- (void)setNativeMiniPlayerSuppressed:(BOOL)suppressed {
    _nativeMiniPlayerSuppressed = suppressed;
}
- (void)showOfflineEndedForNativeToast {
    self.toastCount++;
}
@end

@interface YTMUTestOfflineController : NSObject <YTMUOfflineSessionControlling>
@property (nonatomic, assign, getter=isOfflineSessionActive) BOOL offlineSessionActive;
@property (nonatomic, assign) NSUInteger endCount;
@property (nonatomic, assign) YTMUOfflineSessionEndReason lastReason;
@end

@implementation YTMUTestOfflineController
- (void)endOfflineSessionWithReason:(YTMUOfflineSessionEndReason)reason {
    if (!self.offlineSessionActive) {
        return;
    }
    self.endCount++;
    self.lastReason = reason;
    self.offlineSessionActive = NO;
}
@end

static YTMUPlaybackCoordinator *MakeCoordinator(YTMUTestNativeAdapter **nativeOut,
                                                YTMUTestOfflineController **offlineOut) {
    YTMUTestNativeAdapter *native = [[YTMUTestNativeAdapter alloc] init];
    native.pauseRequestSucceeds = YES;
    YTMUTestOfflineController *offline = [[YTMUTestOfflineController alloc] init];
    if (nativeOut != NULL) *nativeOut = native;
    if (offlineOut != NULL) *offlineOut = offline;
    return [[YTMUPlaybackCoordinator alloc] initWithNativeAdapter:native offlineController:offline];
}

static void testPureOwnershipTransitions(void) {
    YTMUPlaybackOwnershipState state = YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwnerNative);
    state = YTMUPlaybackBeginTransition(state, YTMUPlaybackOwnerOffline);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerTransitioning, state.owner);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerOffline, state.targetOwner);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, state.fallbackOwner);
    ASSERT_TRUE(!YTMUPlaybackOfflineControlsAreActive(state));

    YTMUPlaybackOwnershipState failed = YTMUPlaybackCompleteTransition(state, false);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, failed.owner);
    YTMUPlaybackOwnershipState succeeded = YTMUPlaybackCompleteTransition(state, true);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerOffline, succeeded.owner);
    ASSERT_TRUE(YTMUPlaybackOfflineControlsAreActive(succeeded));
}

static void testNativeToOfflineWaitsForConfirmedPause(void) {
    YTMUTestNativeAdapter *native = nil;
    YTMUPlaybackCoordinator *coordinator = MakeCoordinator(&native, NULL);
    [coordinator nativePlaybackDidStart];
    native.nativePlaybackAudible = YES;

    __block BOOL completionCalled = NO;
    __block BOOL granted = NO;
    [coordinator requestOfflinePlaybackWithCompletion:^(BOOL value, NSError *error) {
        completionCalled = YES;
        granted = value;
        ASSERT_TRUE(error == nil);
    }];

    ASSERT_EQUAL_INTEGER(1, native.pauseRequestCount);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerTransitioning, coordinator.owner);
    ASSERT_TRUE(!completionCalled);
    ASSERT_TRUE(!native.nativeMiniPlayerSuppressed);

    native.nativePlaybackAudible = NO;
    [coordinator nativePlaybackDidPause];
    ASSERT_TRUE(completionCalled);
    ASSERT_TRUE(granted);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerOffline, coordinator.owner);
    ASSERT_TRUE(native.nativeMiniPlayerSuppressed);
    ASSERT_TRUE(coordinator.offlineControlsShouldBeActive);
}

static void testNativePauseFailureCancelsOfflineStart(void) {
    YTMUTestNativeAdapter *native = nil;
    YTMUPlaybackCoordinator *coordinator = MakeCoordinator(&native, NULL);
    [coordinator nativePlaybackDidStart];
    native.nativePlaybackAudible = YES;
    native.pauseRequestSucceeds = NO;

    __block BOOL completionCalled = NO;
    __block BOOL granted = YES;
    [coordinator requestOfflinePlaybackWithCompletion:^(BOOL value, NSError *error) {
        completionCalled = YES;
        granted = value;
        ASSERT_TRUE(error != nil);
    }];

    ASSERT_TRUE(completionCalled);
    ASSERT_TRUE(!granted);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, coordinator.owner);
    ASSERT_TRUE(!native.nativeMiniPlayerSuppressed);
}

static void testNativeStartCancelsPendingOfflineGrant(void) {
    YTMUTestNativeAdapter *native = nil;
    YTMUPlaybackCoordinator *coordinator = MakeCoordinator(&native, NULL);
    [coordinator nativePlaybackDidStart];
    native.nativePlaybackAudible = YES;

    __block BOOL completionCalled = NO;
    __block BOOL granted = YES;
    [coordinator requestOfflinePlaybackWithCompletion:^(BOOL value, NSError *error) {
        completionCalled = YES;
        granted = value;
        ASSERT_TRUE(error != nil);
    }];
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerTransitioning, coordinator.owner);

    [coordinator nativePlaybackWillStart];
    [coordinator nativePlaybackDidStart];
    ASSERT_TRUE(completionCalled);
    ASSERT_TRUE(!granted);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, coordinator.owner);
}

static void testOfflineToNativeEndsOfflineBeforeNativeStarts(void) {
    YTMUTestNativeAdapter *native = nil;
    YTMUTestOfflineController *offline = nil;
    YTMUPlaybackCoordinator *coordinator = MakeCoordinator(&native, &offline);
    __block BOOL granted = NO;
    [coordinator requestOfflinePlaybackWithCompletion:^(BOOL value, __unused NSError *error) {
        granted = value;
    }];
    ASSERT_TRUE(granted);
    [coordinator offlinePlaybackDidStart];
    offline.offlineSessionActive = YES;

    [coordinator nativePlaybackWillStart];
    ASSERT_EQUAL_INTEGER(1, offline.endCount);
    ASSERT_EQUAL_INTEGER(YTMUOfflineSessionEndReasonNativePlaybackStarted, offline.lastReason);
    ASSERT_TRUE(!offline.offlineSessionActive);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerTransitioning, coordinator.owner);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, coordinator.targetOwner);
    ASSERT_TRUE(!native.nativeMiniPlayerSuppressed);

    [coordinator nativePlaybackDidStart];
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, coordinator.owner);
    ASSERT_EQUAL_INTEGER(1, native.toastCount);
}

static void testOfflineEndIsIdempotent(void) {
    YTMUTestNativeAdapter *native = nil;
    YTMUTestOfflineController *offline = nil;
    YTMUPlaybackCoordinator *coordinator = MakeCoordinator(&native, &offline);
    [coordinator requestOfflinePlaybackWithCompletion:^(__unused BOOL granted, __unused NSError *error) {}];
    [coordinator offlinePlaybackDidStart];
    offline.offlineSessionActive = YES;

    [coordinator endOfflineSessionWithReason:YTMUOfflineSessionEndReasonUserStop];
    [coordinator endOfflineSessionWithReason:YTMUOfflineSessionEndReasonUserStop];

    ASSERT_EQUAL_INTEGER(1, offline.endCount);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNone, coordinator.owner);
    ASSERT_TRUE(!coordinator.offlineControlsShouldBeActive);
    ASSERT_TRUE(!native.nativeMiniPlayerSuppressed);
}

static void testNativePauseRetainsNativeOwnership(void) {
    YTMUPlaybackCoordinator *coordinator = MakeCoordinator(NULL, NULL);
    [coordinator nativePlaybackDidStart];
    [coordinator nativePlaybackDidPause];
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, coordinator.owner);
    ASSERT_TRUE(!coordinator.nativeAudioPlaying);
}

static void testUnexpectedNativeStartStillEndsOffline(void) {
    YTMUTestNativeAdapter *native = nil;
    YTMUTestOfflineController *offline = nil;
    YTMUPlaybackCoordinator *coordinator = MakeCoordinator(&native, &offline);
    [coordinator requestOfflinePlaybackWithCompletion:^(__unused BOOL granted, __unused NSError *error) {}];
    [coordinator offlinePlaybackDidStart];
    offline.offlineSessionActive = YES;

    [coordinator nativePlaybackDidStart];
    ASSERT_EQUAL_INTEGER(1, offline.endCount);
    ASSERT_EQUAL_INTEGER(YTMUPlaybackOwnerNative, coordinator.owner);
    ASSERT_TRUE(coordinator.nativeAudioPlaying);
}

int main(void) {
    @autoreleasepool {
        testPureOwnershipTransitions();
        testNativeToOfflineWaitsForConfirmedPause();
        testNativePauseFailureCancelsOfflineStart();
        testNativeStartCancelsPendingOfflineGrant();
        testOfflineToNativeEndsOfflineBeforeNativeStarts();
        testOfflineEndIsIdempotent();
        testNativePauseRetainsNativeOwnership();
        testUnexpectedNativeStartStillEndsOffline();

        if (failures != 0) {
            NSLog(@"%lu playback coordinator test(s) failed", (unsigned long)failures);
            return EXIT_FAILURE;
        }
        NSLog(@"Playback coordinator tests passed");
    }
    return EXIT_SUCCESS;
}
