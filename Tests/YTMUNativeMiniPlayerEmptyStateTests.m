#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

#import "YTMUPlaybackCoordinatorPolicy.h"
#import "YTMUObjectiveCExceptionGuard.h"

static NSUInteger failures = 0;
static char testHostAssociationKey;
#define CHECK(value) do { if (!(value)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #value); failures++; \
} } while (0)

NSNotificationName const UIApplicationDidBecomeActiveNotification = @"test-app-active";
NSNotificationName const YTMUPlaybackOwnershipDidChangeNotification = @"test-owner-changed";
NSNotificationName const YTMUNativePlaybackWillStartNotification = @"test-native-start";

@interface UIView : NSObject
@property (nonatomic, strong) NSObject *window;
@end
@implementation UIView
@end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, getter=isViewLoaded) BOOL viewLoaded;
@end
@implementation UIViewController
@end

@interface YTMGradientBackgroundView : UIView
@end
@implementation YTMGradientBackgroundView
@end
@interface YTMWatchView : UIView {
@public
    YTMGradientBackgroundView *_containerView;
    YTMGradientBackgroundView *_gradientBackgroundView;
    UIView *_containerShadowView;
}
@end
@implementation YTMWatchView
@end

@interface YTQueueController : NSObject
@property (nonatomic) unsigned long long queueCount;
@property (nonatomic, strong) id nowPlayingMusicQueueItem;
@end
@implementation YTQueueController
@end
@interface YTPlayerViewController : UIViewController
@property (nonatomic, copy) NSString *currentVideoID;
@end
@implementation YTPlayerViewController
@end
@interface YTMWatchViewController : UIViewController
@property (nonatomic, strong) id model;
@property (nonatomic, copy) NSString *activeVideoID;
@property (nonatomic, strong) YTQueueController *queueController;
@property (nonatomic, strong) YTPlayerViewController *playerViewController;
@property (nonatomic) BOOL throwOnModelRead;
@property (nonatomic) _Bool isPlaybackVideoPlaying;
@end
@implementation YTMWatchViewController
- (id)model {
    if (self.throwOnModelRead) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                      reason:@"synthetic host getter failure" userInfo:nil];
    }
    return _model;
}
@end

@interface YTMUPlaybackCoordinator : NSObject
@property (class, nonatomic, readonly) YTMUPlaybackCoordinator *sharedCoordinator;
@property (nonatomic) YTMUPlaybackOwner owner;
@end
@implementation YTMUPlaybackCoordinator
+ (instancetype)sharedCoordinator {
    static YTMUPlaybackCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ coordinator = [self new]; });
    return coordinator;
}
@end

/* YTMU_PRODUCTION_EMPTY_STATE_ADAPTER */

static void DrainMainQueue(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    }
    CHECK(done);
}

static YTMUNativePlaybackAdapter *MakeAdapter(void) {
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNone;
    YTMUNativePlaybackAdapter *adapter = [[YTMUNativePlaybackAdapter alloc] initPrivate];
    adapter.testLayoutSucceeds = YES;
    YTMWatchViewController *watch = [YTMWatchViewController new];
    watch.view = [UIView new];
    watch.view.window = [NSObject new];
    watch.viewLoaded = YES;
    watch.playerViewController = [YTPlayerViewController new];
    watch.queueController = [YTQueueController new];
    // Production references are weak; a test-owned association keeps the host alive.
    objc_setAssociatedObject(adapter, &testHostAssociationKey, watch,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    adapter.watchViewController = watch;
    adapter.playerViewController = watch.playerViewController;
    return adapter;
}

static YTMWatchViewController *Watch(YTMUNativePlaybackAdapter *adapter) {
    return (YTMWatchViewController *)adapter.watchViewController;
}

static void testColdLaunchAndDuplicateCallbacks(void) {
    YTMUNativePlaybackAdapter *adapter = MakeAdapter();
    [adapter registerWatchViewController:Watch(adapter)];
    [adapter registerMiniPlayerViewController:[UIViewController new]];
    [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 1);
    CHECK(adapter.nativeMiniPlayerVisualShellCollapsed);
    [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 1);
}

static void testForegroundRechecksAnEmptyHost(void) {
    YTMUNativePlaybackAdapter *adapter = MakeAdapter();
    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidBecomeActiveNotification
                                                      object:nil];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 1);
}

static void testModelVideoAndQueueEachPreserveThePlayer(void) {
    for (NSUInteger content = 0; content < 5; content++) {
        YTMUNativePlaybackAdapter *adapter = MakeAdapter();
        YTMWatchViewController *watch = Watch(adapter);
        if (content == 0) watch.model = [NSObject new];
        if (content == 1) watch.activeVideoID = @"restored-video";
        if (content == 2) watch.queueController.queueCount = 2;
        if (content == 3) watch.queueController.nowPlayingMusicQueueItem = [NSObject new];
        if (content == 4) watch.playerViewController.currentVideoID = @"paused-video";
        adapter.nativeMiniPlayerVisualShellCollapsed = YES;
        [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
        DrainMainQueue();
        CHECK(adapter.testCollapseCount == 0);
        CHECK(!adapter.nativeMiniPlayerVisualShellCollapsed);
        if (content == 2) CHECK(watch.queueController.queueCount == 2);
    }
}

static void testOwnershipAndAudibilityCannotBeOverridden(void) {
    for (YTMUPlaybackOwner owner = YTMUPlaybackOwnerNone;
         owner <= YTMUPlaybackOwnerTransitioning; owner++) {
        for (NSUInteger audible = 0; audible < 2; audible++) {
            for (NSUInteger suppressed = 0; suppressed < 2; suppressed++) {
                YTMUNativePlaybackAdapter *adapter = MakeAdapter();
                YTMUPlaybackCoordinator.sharedCoordinator.owner = owner;
                adapter.nativePlaybackAudible = audible;
                adapter.miniPlayerSuppressed = suppressed;
                [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
                DrainMainQueue();
                BOOL canCollapse = owner == YTMUPlaybackOwnerNone && !audible && !suppressed;
                CHECK(adapter.testCollapseCount == (canCollapse ? 1 : 0));
                CHECK(YTMUPlaybackCoordinator.sharedCoordinator.owner == owner);
                CHECK(adapter.nativePlaybackAudible == (BOOL)audible);
            }
        }
    }
}

static void testLateNativePlaybackInvalidatesThePendingCollapse(void) {
    YTMUNativePlaybackAdapter *adapter = MakeAdapter();
    [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    [adapter prepareNativeMiniPlayerForPlaybackStart];
    Watch(adapter).model = [NSObject new];
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNative;
    DrainMainQueue();
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 0);
    CHECK(!adapter.nativeMiniPlayerVisualShellCollapsed);
}

static void testSessionEndAndReappearingLayout(void) {
    YTMUNativePlaybackAdapter *adapter = MakeAdapter();
    [adapter nativePlaybackSessionDidEnd];
    [adapter nativePlaybackSessionDidEnd];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 1);
    adapter.testGeometryCollapsed = NO;
    [adapter registerMiniPlayerViewController:[UIViewController new]];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 2);
    [adapter prepareNativeMiniPlayerForPlaybackStart];
    CHECK(!adapter.nativeMiniPlayerVisualShellCollapsed);
}

static void testOfflineReleaseRechecksOnlyAnEmptyQueue(void) {
    for (NSUInteger hasQueue = 0; hasQueue < 2; hasQueue++) {
        YTMUNativePlaybackAdapter *adapter = MakeAdapter();
        adapter.miniPlayerSuppressed = YES;
        Watch(adapter).queueController.queueCount = hasQueue;
        [adapter setNativeMiniPlayerSuppressed:NO];
        DrainMainQueue();
        CHECK(adapter.testCollapseCount == (hasQueue ? 0 : 1));
        CHECK(Watch(adapter).queueController.queueCount == hasQueue);
    }
}

static void testUnknownDetachedAndThrowingHostsStayUnchanged(void) {
    for (NSUInteger failure = 0; failure < 4; failure++) {
        YTMUNativePlaybackAdapter *adapter = MakeAdapter();
        if (failure == 0) adapter.watchViewController = nil;
        if (failure == 1) Watch(adapter).view.window = nil;
        if (failure == 2) Watch(adapter).throwOnModelRead = YES;
        if (failure == 3) Watch(adapter).isPlaybackVideoPlaying = YES;
        [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
        DrainMainQueue();
        CHECK(adapter.testCollapseCount == 0);
        CHECK(!adapter.nativeMiniPlayerVisualShellCollapsed);
    }
}

static long long WrongQueueCount(__unused id self, __unused SEL selector) { return 0; }
static void testIncompatiblePrivateGetterIsNotInvoked(void) {
    Class wrongABI = objc_allocateClassPair(YTQueueController.class, "YTMUWrongQueueCountABI", 0);
    CHECK(wrongABI != Nil);
    CHECK(class_addMethod(wrongABI, @selector(queueCount), (IMP)WrongQueueCount, "q16@0:8"));
    objc_registerClassPair(wrongABI);
    YTMUNativePlaybackAdapter *adapter = MakeAdapter();
    Watch(adapter).queueController = [wrongABI new];
    [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 0);
}

static void testColdShellMayLackOptionalBackgrounds(void) {
    YTMUNativePlaybackAdapter *adapter = MakeAdapter();
    YTMWatchView *view = [YTMWatchView new];
    view->_containerView = [YTMGradientBackgroundView new];
    NSError *error = nil;
    NSArray *shells = [adapter nativeMiniPlayerVisualShellViewsForWatchView:view error:&error];
    CHECK(shells.count == 1);
    CHECK(error == nil);
    view->_containerView = nil;
    CHECK([adapter nativeMiniPlayerVisualShellViewsForWatchView:view error:&error] == nil);
}

static void testLayoutFailureAndReentryAreContained(void) {
    YTMUNativePlaybackAdapter *adapter = MakeAdapter();
    adapter.testLayoutReenters = YES;
    adapter.testLayoutThrows = YES;
    [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 1);
    CHECK(!adapter.nativeMiniPlayerVisualShellCollapsed);
    adapter.testLayoutThrows = NO;
    [adapter scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    DrainMainQueue();
    CHECK(adapter.testCollapseCount == 2);
    CHECK(adapter.nativeMiniPlayerVisualShellCollapsed);
}

int main(void) {
    @autoreleasepool {
        testColdLaunchAndDuplicateCallbacks();
        testForegroundRechecksAnEmptyHost();
        testModelVideoAndQueueEachPreserveThePlayer();
        testOwnershipAndAudibilityCannotBeOverridden();
        testLateNativePlaybackInvalidatesThePendingCollapse();
        testSessionEndAndReappearingLayout();
        testOfflineReleaseRechecksOnlyAnEmptyQueue();
        testUnknownDetachedAndThrowingHostsStayUnchanged();
        testIncompatiblePrivateGetterIsNotInvoked();
        testColdShellMayLackOptionalBackgrounds();
        testLayoutFailureAndReentryAreContained();
        if (failures) {
            fprintf(stderr, "Native empty-state tests failed: %lu assertions\n", (unsigned long)failures);
            return 1;
        }
        puts("Native empty-state tests passed (11 scenario groups; actual adapter lifecycle/getters)");
    }
    return 0;
}
