#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "YTMUPlaybackCoordinatorPolicy.h"

static int failures;
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); failures++; \
} } while (0)

// Deliberately minimal doubles: these test native property ownership and stale
// callbacks, not UIKit view hierarchy, gesture delivery, or real rendering.
@interface YTMUTestLayer : NSObject
@property (nonatomic) float opacity;
@property (nonatomic) NSUInteger opacityWriteCount;
- (void)removeAllAnimations;
@end
@implementation YTMUTestLayer
- (instancetype)init { if ((self = [super init])) _opacity = 1; return self; }
- (void)setOpacity:(float)value { _opacity = value; _opacityWriteCount++; }
- (void)removeAllAnimations {}
@end

@class UIWindow;
static BOOL deferAnimations;
static void (^deferredCompletion)(BOOL);
enum { UIViewAnimationOptionBeginFromCurrentState = 1, UIViewAnimationOptionCurveEaseOut = 2 };
static const NSTimeInterval YTMUNativeSwipeRestoreDuration = 0.22;

@interface UIView : NSObject
@property (nonatomic) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) CGAffineTransform transform;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nonatomic) CGRect bounds;
@property (nonatomic) CGRect frame;
@property (nonatomic, strong) YTMUTestLayer *layer;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, weak) UIWindow *window;
+ (void)performWithoutAnimation:(void (^)(void))actions;
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay
                   options:(NSUInteger)options animations:(void (^)(void))animations
                completion:(void (^)(BOOL))completion;
- (void)removeFromSuperview;
- (BOOL)isDescendantOfView:(UIView *)view;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) {
        _alpha = 1; _transform = CGAffineTransformIdentity; _userInteractionEnabled = YES;
        _layer = [YTMUTestLayer new]; _bounds = CGRectMake(0, 0, 390, 64);
    }
    return self;
}
+ (void)performWithoutAnimation:(void (^)(void))actions { actions(); }
+ (void)animateWithDuration:(__unused NSTimeInterval)duration delay:(__unused NSTimeInterval)delay
                   options:(__unused NSUInteger)options animations:(void (^)(void))animations
                completion:(void (^)(BOOL))completion {
    animations();
    if (deferAnimations) deferredCompletion = [completion copy];
    else completion(YES);
}
- (void)removeFromSuperview { self.superview = nil; }
- (BOOL)isDescendantOfView:(UIView *)view {
    for (UIView *candidate = self; candidate != nil; candidate = candidate.superview) {
        if (candidate == view) return YES;
    }
    return NO;
}
@end
@interface UIWindow : UIView @end
@implementation UIWindow @end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *view;
@end
@implementation UIViewController @end
@interface UIPanGestureRecognizer : NSObject
@property (nonatomic) BOOL enabled;
@end
@implementation UIPanGestureRecognizer @end

@interface YTMUPlaybackCoordinator : NSObject
@property (nonatomic) YTMUPlaybackOwner owner;
+ (instancetype)sharedCoordinator;
@end
@implementation YTMUPlaybackCoordinator
+ (instancetype)sharedCoordinator {
    static YTMUPlaybackCoordinator *value; if (!value) value = [self new]; return value;
}
@end
@interface YTMUNativePlaybackAdapter : NSObject
@property (nonatomic) BOOL nativeMiniPlayerSuppressed;
@property (nonatomic) BOOL nativeMiniPlayerVisualShellCollapsed;
+ (instancetype)sharedAdapter;
@end
@implementation YTMUNativePlaybackAdapter
+ (instancetype)sharedAdapter {
    static YTMUNativePlaybackAdapter *value; if (!value) value = [self new]; return value;
}
@end

static void YTMUSetNativeMiniPlayerViewsLayerOpacity(NSArray<UIView *> *views, float opacity) {
    for (UIView *view in views) view.layer.opacity = opacity;
}

/* YTMU_PRODUCTION_HANDLER */

@interface YTMUTestFixture : NSObject
@property (nonatomic, strong) UIViewController *controller;
@property (nonatomic, strong) UIView *root;
@property (nonatomic, strong) UIView *mini;
@property (nonatomic, strong) YTMUNativeMiniPlayerSwipeHandler *handler;
@end
@implementation YTMUTestFixture @end

static YTMUTestFixture *fixture(void) {
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNative;
    YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerSuppressed = NO;
    YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerVisualShellCollapsed = NO;
    deferAnimations = NO; deferredCompletion = nil;
    YTMUTestFixture *f = [YTMUTestFixture new];
    f.root = [UIView new]; f.mini = [UIView new]; f.mini.superview = f.root;
    f.controller = [UIViewController new]; f.controller.view = f.root;
    f.handler = [YTMUNativeMiniPlayerSwipeHandler new];
    f.handler.miniPlayerController = f.controller;
    f.handler.visualRootView = f.root; f.handler.miniPlayerView = f.mini;
    // Seed only legacy constructor snapshots that exist in the tested source.
    NSDictionary *legacy = @{@"visualRootOriginalHidden": @NO,
                             @"visualRootOriginalAlpha": @1,
                             @"visualRootOriginalInteractionEnabled": @YES,
                             @"visualRootOriginalLayerOpacity": @1};
    for (NSString *key in legacy) {
        if ([f.handler respondsToSelector:NSSelectorFromString(key)]) {
            [f.handler setValue:legacy[key] forKey:key];
        }
    }
    if ([f.handler respondsToSelector:NSSelectorFromString(@"visualRootOriginalTransform")]) {
        CGAffineTransform identity = CGAffineTransformIdentity;
        [f.handler setValue:[NSValue valueWithBytes:&identity objCType:@encode(CGAffineTransform)]
                    forKey:@"visualRootOriginalTransform"];
    }
    return f;
}

static void testFirstLaunchCallbacksLeaveNativeFullscreenOpacityAlone(void) {
    YTMUTestFixture *f = fixture();
    f.root.layer.opacity = 0; f.root.layer.opacityWriteCount = 0;
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNone;
    [f.handler nativePlaybackWillStart:nil];
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNative;
    [f.handler playbackOwnershipDidChange:nil];
    [f.handler prepareForPresentation];
    CHECK(f.root.layer.opacity == 0);
    CHECK(f.root.layer.opacityWriteCount == 0);
}

static void testFailedBeginCleanupDoesNotRestoreConstructorState(void) {
    YTMUTestFixture *f = fixture();
    f.root.hidden = YES; f.root.alpha = 0.25; f.root.userInteractionEnabled = NO;
    f.root.transform = CGAffineTransformMakeTranslation(8, 19);
    f.root.layer.opacity = 0; f.root.layer.opacityWriteCount = 0;
    [f.handler restoreSwipeAnimated:NO];
    CHECK(f.root.hidden && f.root.alpha == 0.25 && !f.root.userInteractionEnabled);
    CHECK(CGAffineTransformEqualToTransform(f.root.transform, CGAffineTransformMakeTranslation(8, 19)));
    CHECK(f.root.layer.opacity == 0 && f.root.layer.opacityWriteCount == 0);
}

static void testSwipeCancellationRestoresOnlyTheOpacityItChanged(void) {
    YTMUTestFixture *f = fixture();
    f.root.layer.opacity = 0.7f;
    [f.handler coverNativeViews:@[f.root, f.mini]];
    CHECK(f.root.layer.opacity == 0 && f.mini.layer.opacity == 0);
    f.root.hidden = YES; f.root.alpha = 0.3; f.root.userInteractionEnabled = NO;
    f.root.transform = CGAffineTransformMakeTranslation(7, 11);
    [f.handler restoreSwipeAnimated:NO];
    CHECK(f.root.layer.opacity == 0.7f && f.mini.layer.opacity == 1);
    CHECK(f.root.hidden && f.root.alpha == 0.3 && !f.root.userInteractionEnabled);
    CHECK(CGAffineTransformEqualToTransform(f.root.transform, CGAffineTransformMakeTranslation(7, 11)));
    CHECK(f.handler.coveredNativeViews.count == 0);
}

static void testLaterNativeOpacityWriteWinsOverOldOverride(void) {
    YTMUTestFixture *f = fixture();
    [f.handler coverNativeViews:@[f.root]];
    f.root.layer.opacity = 0.35f;
    [f.handler restoreCoveredNativeViews];
    CHECK(f.root.layer.opacity == 0.35f);
}

static void testDuplicateCleanupCannotResurrectAnEmptyShell(void) {
    YTMUTestFixture *f = fixture();
    [f.handler coverNativeViews:@[f.root]];
    [f.handler restoreSwipeAnimated:NO];
    f.root.layer.opacity = 0; f.root.layer.opacityWriteCount = 0;
    [f.handler prepareForPresentation];
    [f.handler nativePlaybackWillStart:nil];
    [f.handler restoreSwipeAnimated:NO];
    CHECK(f.root.layer.opacity == 0 && f.root.layer.opacityWriteCount == 0);
}

static void testStaleAnimationCompletionCannotOverwriteANewSession(void) {
    YTMUTestFixture *f = fixture();
    [f.handler coverNativeViews:@[f.root]];
    f.handler.animationSnapshot = [UIView new];
    f.handler.animationOriginalAlpha = 1;
    f.handler.animationOriginalTransform = CGAffineTransformIdentity;
    deferAnimations = YES;
    [f.handler restoreSwipeAnimated:YES];
    void (^oldCompletion)(BOOL) = deferredCompletion;
    CHECK(oldCompletion != nil);
    [f.handler nativePlaybackWillStart:nil];
    f.root.layer.opacity = 0; f.root.layer.opacityWriteCount = 0;
    oldCompletion(YES);
    CHECK(f.root.layer.opacity == 0 && f.root.layer.opacityWriteCount == 0);
    CHECK(f.handler.animationSnapshot == nil);
    deferAnimations = NO; deferredCompletion = nil;
}

static void testAlreadyHiddenOpacityIsNotClaimedByTheSwipe(void) {
    YTMUTestFixture *f = fixture();
    f.root.layer.opacity = 0; f.root.layer.opacityWriteCount = 0;
    [f.handler coverNativeViews:@[f.root]];
    CHECK(f.handler.coveredNativeViews.count == 0);
    [f.handler nativePlaybackWillStart:nil];
    CHECK(f.root.layer.opacity == 0 && f.root.layer.opacityWriteCount == 0);
}

static void testDuplicateCoverKeepsTheImmediatePreOverrideValue(void) {
    YTMUTestFixture *f = fixture();
    f.root.layer.opacity = 0.6f;
    [f.handler coverNativeViews:@[f.root]];
    [f.handler coverNativeViews:@[f.root, f.mini]];
    CHECK(f.handler.coveredNativeViews.count == 2);
    [f.handler restoreCoveredNativeViews];
    CHECK(f.root.layer.opacity == 0.6f && f.mini.layer.opacity == 1);
}

static void testOldVisualGenerationCannotRestoreOpacity(void) {
    YTMUTestFixture *f = fixture();
    [f.handler coverNativeViews:@[f.root]];
    f.handler.nativeVisualGeneration++;
    f.root.layer.opacityWriteCount = 0;
    [f.handler restoreCoveredNativeViews];
    CHECK(f.root.layer.opacity == 0 && f.root.layer.opacityWriteCount == 0);
    CHECK(f.handler.coveredNativeViews.count == 0);
}

static void testReplacedRootIsNotTouchedByOldHandler(void) {
    YTMUTestFixture *f = fixture();
    [f.handler coverNativeViews:@[f.root]];
    UIView *replacement = [UIView new];
    replacement.layer.opacity = 0.2f; replacement.layer.opacityWriteCount = 0;
    f.controller.view = replacement;
    f.root.layer.opacityWriteCount = 0;
    [f.handler restoreSwipeAnimated:NO];
    CHECK(f.root.layer.opacityWriteCount == 0);
    CHECK(replacement.layer.opacity == 0.2f && replacement.layer.opacityWriteCount == 0);
    CHECK(f.handler.coveredNativeViews.count == 0);
}

static void testInteractionRestoresOnlyAnOwnedDisable(void) {
    YTMUTestFixture *f = fixture();
    f.root.userInteractionEnabled = NO;
    [f.handler disableInteractionAfterFailedCollapse];
    CHECK(!f.handler.interactionDisabledAfterFailedCollapse);
    [f.handler restoreOwnedInteraction];
    CHECK(!f.root.userInteractionEnabled);

    f.root.userInteractionEnabled = YES;
    [f.handler disableInteractionAfterFailedCollapse];
    CHECK(!f.root.userInteractionEnabled && f.handler.interactionDisabledAfterFailedCollapse);
    [f.handler restoreOwnedInteraction];
    CHECK(f.root.userInteractionEnabled && !f.handler.interactionDisabledAfterFailedCollapse);
    f.root.userInteractionEnabled = NO;
    [f.handler restoreOwnedInteraction];
    CHECK(!f.root.userInteractionEnabled);
}

static void testInteractionRestoreWaitsForOfflineSuppressionToEnd(void) {
    YTMUTestFixture *f = fixture();
    [f.handler disableInteractionAfterFailedCollapse];
    YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerSuppressed = YES;
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerOffline;
    [f.handler nativePlaybackWillStart:nil];
    CHECK(!f.root.userInteractionEnabled && f.handler.interactionDisabledAfterFailedCollapse);
    YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerSuppressed = NO;
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNative;
    [f.handler playbackOwnershipDidChange:nil];
    CHECK(f.root.userInteractionEnabled && !f.handler.interactionDisabledAfterFailedCollapse);
}

static void testStaleInteractionRestoreDoesNotTouchNewPresentation(void) {
    YTMUTestFixture *f = fixture();
    [f.handler disableInteractionAfterFailedCollapse];
    f.handler.nativeVisualGeneration++;
    [f.handler restoreOwnedInteraction];
    CHECK(!f.root.userInteractionEnabled && !f.handler.interactionDisabledAfterFailedCollapse);
}

static void testConfirmedEmptyCoverRestoresOnlyBeforeNewNativePlayback(void) {
    YTMUTestFixture *f = fixture();
    [f.handler coverConfirmedEmptyShell];
    CHECK(f.handler.coveredNativeViews.count == 0);
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNone;
    YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerVisualShellCollapsed = YES;
    f.root.layer.opacity = 0.8f;
    [f.handler coverConfirmedEmptyShell];
    [f.handler coverConfirmedEmptyShell];
    CHECK(f.root.layer.opacity == 0 && f.handler.coveredNativeViews.count == 1);
    [f.handler restoreSwipeAnimated:NO];
    CHECK(f.root.layer.opacity == 0);
    YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerVisualShellCollapsed = NO;
    [f.handler nativePlaybackWillStart:nil];
    CHECK(f.root.layer.opacity == 0.8f && f.handler.coveredNativeViews.count == 0);
    // Native fullscreen owns the subsequent zero; a post-start callback must
    // not interpret that change as another handler-owned override.
    f.root.layer.opacity = 0; f.root.layer.opacityWriteCount = 0;
    [f.handler nativePlaybackWillStart:nil];
    YTMUPlaybackCoordinator.sharedCoordinator.owner = YTMUPlaybackOwnerNative;
    [f.handler playbackOwnershipDidChange:nil];
    CHECK(f.root.layer.opacity == 0 && f.root.layer.opacityWriteCount == 0);
}

int main(void) {
    @autoreleasepool {
        testFirstLaunchCallbacksLeaveNativeFullscreenOpacityAlone();
        testFailedBeginCleanupDoesNotRestoreConstructorState();
        testSwipeCancellationRestoresOnlyTheOpacityItChanged();
        testLaterNativeOpacityWriteWinsOverOldOverride();
        testDuplicateCleanupCannotResurrectAnEmptyShell();
        testStaleAnimationCompletionCannotOverwriteANewSession();
        testAlreadyHiddenOpacityIsNotClaimedByTheSwipe();
        testDuplicateCoverKeepsTheImmediatePreOverrideValue();
        testOldVisualGenerationCannotRestoreOpacity();
        testReplacedRootIsNotTouchedByOldHandler();
        testInteractionRestoresOnlyAnOwnedDisable();
        testInteractionRestoreWaitsForOfflineSuppressionToEnd();
        testStaleInteractionRestoreDoesNotTouchNewPresentation();
        testConfirmedEmptyCoverRestoresOnlyBeforeNewNativePlayback();
        if (failures) { fprintf(stderr, "%d native visual-state assertion(s) failed\n", failures); return 1; }
        puts("Native mini-player visual-state tests passed (14 scenarios)");
    }
    return 0;
}
