#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

#import "YTMUMiniPlayerSwipePolicy.h"
#import "YTMUObjectiveCExceptionGuard.h"

static int failures;
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); failures++; \
} } while (0)
static const CGFloat YTMUNativeVisualGeometryTolerance = 1.0;
static double nativeMinimizedHeight = 64.0;

// These doubles model attachment, named native ivars and rectangle conversion,
// not UIKit hit testing, rendering, animation or real server configuration.
@class UIWindow;
@interface UIView : NSObject
@property (nonatomic) CGRect frame;
@property (nonatomic) CGRect bounds;
@property (nonatomic) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nonatomic) CGAffineTransform transform;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, weak) UIWindow *window;
- (BOOL)isDescendantOfView:(UIView *)view;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) {
        _alpha = 1.0;
        _userInteractionEnabled = YES;
        _transform = CGAffineTransformIdentity;
    }
    return self;
}
- (BOOL)isDescendantOfView:(UIView *)view {
    for (UIView *candidate = self; candidate != nil; candidate = candidate.superview) {
        if (candidate == view) return YES;
    }
    return NO;
}
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view {
    // Fixtures use the same window and untransformed native frames. Production
    // performs this conversion with UIKit; no crop decision is mocked here.
    for (UIView *candidate = self; candidate != nil && candidate != view;
         candidate = candidate.superview) {
        rect.origin.x += candidate.frame.origin.x - candidate.bounds.origin.x;
        rect.origin.y += candidate.frame.origin.y - candidate.bounds.origin.y;
    }
    return rect;
}
@end
@interface UIWindow : UIView @end
@implementation UIWindow @end
@interface UITabBar : UIView @end
@implementation UITabBar @end
@interface YTPivotBarView : UIView @end
@implementation YTPivotBarView @end
@interface YTMGradientBackgroundView : UIView @end
@implementation YTMGradientBackgroundView @end
@interface YTMMiniPlayerView : UIView @end
@implementation YTMMiniPlayerView @end

@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, getter=isViewLoaded) BOOL viewLoaded;
@end
@implementation UIViewController @end

// The ivar names and encodings match the inspected 9.14.2 Mach-O. Its
// -initWithColorScheme: allocates _gradientBackgroundView only when the native
// split-view configuration is enabled; _containerView exists in both modes.
@interface YTMWatchView : UIView {
@public
    YTMGradientBackgroundView *_containerView;
    YTMGradientBackgroundView *_gradientBackgroundView;
    UIView *_containerShadowView;
    UIView *_frostedGlassView;
}
@property (nonatomic, strong) YTMMiniPlayerView *miniPlayerView;
@property (nonatomic, strong) YTPivotBarView *pivotBarView;
+ (double)minimizedPlayerHeight;
@end
@implementation YTMWatchView
+ (double)minimizedPlayerHeight { return nativeMinimizedHeight; }
@end
@interface YTMWatchViewController : UIViewController
@property (nonatomic, strong) YTMWatchView *watchView;
@end
@implementation YTMWatchViewController @end
@interface YTMMiniPlayerViewController : UIViewController
@property (nonatomic, weak) YTMWatchViewController *parentResponder;
@end
@implementation YTMMiniPlayerViewController @end

/* YTMU_PRODUCTION_VISUAL_CONTEXT */

@interface YTMUContextFixture : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) YTMWatchViewController *watchController;
@property (nonatomic, strong) YTMMiniPlayerViewController *miniController;
@end
@implementation YTMUContextFixture @end

static void attach(UIView *view, UIView *parent, UIWindow *window, CGRect frame) {
    view.frame = frame;
    view.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    view.superview = parent;
    view.window = window;
}

static YTMUContextFixture *fixture(BOOL splitView) {
    nativeMinimizedHeight = 64.0;
    YTMUContextFixture *f = [YTMUContextFixture new];
    f.window = [UIWindow new];
    f.window.frame = f.window.bounds = CGRectMake(0, 0, 390, 844);
    f.window.window = f.window;
    f.watchController = [YTMWatchViewController new];
    YTMWatchView *watch = [YTMWatchView new];
    f.watchController.watchView = watch;
    attach(watch, f.window, f.window, f.window.bounds);
    watch->_containerView = [YTMGradientBackgroundView new];
    attach(watch->_containerView, watch, f.window, CGRectMake(0, 697, 390, 64));
    watch->_containerShadowView = [UIView new];
    attach(watch->_containerShadowView, watch, f.window, CGRectMake(0, 697, 390, 64));
    if (splitView) {
        watch->_gradientBackgroundView = [YTMGradientBackgroundView new];
        attach(watch->_gradientBackgroundView, watch, f.window, CGRectMake(0, 697, 390, 64));
    }
    watch.pivotBarView = [YTPivotBarView new];
    attach(watch.pivotBarView, watch, f.window, CGRectMake(0, 761, 390, 83));
    watch.miniPlayerView = [YTMMiniPlayerView new];
    attach(watch.miniPlayerView, watch->_containerView, f.window, CGRectMake(0, 0, 390, 64));
    f.miniController = [YTMMiniPlayerViewController new];
    f.miniController.viewLoaded = YES;
    f.miniController.view = watch.miniPlayerView;
    f.miniController.parentResponder = f.watchController;
    return f;
}

static YTMUNativeMiniPlayerVisualContext *resolve(YTMUContextFixture *f, NSString **reason) {
    return YTMUResolveNativeMiniPlayerVisualContext(
        f.miniController, f.watchController.watchView.miniPlayerView, reason);
}

static void checkValidCard(YTMUContextFixture *f) {
    NSString *reason = nil;
    YTMUNativeMiniPlayerVisualContext *context = resolve(f, &reason);
    CHECK(context != nil);
    CHECK(reason == nil);
    if (context == nil) return;
    YTMWatchView *watch = f.watchController.watchView;
    CHECK(CGRectEqualToRect(context.cardFrameInWindow, CGRectMake(0, 697, 390, 64)));
    CHECK([context.visualParticipants containsObject:watch->_containerView]);
    CHECK([context.visualParticipants containsObject:watch.miniPlayerView]);
    CHECK(![context.visualParticipants containsObject:watch]);
    CHECK(![context.visualParticipants containsObject:f.window]);
    CHECK(![context.visualParticipants containsObject:watch.pivotBarView]);
    CHECK(!CGRectIntersectsRect(context.cardFrameInWindow, watch.pivotBarView.frame));
}

static void coldAndWarmNativeConfigurations(void) {
    for (int split = 0; split < 2; split++) {
        YTMUContextFixture *f = fixture(split != 0);
        YTMWatchView *watch = f.watchController.watchView;
        CHECK((watch->_gradientBackgroundView != nil) == (split != 0));
        CHECK(watch->_frostedGlassView == nil);
        checkValidCard(f);
        // Repeated resolution must need neither process restart nor cached UI.
        checkValidCard(f);
        CHECK(!watch.hidden && watch.alpha == 1 && watch.userInteractionEnabled);
        CHECK(CGAffineTransformIsIdentity(watch.transform));
        CHECK(!watch.pivotBarView.hidden && watch.pivotBarView.alpha == 1);
    }
}

static void optionalLayersNeverExpandCard(void) {
    YTMUContextFixture *f = fixture(YES);
    YTMWatchView *watch = f.watchController.watchView;
    attach(watch->_gradientBackgroundView, watch, f.window, f.window.bounds);
    watch->_frostedGlassView = [UIView new];
    attach(watch->_frostedGlassView, watch, f.window, f.window.bounds);
    checkValidCard(f);
    YTMUNativeMiniPlayerVisualContext *context = resolve(f, NULL);
    CHECK(![context.visualParticipants containsObject:watch->_gradientBackgroundView]);
    CHECK(![context.visualParticipants containsObject:watch->_frostedGlassView]);
    CHECK(watch->_gradientBackgroundView.alpha == 1);
    CHECK(watch->_frostedGlassView.alpha == 1);
}

static void missingRequiredViewsStillReject(void) {
    for (int missing = 0; missing < 3; missing++) {
        YTMUContextFixture *f = fixture(YES);
        YTMWatchView *watch = f.watchController.watchView;
        if (missing == 0) watch->_containerView = nil;
        if (missing == 1) watch->_containerShadowView = nil;
        if (missing == 2) watch.pivotBarView = nil;
        NSString *reason = nil;
        CHECK(resolve(f, &reason) == nil);
        CHECK([reason isEqualToString:@"native-layout-views-unavailable"]);
    }
}

static void invalidGeometryStillRejects(void) {
    const CGRect invalidFrames[] = {
        {{0, 0}, {390, 844}}, {{0, 20}, {390, 741}},
        {{0, 670}, {390, 64}}, {{0, 710}, {390, 64}},
    };
    for (NSUInteger i = 0; i < sizeof(invalidFrames) / sizeof(invalidFrames[0]); i++) {
        YTMUContextFixture *f = fixture(YES);
        YTMWatchView *watch = f.watchController.watchView;
        attach(watch->_containerView, watch, f.window, invalidFrames[i]);
        NSString *reason = nil;
        CHECK(resolve(f, &reason) == nil);
        CHECK([reason isEqualToString:@"card-height-or-pivot-adjacency"]);
    }
}

static void firstLayoutCanBecomeReadyWithoutRestart(void) {
    YTMUContextFixture *f = fixture(NO);
    YTMWatchView *watch = f.watchController.watchView;
    attach(watch->_containerView, watch, f.window, CGRectZero);
    CHECK(resolve(f, NULL) == nil);
    attach(watch->_containerView, watch, f.window, CGRectMake(0, 697, 390, 64));
    checkValidCard(f);
}

static void viewIdentityAndAttachmentStillRequired(void) {
    YTMUContextFixture *f = fixture(YES);
    f.miniController.view = [UIView new];
    NSString *reason = nil;
    CHECK(resolve(f, &reason) == nil);
    CHECK([reason isEqualToString:@"controller-root-identity"]);
    f = fixture(YES);
    f.watchController.watchView.window = nil;
    CHECK(resolve(f, &reason) == nil);
    CHECK([reason isEqualToString:@"window-not-attached"]);
    f = fixture(YES);
    f.watchController.watchView.pivotBarView.hidden = YES;
    CHECK(resolve(f, &reason) == nil);
    CHECK([reason isEqualToString:@"native-layout-views-unavailable"]);
}

static void oversizedMiniBoundsDoNotDefineCrop(void) {
    YTMUContextFixture *f = fixture(NO);
    YTMWatchView *watch = f.watchController.watchView;
    attach(watch.miniPlayerView, watch->_containerView, f.window, CGRectMake(0, 0, 390, 844));
    checkValidCard(f);
}

static void invalidNativeHeightStillRejects(void) {
    YTMUContextFixture *f = fixture(YES);
    nativeMinimizedHeight = NAN;
    NSString *reason = nil;
    CHECK(resolve(f, &reason) == nil);
    CHECK([reason isEqualToString:@"minimized-height-abi"]);
    nativeMinimizedHeight = 800;
    CHECK(resolve(f, &reason) == nil);
    CHECK([reason isEqualToString:@"card-height-or-pivot-adjacency"]);
    nativeMinimizedHeight = 64;
}

int main(void) {
    @autoreleasepool {
        coldAndWarmNativeConfigurations();
        optionalLayersNeverExpandCard();
        missingRequiredViewsStillReject();
        invalidGeometryStillRejects();
        firstLayoutCanBecomeReadyWithoutRestart();
        viewIdentityAndAttachmentStillRequired();
        oversizedMiniBoundsDoNotDefineCrop();
        invalidNativeHeightStillRejects();
        if (failures != 0) return 1;
        printf("Native visual-context tests passed (8 scenario groups; actual resolver, no UIKit host)\n");
    }
    return 0;
}
