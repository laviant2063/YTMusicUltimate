#import "YTMUNativeMiniPlayerSwipeController.h"

#import <objc/message.h>
#import <objc/runtime.h>

#include <math.h>
#include <string.h>

#import "YTMUMiniPlayerSwipePolicy.h"
#import "YTMUNativePlaybackAdapter.h"
#import "YTMUObjectiveCExceptionGuard.h"
#import "YTMUPlaybackCoordinator.h"
#import "../Headers/Localization.h"

static const NSTimeInterval YTMUNativeSwipeRestoreDuration = 0.22;
static const NSTimeInterval YTMUNativeSwipeCommitDuration = 0.18;
static const CGFloat YTMUNativeSwipeMaximumFade = 0.35;
static const CGFloat YTMUNativeSwipeFinishPadding = 12.0;
static const CGFloat YTMUNativeVisualGeometryTolerance = 1.0;
static char YTMUNativeMiniPlayerSwipeAssociationKey;

static NSString *YTMUNativeSwipeLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

static void YTMUSetNativeMiniPlayerViewsLayerOpacity(NSArray<UIView *> *views,
                                                     float opacity) {
    [UIView performWithoutAnimation:^{
        for (UIView *view in views) {
            view.layer.opacity = opacity;
        }
    }];
}

static BOOL YTMURectsEqualWithinTolerance(CGRect lhs, CGRect rhs) {
    return fabs(CGRectGetMinX(lhs) - CGRectGetMinX(rhs)) <= YTMUNativeVisualGeometryTolerance
        && fabs(CGRectGetMinY(lhs) - CGRectGetMinY(rhs)) <= YTMUNativeVisualGeometryTolerance
        && fabs(CGRectGetWidth(lhs) - CGRectGetWidth(rhs)) <= YTMUNativeVisualGeometryTolerance
        && fabs(CGRectGetHeight(lhs) - CGRectGetHeight(rhs)) <= YTMUNativeVisualGeometryTolerance;
}

static BOOL YTMURectIsFiniteAndVisible(CGRect rect) {
    return !CGRectIsNull(rect)
        && !CGRectIsInfinite(rect)
        && !CGRectIsEmpty(rect)
        && isfinite(CGRectGetMinX(rect))
        && isfinite(CGRectGetMinY(rect))
        && isfinite(CGRectGetWidth(rect))
        && isfinite(CGRectGetHeight(rect));
}

static BOOL YTMUMethodHasEncoding(id object, SEL selector, const char *expectedEncoding) {
    if (object == nil || selector == NULL || ![object respondsToSelector:selector]) return NO;
    Method method = class_getInstanceMethod([object class], selector);
    const char *encoding = method == NULL ? NULL : method_getTypeEncoding(method);
    return encoding != NULL && strcmp(encoding, expectedEncoding) == 0;
}

static id YTMUObjectReturnedByVerifiedSelector(id object,
                                                NSString *selectorName,
                                                Class expectedClass) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!YTMUMethodHasEncoding(object, selector, "@16@0:8")) return nil;
    __block id resolvedObject = nil;
    BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
        id (*sendObject)(id, SEL) = (void *)objc_msgSend;
        resolvedObject = sendObject(object, selector);
    }, NULL);
    return resolvedSafely
        && resolvedObject != nil
        && (expectedClass == Nil || [resolvedObject isKindOfClass:expectedClass])
        ? resolvedObject
        : nil;
}

static BOOL YTMUClassDoubleReturnedByVerifiedSelector(Class objectClass,
                                                       NSString *selectorName,
                                                       double *resolvedValue) {
    if (objectClass == Nil || resolvedValue == NULL) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(objectClass, selector);
    const char *encoding = method == NULL ? NULL : method_getTypeEncoding(method);
    if (encoding == NULL || strcmp(encoding, "d16@0:8") != 0) return NO;

    __block double value = 0.0;
    BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
        double (*sendDouble)(id, SEL) = (void *)objc_msgSend;
        value = sendDouble((id)objectClass, selector);
    }, NULL);
    if (!resolvedSafely || !isfinite(value) || value <= 0.0) return NO;
    *resolvedValue = value;
    return YES;
}

static UIView *YTMUViewFromVerifiedIvar(id object,
                                       const char *ivarName,
                                       const char *expectedEncoding,
                                       Class expectedClass) {
    if (object == nil || ivarName == NULL || expectedEncoding == NULL) return nil;
    Ivar ivar = class_getInstanceVariable([object class], ivarName);
    const char *encoding = ivar == NULL ? NULL : ivar_getTypeEncoding(ivar);
    if (ivar == NULL || encoding == NULL || strcmp(encoding, expectedEncoding) != 0) {
        return nil;
    }
    __block id resolvedView = nil;
    BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
        resolvedView = object_getIvar(object, ivar);
    }, NULL);
    return resolvedSafely
        && [resolvedView isKindOfClass:UIView.class]
        && (expectedClass == Nil || [resolvedView isKindOfClass:expectedClass])
        ? resolvedView
        : nil;
}

static void YTMUAppendUniqueView(NSMutableArray<UIView *> *views, UIView *view) {
    if (view != nil && ![views containsObject:view]) [views addObject:view];
}

static YTMUMiniPlayerCropRect YTMUCropRectFromCGRect(CGRect rect) {
    YTMUMiniPlayerCropRect cropRect = {
        CGRectGetMinX(rect),
        CGRectGetMinY(rect),
        CGRectGetWidth(rect),
        CGRectGetHeight(rect),
    };
    return cropRect;
}

static CGRect YTMUCGRectFromCropRect(YTMUMiniPlayerCropRect rect) {
    return CGRectMake(rect.x, rect.y, rect.width, rect.height);
}

static void YTMUAppendCardParticipantIfContained(NSMutableArray<UIView *> *views,
                                                  UIView *view,
                                                  UIWindow *window,
                                                  CGRect cardFrame,
                                                  NSArray<UIView *> *excludedViews) {
    if (view == nil
        || window == nil
        || view.window != window
        || [excludedViews containsObject:view]) {
        return;
    }
    CGRect participantFrame = [view convertRect:view.bounds toView:window];
    CGRect visibleParticipantFrame = CGRectIntersection(participantFrame, window.bounds);
    if (!YTMURectIsFiniteAndVisible(visibleParticipantFrame)
        || YTMURectsEqualWithinTolerance(visibleParticipantFrame, window.bounds)
        || !CGRectContainsRect(CGRectInset(cardFrame,
                                           -YTMUNativeVisualGeometryTolerance,
                                           -YTMUNativeVisualGeometryTolerance),
                               visibleParticipantFrame)) {
        return;
    }
    YTMUAppendUniqueView(views, view);
}

static void YTMUAppendVerifiedMiniPlayerParticipant(NSMutableArray<UIView *> *views,
                                                     UIView *miniPlayerView,
                                                     Class miniPlayerViewClass,
                                                     UIWindow *window,
                                                     CGRect cardFrame) {
    if (miniPlayerView == nil
        || miniPlayerViewClass == Nil
        || ![miniPlayerView isKindOfClass:miniPlayerViewClass]
        || miniPlayerView.window != window) {
        return;
    }
    CGRect miniPlayerFrame = [miniPlayerView convertRect:miniPlayerView.bounds toView:window];
    if (!YTMURectIsFiniteAndVisible(CGRectIntersection(miniPlayerFrame, cardFrame))) return;

    // YTMMiniPlayerView is the verified semantic owner of the title, artwork,
    // and controls. Its layout bounds may be much taller than the 64pt card,
    // but hiding this exact class does not hide YTMWatchView, its controller
    // root, the home feed, or the pivot bar.
    YTMUAppendUniqueView(views, miniPlayerView);
}

static UIView *YTMUClosestCommonAncestorForViews(UIView *firstView, UIView *secondView) {
    if (firstView == nil || secondView == nil) return nil;
    for (UIView *candidate = firstView; candidate != nil; candidate = candidate.superview) {
        if (candidate == secondView || [secondView isDescendantOfView:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static UIView *YTMUDirectChildContainingView(UIView *ancestor, UIView *view) {
    if (ancestor == nil || view == nil || ancestor == view) return nil;
    UIView *branch = view;
    while (branch.superview != nil && branch.superview != ancestor) {
        branch = branch.superview;
    }
    return branch.superview == ancestor ? branch : nil;
}

static BOOL YTMUViewIsOrderedBelowSibling(UIView *view, UIView *sibling) {
    UIView *superview = view.superview;
    if (view == nil || sibling == nil || superview == nil || sibling.superview != superview) {
        return NO;
    }
    NSArray<UIView *> *siblings = superview.subviews;
    NSUInteger viewIndex = [siblings indexOfObjectIdenticalTo:view];
    NSUInteger siblingIndex = [siblings indexOfObjectIdenticalTo:sibling];
    return viewIndex != NSNotFound
        && siblingIndex != NSNotFound
        && viewIndex < siblingIndex;
}

@interface YTMUNativeMiniPlayerVisualContext : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIView *watchView;
@property (nonatomic, weak) UIView *controllerRootView;
@property (nonatomic, weak) UIView *miniPlayerView;
@property (nonatomic, weak) UIView *containerView;
@property (nonatomic, weak) UIView *pivotBarView;
@property (nonatomic, assign) CGRect cardFrameInWindow;
@property (nonatomic, copy) NSArray<UIView *> *visualParticipants;
@end

@implementation YTMUNativeMiniPlayerVisualContext
@end

static YTMUNativeMiniPlayerVisualContext *YTMUResolveNativeMiniPlayerVisualContext(
    UIViewController *controller,
    UIView *miniPlayerView) {
    Class miniPlayerControllerClass = NSClassFromString(@"YTMMiniPlayerViewController");
    Class watchControllerClass = NSClassFromString(@"YTMWatchViewController");
    Class watchViewClass = NSClassFromString(@"YTMWatchView");
    Class miniPlayerViewClass = NSClassFromString(@"YTMMiniPlayerView");
    Class gradientClass = NSClassFromString(@"YTMGradientBackgroundView");
    if (controller == nil
        || miniPlayerView == nil
        || miniPlayerControllerClass == Nil
        || watchControllerClass == Nil
        || watchViewClass == Nil
        || miniPlayerViewClass == Nil
        || gradientClass == Nil
        || ![controller isKindOfClass:miniPlayerControllerClass]
        || !controller.isViewLoaded) {
        return nil;
    }

    UIView *controllerRootView = controller.view;
    if (controllerRootView == nil
        || (miniPlayerView != controllerRootView
            && ![miniPlayerView isDescendantOfView:controllerRootView])) {
        return nil;
    }

    id watchController = YTMUObjectReturnedByVerifiedSelector(
        controller, @"parentResponder", watchControllerClass);
    UIView *watchView = YTMUObjectReturnedByVerifiedSelector(
        watchController, @"watchView", watchViewClass);
    UIView *watchMiniPlayerView = YTMUObjectReturnedByVerifiedSelector(
        watchView, @"miniPlayerView", miniPlayerViewClass);
    if (watchController == nil || watchView == nil || watchMiniPlayerView != miniPlayerView) {
        return nil;
    }

    UIWindow *window = miniPlayerView.window;
    if (window == nil
        || controllerRootView.window != window
        || watchView.window != window
        || [controllerRootView isKindOfClass:UITabBar.class]) {
        return nil;
    }

    UIView *containerView = YTMUViewFromVerifiedIvar(
        watchView, "_containerView", "@\"YTMGradientBackgroundView\"", gradientClass);
    UIView *gradientBackgroundView = YTMUViewFromVerifiedIvar(
        watchView, "_gradientBackgroundView", "@\"YTMGradientBackgroundView\"", gradientClass);
    UIView *containerShadowView = YTMUViewFromVerifiedIvar(
        watchView, "_containerShadowView", "@\"UIView\"", UIView.class);
    UIView *frostedGlassView = YTMUViewFromVerifiedIvar(
        watchView, "_frostedGlassView", "@\"UIView\"", UIView.class);
    UIView *pivotBarView = YTMUObjectReturnedByVerifiedSelector(
        watchView, @"pivotBarView", NSClassFromString(@"YTPivotBarView"));
    if (containerView == nil
        || gradientBackgroundView == nil
        || containerShadowView == nil
        || pivotBarView == nil
        || pivotBarView.window != window
        || pivotBarView.hidden) {
        return nil;
    }

    CGRect containerFrame = [containerView convertRect:containerView.bounds toView:window];
    CGRect pivotFrame = [pivotBarView convertRect:pivotBarView.bounds toView:window];
    if (!YTMURectIsFiniteAndVisible(containerFrame)
        || !YTMURectIsFiniteAndVisible(pivotFrame)) {
        return nil;
    }

    double nativeMinimizedHeight = 0.0;
    if (!YTMUClassDoubleReturnedByVerifiedSelector(
            watchViewClass, @"minimizedPlayerHeight", &nativeMinimizedHeight)) {
        return nil;
    }
    YTMUMiniPlayerCropRect resolvedCrop;
    if (!YTMUNativeMiniPlayerResolveCardCrop(
            YTMUCropRectFromCGRect(window.bounds),
            YTMUCropRectFromCGRect(containerFrame),
            YTMUCropRectFromCGRect(pivotFrame),
            nativeMinimizedHeight,
            YTMUNativeVisualGeometryTolerance,
            &resolvedCrop)) {
        return nil;
    }
    CGRect cardFrame = YTMUCGRectFromCropRect(resolvedCrop);
    if (!YTMURectIsFiniteAndVisible(cardFrame)
        || CGRectIntersectsRect(cardFrame, pivotFrame)) {
        return nil;
    }

    NSMutableArray<UIView *> *participants = [NSMutableArray array];
    NSArray<UIView *> *excludedParticipants = @[window, watchView, pivotBarView];
    YTMUAppendCardParticipantIfContained(participants,
                                         containerShadowView,
                                         window,
                                         cardFrame,
                                         excludedParticipants);
    YTMUAppendCardParticipantIfContained(participants,
                                         containerView,
                                         window,
                                         cardFrame,
                                         excludedParticipants);
    YTMUAppendCardParticipantIfContained(participants,
                                         gradientBackgroundView,
                                         window,
                                         cardFrame,
                                         excludedParticipants);
    YTMUAppendCardParticipantIfContained(participants,
                                         frostedGlassView,
                                         window,
                                         cardFrame,
                                         excludedParticipants);
    YTMUAppendCardParticipantIfContained(participants,
                                         controllerRootView,
                                         window,
                                         cardFrame,
                                         excludedParticipants);
    YTMUAppendVerifiedMiniPlayerParticipant(participants,
                                            miniPlayerView,
                                            miniPlayerViewClass,
                                            window,
                                            cardFrame);
    if (![participants containsObject:containerView]
        || ![participants containsObject:miniPlayerView]) {
        return nil;
    }

    YTMUNativeMiniPlayerVisualContext *context =
        [[YTMUNativeMiniPlayerVisualContext alloc] init];
    context.window = window;
    context.watchView = watchView;
    context.controllerRootView = controllerRootView;
    context.miniPlayerView = miniPlayerView;
    context.containerView = containerView;
    context.pivotBarView = pivotBarView;
    context.cardFrameInWindow = cardFrame;
    context.visualParticipants = participants;
    return context;
}

@interface YTMUNativeMiniPlayerSwipeHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *miniPlayerController;
@property (nonatomic, weak) UIView *miniPlayerView;
@property (nonatomic, weak) UIView *visualRootView;
@property (nonatomic, weak) UIPanGestureRecognizer *panGesture;
@property (nonatomic, weak) UIWindow *animationWindow;
@property (nonatomic, weak) UIView *animationCommonAncestor;
@property (nonatomic, weak) UIView *animationPivotBranch;
@property (nonatomic, strong) UIView *animationOcclusionView;
@property (nonatomic, strong) UIView *animationSnapshot;
@property (nonatomic, strong) UIView *interactionBlocker;
@property (nonatomic, copy) NSArray<UIView *> *coveredNativeViews;
@property (nonatomic, copy) NSArray<NSNumber *> *coveredNativeViewLayerOpacities;
@property (nonatomic, assign) CGAffineTransform animationOriginalTransform;
@property (nonatomic, assign) CGFloat animationOriginalAlpha;
@property (nonatomic, assign) BOOL visualRootOriginalHidden;
@property (nonatomic, assign) CGFloat visualRootOriginalAlpha;
@property (nonatomic, assign) CGAffineTransform visualRootOriginalTransform;
@property (nonatomic, assign) BOOL visualRootOriginalInteractionEnabled;
@property (nonatomic, assign) float visualRootOriginalLayerOpacity;
@property (nonatomic, assign) CGRect visualRootBoundsAtSwipeStart;
@property (nonatomic, assign) CGRect animationWindowBoundsAtSwipeStart;
@property (nonatomic, assign) CGRect animationCardFrameInWindow;
@property (nonatomic, assign) BOOL swipeInProgress;
@property (nonatomic, assign) BOOL swipeRestoring;
@property (nonatomic, assign) BOOL swipeDismissCommitted;
@property (nonatomic, assign) BOOL sessionEndRequestStarted;
@property (nonatomic, assign) BOOL ownerLeftNativeDuringCommit;
@property (nonatomic, assign) BOOL visualRootCoveredAfterConfirmedSessionEnd;
@property (nonatomic, assign) BOOL interactionDisabledAfterFailedCollapse;
@property (nonatomic, assign) NSUInteger swipeGeneration;
- (instancetype)initWithController:(UIViewController *)controller
                    miniPlayerView:(UIView *)miniPlayerView
                    visualRootView:(UIView *)visualRootView;
- (BOOL)isAttachedToMiniPlayerView:(UIView *)miniPlayerView;
- (void)prepareForPresentation;
- (void)invalidate;
- (BOOL)nativeSwipeCanContinue;
- (BOOL)unifiedAnimationGeometryIsCurrent;
- (BOOL)beginUnifiedSwipeAnimation;
- (void)coverNativeViews:(NSArray<UIView *> *)views;
- (void)restoreCoveredNativeViews;
- (void)discardAnimationSnapshot;
- (void)restoreVisualRootIncludingNativeState:(BOOL)restoreNativeState;
- (void)restoreSwipeAnimated:(BOOL)animated;
- (void)restoreSwipeAnimated:(BOOL)animated restoreNativeState:(BOOL)restoreNativeState;
- (void)showEndFailure:(NSError *)error;
- (void)commitDismissal;
- (void)finishCommittedDismissalForGeneration:(NSUInteger)generation;
- (void)endNativeSessionForGeneration:(NSUInteger)generation;
- (void)cancelSwipeForExternalStateChange;
- (void)applicationDidEnterBackground:(NSNotification *)notification;
- (void)nativePlaybackWillStart:(NSNotification *)notification;
- (void)playbackOwnershipDidChange:(NSNotification *)notification;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
@end

@implementation YTMUNativeMiniPlayerSwipeHandler

- (instancetype)initWithController:(UIViewController *)controller
                    miniPlayerView:(UIView *)miniPlayerView
                    visualRootView:(UIView *)visualRootView {
    self = [super init];
    if (self) {
        _miniPlayerController = controller;
        _miniPlayerView = miniPlayerView;
        _visualRootView = visualRootView;
        _visualRootOriginalHidden = visualRootView.hidden;
        _visualRootOriginalAlpha = visualRootView.alpha;
        _visualRootOriginalTransform = visualRootView.transform;
        _visualRootOriginalInteractionEnabled = visualRootView.userInteractionEnabled;
        _visualRootOriginalLayerOpacity = visualRootView.layer.opacity;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;
        [miniPlayerView addGestureRecognizer:pan];
        _panGesture = pan;

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(playbackOwnershipDidChange:)
                   name:YTMUPlaybackOwnershipDidChangeNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(nativePlaybackWillStart:)
                   name:YTMUNativePlaybackWillStartNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self invalidate];
}

- (BOOL)isAttachedToMiniPlayerView:(UIView *)miniPlayerView {
    return self.miniPlayerView == miniPlayerView
        && self.panGesture.view == miniPlayerView
        && self.visualRootView == self.miniPlayerController.view
        && (miniPlayerView == self.visualRootView
            || [miniPlayerView isDescendantOfView:self.visualRootView]);
}

- (void)invalidate {
    self.swipeGeneration++;
    BOOL restoreNativeState =
        YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerNative
        && !YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerSuppressed;
    [self restoreVisualRootIncludingNativeState:restoreNativeState];
    [self discardAnimationSnapshot];
    UIPanGestureRecognizer *pan = self.panGesture;
    pan.delegate = nil;
    [pan.view removeGestureRecognizer:pan];
    self.panGesture = nil;
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = NO;
    self.sessionEndRequestStarted = NO;
    self.ownerLeftNativeDuringCommit = NO;
    self.visualRootCoveredAfterConfirmedSessionEnd = NO;
    self.interactionDisabledAfterFailedCollapse = NO;
}

- (void)prepareForPresentation {
    if (YTMUPlaybackCoordinator.sharedCoordinator.owner != YTMUPlaybackOwnerNative) return;
    UIView *view = self.visualRootView;
    if (view == nil || self.miniPlayerView == nil) return;
    if (self.swipeInProgress || self.swipeRestoring || self.swipeDismissCommitted) {
        [self restoreSwipeAnimated:NO];
    }
    self.swipeGeneration++;
    [self restoreCoveredNativeViews];
    [self discardAnimationSnapshot];
    [self restoreVisualRootIncludingNativeState:NO];
    if (self.interactionDisabledAfterFailedCollapse) {
        view.userInteractionEnabled = self.visualRootOriginalInteractionEnabled;
        self.interactionDisabledAfterFailedCollapse = NO;
    }
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = NO;
    self.sessionEndRequestStarted = NO;
    self.ownerLeftNativeDuringCommit = NO;
    self.visualRootCoveredAfterConfirmedSessionEnd = NO;
    self.visualRootOriginalHidden = view.hidden;
    self.visualRootOriginalAlpha = view.alpha;
    self.visualRootOriginalTransform = view.transform;
    self.visualRootOriginalInteractionEnabled = view.userInteractionEnabled;
    self.visualRootOriginalLayerOpacity = view.layer.opacity;
}

- (BOOL)nativeSwipeCanContinue {
    UIView *view = self.miniPlayerView;
    UIView *visualRoot = self.visualRootView;
    UIViewController *controller = self.miniPlayerController;
    YTMUNativePlaybackAdapter *adapter = YTMUNativePlaybackAdapter.sharedAdapter;
    return view != nil
        && visualRoot != nil
        && controller != nil
        && visualRoot == controller.view
        && (view == visualRoot || [view isDescendantOfView:visualRoot])
        && visualRoot.window != nil
        && !view.hidden
        && !visualRoot.hidden
        && !adapter.nativeMiniPlayerSuppressed
        && YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerNative;
}

- (BOOL)unifiedAnimationGeometryIsCurrent {
    UIView *visualRootView = self.visualRootView;
    UIView *animationView = self.animationSnapshot;
    UIView *occlusionView = self.animationOcclusionView;
    UIView *commonAncestor = self.animationCommonAncestor;
    UIView *pivotBranch = self.animationPivotBranch;
    UIWindow *animationWindow = self.animationWindow;
    YTMUNativeMiniPlayerVisualContext *context =
        YTMUResolveNativeMiniPlayerVisualContext(self.miniPlayerController,
                                                 self.miniPlayerView);
    CGRect occlusionFrameInWindow = occlusionView == nil || animationWindow == nil
        ? CGRectNull
        : [occlusionView convertRect:occlusionView.bounds toView:animationWindow];
    return visualRootView != nil
        && animationView != nil
        && occlusionView != nil
        && commonAncestor != nil
        && pivotBranch != nil
        && animationWindow != nil
        && context != nil
        && context.window == animationWindow
        && animationView.superview == occlusionView
        && occlusionView.superview == commonAncestor
        && pivotBranch.superview == commonAncestor
        && YTMUViewIsOrderedBelowSibling(occlusionView, pivotBranch)
        && occlusionView.clipsToBounds
        && CGRectEqualToRect(visualRootView.bounds, self.visualRootBoundsAtSwipeStart)
        && CGRectEqualToRect(animationWindow.bounds,
                             self.animationWindowBoundsAtSwipeStart)
        && YTMURectsEqualWithinTolerance(occlusionFrameInWindow,
                                         self.animationCardFrameInWindow)
        && YTMURectsEqualWithinTolerance(context.cardFrameInWindow,
                                         self.animationCardFrameInWindow);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.panGesture) return YES;
    UIView *view = touch.view;
    while (view != nil && view != self.miniPlayerView) {
        if ([view isKindOfClass:UIControl.class]) return NO;
        view = view.superview;
    }
    return !UIAccessibilityIsVoiceOverRunning();
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.panGesture
        || self.swipeInProgress
        || self.swipeRestoring
        || self.swipeDismissCommitted
        || ![self nativeSwipeCanContinue]) {
        return NO;
    }

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:self.miniPlayerView];
    return YTMUMiniPlayerSwipeCanBegin(
        YTMUPlaybackCoordinator.sharedCoordinator.owner,
        YTMUPlaybackOwnerNative,
        YES,
        YES,
        NO,
        velocity.x,
        velocity.y);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if (gestureRecognizer != self.panGesture) return NO;
    UIView *otherView = other.view;
    return [otherView isKindOfClass:UIScrollView.class]
        && other == ((UIScrollView *)otherView).panGestureRecognizer
        && [otherView isDescendantOfView:self.miniPlayerView];
}

- (BOOL)beginUnifiedSwipeAnimation {
    UIView *miniPlayerView = self.miniPlayerView;
    UIView *visualRootView = self.visualRootView;
    YTMUNativeMiniPlayerVisualContext *context =
        YTMUResolveNativeMiniPlayerVisualContext(self.miniPlayerController,
                                                 miniPlayerView);
    UIWindow *window = context.window;
    CGRect cardFrame = context.cardFrameInWindow;
    UIView *commonAncestor = YTMUClosestCommonAncestorForViews(context.containerView,
                                                               context.pivotBarView);
    UIView *cardBranch = YTMUDirectChildContainingView(commonAncestor,
                                                       context.containerView);
    UIView *pivotBranch = YTMUDirectChildContainingView(commonAncestor,
                                                        context.pivotBarView);
    if (miniPlayerView == nil
        || visualRootView == nil
        || context == nil
        || window == nil
        || commonAncestor == nil
        || cardBranch == nil
        || pivotBranch == nil
        || cardBranch == pivotBranch
        || commonAncestor.window != window
        || pivotBranch.window != window
        || !YTMURectIsFiniteAndVisible(cardFrame)
        || (miniPlayerView != visualRootView
            && ![miniPlayerView isDescendantOfView:visualRootView])) {
        return NO;
    }

    [self restoreCoveredNativeViews];
    [self discardAnimationSnapshot];
    self.visualRootOriginalHidden = visualRootView.hidden;
    self.visualRootOriginalAlpha = visualRootView.alpha;
    self.visualRootOriginalTransform = visualRootView.transform;
    self.visualRootOriginalInteractionEnabled = visualRootView.userInteractionEnabled;
    self.visualRootOriginalLayerOpacity = visualRootView.layer.opacity;
    self.visualRootBoundsAtSwipeStart = visualRootView.bounds;
    self.animationWindowBoundsAtSwipeStart = window.bounds;
    self.animationCardFrameInWindow = cardFrame;

    [window layoutIfNeeded];
    [commonAncestor layoutIfNeeded];
    UIView *snapshot = [window resizableSnapshotViewFromRect:cardFrame
                                         afterScreenUpdates:NO
                                              withCapInsets:UIEdgeInsetsZero];
    if (snapshot == nil) return NO;
    CGRect occlusionFrame = [commonAncestor convertRect:cardFrame fromView:window];
    if (!YTMURectIsFiniteAndVisible(occlusionFrame)) return NO;
    UIView *occlusionView = [[UIView alloc] initWithFrame:occlusionFrame];
    occlusionView.backgroundColor = UIColor.clearColor;
    occlusionView.userInteractionEnabled = YES;
    occlusionView.isAccessibilityElement = NO;
    occlusionView.accessibilityElementsHidden = YES;
    occlusionView.clipsToBounds = YES;
    occlusionView.layer.masksToBounds = YES;
    snapshot.frame = occlusionView.bounds;
    snapshot.userInteractionEnabled = NO;
    snapshot.isAccessibilityElement = NO;
    snapshot.accessibilityElementsHidden = YES;
    snapshot.clipsToBounds = NO;
    snapshot.layer.masksToBounds = NO;
    UIView *interactionBlocker = [[UIView alloc] initWithFrame:occlusionView.bounds];
    interactionBlocker.backgroundColor = UIColor.clearColor;
    interactionBlocker.userInteractionEnabled = YES;
    interactionBlocker.isAccessibilityElement = NO;
    interactionBlocker.accessibilityElementsHidden = YES;
    [occlusionView addSubview:interactionBlocker];
    [occlusionView addSubview:snapshot];
    __block BOOL placedBelowPivot = NO;
    BOOL placementSucceeded = YTMUPerformObjectiveCBlockSafely(^{
        if (pivotBranch.superview != commonAncestor) return;
        [commonAncestor insertSubview:occlusionView belowSubview:pivotBranch];
        placedBelowPivot = occlusionView.superview == commonAncestor
            && YTMUViewIsOrderedBelowSibling(occlusionView, pivotBranch);
    }, NULL);
    if (!placementSucceeded || !placedBelowPivot) {
        [occlusionView removeFromSuperview];
        return NO;
    }

    self.animationWindow = window;
    self.animationCommonAncestor = commonAncestor;
    self.animationPivotBranch = pivotBranch;
    self.animationOcclusionView = occlusionView;
    self.animationSnapshot = snapshot;
    self.interactionBlocker = interactionBlocker;
    self.animationOriginalTransform = snapshot.transform;
    self.animationOriginalAlpha = snapshot.alpha;
    [self coverNativeViews:context.visualParticipants];
    return YES;
}

- (void)coverNativeViews:(NSArray<UIView *> *)views {
    if (views.count == 0) return;
    [self restoreCoveredNativeViews];
    NSMutableArray<NSNumber *> *opacities = [NSMutableArray arrayWithCapacity:views.count];
    for (UIView *view in views) {
        [opacities addObject:@(view.layer.opacity)];
    }
    self.coveredNativeViews = [views copy];
    self.coveredNativeViewLayerOpacities = opacities;
    YTMUSetNativeMiniPlayerViewsLayerOpacity(self.coveredNativeViews, 0.0f);
}

- (void)restoreCoveredNativeViews {
    NSArray<UIView *> *views = self.coveredNativeViews;
    NSArray<NSNumber *> *opacities = self.coveredNativeViewLayerOpacities;
    self.coveredNativeViews = nil;
    self.coveredNativeViewLayerOpacities = nil;
    NSUInteger count = MIN(views.count, opacities.count);
    [UIView performWithoutAnimation:^{
        for (NSUInteger index = 0; index < count; index++) {
            views[index].layer.opacity = opacities[index].floatValue;
        }
    }];
}

- (void)discardAnimationSnapshot {
    UIView *snapshot = self.animationSnapshot;
    UIView *occlusionView = self.animationOcclusionView;
    self.animationSnapshot = nil;
    self.interactionBlocker = nil;
    self.animationOcclusionView = nil;
    self.animationCommonAncestor = nil;
    self.animationPivotBranch = nil;
    self.animationWindow = nil;
    self.animationWindowBoundsAtSwipeStart = CGRectZero;
    self.animationCardFrameInWindow = CGRectZero;
    if (snapshot != nil) {
        [snapshot.layer removeAllAnimations];
        // Only the transient view created by this handler is removed. Native
        // YouTube Music views remain in their original hierarchy.
    }
    [occlusionView.layer removeAllAnimations];
    [occlusionView removeFromSuperview];
}

- (void)restoreVisualRootIncludingNativeState:(BOOL)restoreNativeState {
    UIView *visualRootView = self.visualRootView;
    if (visualRootView == nil) return;
    if (restoreNativeState) {
        visualRootView.hidden = self.visualRootOriginalHidden;
        visualRootView.alpha = self.visualRootOriginalAlpha;
        visualRootView.transform = self.visualRootOriginalTransform;
        visualRootView.userInteractionEnabled = self.visualRootOriginalInteractionEnabled;
        self.interactionDisabledAfterFailedCollapse = NO;
    }
    BOOL keepEndedShellCovered = !restoreNativeState
        && (self.visualRootCoveredAfterConfirmedSessionEnd
            || YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerVisualShellCollapsed)
        && YTMUPlaybackCoordinator.sharedCoordinator.owner != YTMUPlaybackOwnerNative;
    if (keepEndedShellCovered) {
        YTMUSetNativeMiniPlayerViewsLayerOpacity(self.coveredNativeViews, 0.0f);
    } else {
        [self restoreCoveredNativeViews];
        [UIView performWithoutAnimation:^{
            visualRootView.layer.opacity = self.visualRootOriginalLayerOpacity;
        }];
    }
}

- (void)restoreSwipeAnimated:(BOOL)animated {
    BOOL shouldRestoreNativeState =
        YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerNative
        && !YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerSuppressed;
    [self restoreSwipeAnimated:animated restoreNativeState:shouldRestoreNativeState];
}

- (void)restoreSwipeAnimated:(BOOL)animated restoreNativeState:(BOOL)restoreNativeState {
    UIView *animationView = self.animationSnapshot;
    NSUInteger generation = ++self.swipeGeneration;
    self.swipeInProgress = NO;
    self.swipeRestoring = animated;
    self.swipeDismissCommitted = NO;
    self.sessionEndRequestStarted = NO;
    self.ownerLeftNativeDuringCommit = NO;
    if (restoreNativeState) {
        self.visualRootCoveredAfterConfirmedSessionEnd = NO;
    }
    void (^animations)(void) = ^{
        animationView.transform = self.animationOriginalTransform;
        animationView.alpha = self.animationOriginalAlpha;
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (generation != self.swipeGeneration) return;
        [self restoreVisualRootIncludingNativeState:restoreNativeState];
        [self discardAnimationSnapshot];
        self.swipeRestoring = NO;
    };
    if (animated && animationView != nil) {
        [UIView animateWithDuration:YTMUNativeSwipeRestoreDuration
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                                  | UIViewAnimationOptionCurveEaseOut
                         animations:animations
                         completion:completion];
    } else {
        [animationView.layer removeAllAnimations];
        animations();
        completion(YES);
    }
}

- (void)showEndFailure:(NSError *)error {
    NSException *toastException = nil;
    BOOL shownSafely = YTMUPerformObjectiveCBlockSafely(^{
        Class toastClass = NSClassFromString(@"YTMToastController");
        SEL selector = NSSelectorFromString(@"showMessage:");
        id toast = toastClass == Nil ? nil : [[toastClass alloc] init];
        if (toast != nil && [toast respondsToSelector:selector]) {
            void (*sendMessage)(id, SEL, id) = (void *)objc_msgSend;
            sendMessage(toast,
                        selector,
                        YTMUNativeSwipeLocalized(
                            @"NATIVE_MINIPLAYER_END_FAILED",
                            @"YouTube Music playback could not be ended."));
        }
    }, &toastException);
    if (!shownSafely || error != nil) {
        NSLog(@"[YTMusicUltimate] Native mini-player dismissal failed: %@%@%@",
              error.localizedDescription ?: @"unknown error",
              toastException == nil ? @"" : @"; ",
              toastException.reason ?: @"");
    }
}

- (void)commitDismissal {
    if (self.swipeDismissCommitted || ![self nativeSwipeCanContinue]) {
        [self restoreSwipeAnimated:YES];
        return;
    }

    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = YES;
    self.sessionEndRequestStarted = NO;
    self.ownerLeftNativeDuringCommit = NO;
    self.animationSnapshot.userInteractionEnabled = NO;
    NSUInteger generation = ++self.swipeGeneration;
    [self finishCommittedDismissalForGeneration:generation];
}

- (void)finishCommittedDismissalForGeneration:(NSUInteger)generation {
    UIView *animationView = self.animationSnapshot;
    if (generation != self.swipeGeneration
        || animationView == nil
        || ![self unifiedAnimationGeometryIsCurrent]
        || ![self nativeSwipeCanContinue]) {
        [self restoreSwipeAnimated:NO restoreNativeState:NO];
        return;
    }

    CGFloat finishDistance = CGRectGetHeight(animationView.bounds)
        + YTMUNativeSwipeFinishPadding;
    [UIView animateWithDuration:YTMUNativeSwipeCommitDuration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState
                              | UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         animationView.transform = CGAffineTransformTranslate(
                             self.animationOriginalTransform, 0, finishDistance);
                         animationView.alpha = self.animationOriginalAlpha
                             * (1.0 - YTMUNativeSwipeMaximumFade);
                     }
                     completion:^(__unused BOOL finished) {
                         if (generation != self.swipeGeneration) return;
                         [self endNativeSessionForGeneration:generation];
                     }];
}

- (void)endNativeSessionForGeneration:(NSUInteger)generation {
    if (generation != self.swipeGeneration || ![self nativeSwipeCanContinue]) {
        [self restoreSwipeAnimated:NO restoreNativeState:NO];
        return;
    }
    self.sessionEndRequestStarted = YES;

    NSError *endError = nil;
    BOOL ended = [YTMUNativePlaybackAdapter.sharedAdapter
        requestNativeSessionEndFromMiniPlayerController:self.miniPlayerController
                                                   error:&endError];
    if (!ended) {
        [self restoreSwipeAnimated:YES];
        [self showEndFailure:endError];
        return;
    }

    NSError *collapseError = nil;
    BOOL collapsed = [YTMUNativePlaybackAdapter.sharedAdapter
        collapseNativeMiniPlayerVisualShellAfterConfirmedSessionEnd:&collapseError];
    self.visualRootCoveredAfterConfirmedSessionEnd = !collapsed;
    if (collapsed) {
        // The native model and presentation layers are both outside the visible
        // mini-player viewport now. Restoring their original opacity cannot
        // expose a second animation and leaves the next native session clean.
        [self restoreCoveredNativeViews];
        self.visualRootView.userInteractionEnabled =
            self.visualRootOriginalInteractionEnabled;
        self.interactionDisabledAfterFailedCollapse = NO;
    } else {
        // Playback is already confirmed stopped. Keep the original shell
        // visually covered if the version-guarded layout command fails rather
        // than revealing a misleading empty player.
        self.visualRootView.userInteractionEnabled = NO;
        self.interactionDisabledAfterFailedCollapse = YES;
        [self showEndFailure:collapseError];
    }
    // Keep the native root covered while its private dismissal animation
    // settles. The pre-%orig playback-start notification restores it for the
    // next real native session and invalidates this gesture generation.
    [self discardAnimationSnapshot];
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = NO;
    self.sessionEndRequestStarted = NO;
    self.ownerLeftNativeDuringCommit = NO;
}

- (void)cancelSwipeForExternalStateChange {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cancelSwipeForExternalStateChange];
        });
        return;
    }
    if (self.swipeDismissCommitted && self.sessionEndRequestStarted) {
        return;
    }
    if (!self.swipeInProgress
        && !self.swipeRestoring
        && !self.swipeDismissCommitted) {
        return;
    }
    self.panGesture.enabled = NO;
    BOOL nativeStillOwnsPlayback =
        YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerNative
        && !YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerSuppressed;
    [self restoreSwipeAnimated:NO restoreNativeState:nativeStillOwnsPlayback];
    self.panGesture.enabled = YES;
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)notification {
    [self cancelSwipeForExternalStateChange];
}

- (void)nativePlaybackWillStart:(__unused NSNotification *)notification {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf nativePlaybackWillStart:nil];
        });
        return;
    }
    if (self.swipeInProgress || self.swipeRestoring || self.swipeDismissCommitted) {
        self.panGesture.enabled = NO;
        [self restoreSwipeAnimated:NO restoreNativeState:YES];
        self.panGesture.enabled = YES;
        return;
    }
    self.swipeGeneration++;
    if (self.visualRootView.layer.opacity != self.visualRootOriginalLayerOpacity) {
        [self prepareForPresentation];
    }
}

- (void)playbackOwnershipDidChange:(__unused NSNotification *)notification {
    YTMUPlaybackOwner owner = YTMUPlaybackCoordinator.sharedCoordinator.owner;
    if (owner == YTMUPlaybackOwnerNative) {
        if (self.ownerLeftNativeDuringCommit
            || (!self.swipeInProgress
                && !self.swipeRestoring
                && !self.swipeDismissCommitted
                && self.visualRootView.layer.opacity
                    != self.visualRootOriginalLayerOpacity)) {
            [self prepareForPresentation];
        }
        return;
    }
    if (self.swipeDismissCommitted) {
        self.ownerLeftNativeDuringCommit = YES;
    }
    [self cancelSwipeForExternalStateChange];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *view = self.miniPlayerView;
    if (view == nil || self.swipeDismissCommitted) return;
    CGPoint translation = [gesture translationInView:view];
    CGPoint velocity = [gesture velocityInView:view];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            if (![self nativeSwipeCanContinue]
                || ![self beginUnifiedSwipeAnimation]) {
                [self restoreSwipeAnimated:NO];
                return;
            }
            self.swipeGeneration++;
            self.swipeInProgress = YES;
            self.swipeRestoring = NO;
            break;
        case UIGestureRecognizerStateChanged: {
            UIView *animationView = self.animationSnapshot;
            if (!self.swipeInProgress
                || animationView == nil
                || ![self unifiedAnimationGeometryIsCurrent]
                || ![self nativeSwipeCanContinue]) {
                [self restoreSwipeAnimated:YES];
                return;
            }
            CGFloat downwardTranslation = MAX(0.0, translation.y);
            CGFloat cardHeight = CGRectGetHeight(animationView.bounds);
            double progress = YTMUMiniPlayerSwipeProgress(cardHeight, downwardTranslation);
            animationView.transform = CGAffineTransformTranslate(
                self.animationOriginalTransform, 0, downwardTranslation);
            animationView.alpha = self.animationOriginalAlpha
                * (1.0 - YTMUNativeSwipeMaximumFade * progress);
            break;
        }
        case UIGestureRecognizerStateEnded:
            if (!self.swipeInProgress
                || ![self unifiedAnimationGeometryIsCurrent]
                || ![self nativeSwipeCanContinue]) {
                [self restoreSwipeAnimated:YES];
                return;
            }
            if (YTMUMiniPlayerSwipeShouldCommit(
                    CGRectGetHeight(self.animationSnapshot.bounds),
                    translation.x,
                    translation.y,
                    velocity.x,
                    velocity.y)) {
                [self commitDismissal];
            } else {
                [self restoreSwipeAnimated:YES];
            }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self restoreSwipeAnimated:YES];
            break;
        default:
            break;
    }
}

@end

static UIView *YTMUResolveNativeMiniPlayerView(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"miniPlayerView");
    if (![controller respondsToSelector:selector]) return nil;
    __block id resolvedView = nil;
    NSException *resolutionException = nil;
    BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
        id (*sendObject)(id, SEL) = (void *)objc_msgSend;
        resolvedView = sendObject(controller, selector);
    }, &resolutionException);
    if (!resolvedSafely) {
        NSLog(@"[YTMusicUltimate] Native mini-player view resolution failed %@: %@",
              resolutionException.name,
              resolutionException.reason);
        return nil;
    }
    return [resolvedView isKindOfClass:UIView.class] ? resolvedView : nil;
}

static UIView *YTMUResolveNativeMiniPlayerVisualRoot(UIViewController *controller,
                                                     UIView *miniPlayerView) {
    if (controller == nil || miniPlayerView == nil || !controller.isViewLoaded) return nil;
    UIView *visualRoot = controller.view;
    if (visualRoot == nil
        || [visualRoot isKindOfClass:UITabBar.class]
        || (miniPlayerView != visualRoot
            && ![miniPlayerView isDescendantOfView:visualRoot])) {
        return nil;
    }
    // YTMMiniPlayerViewController is the verified dedicated mini-player
    // controller. Its root is used only as a rendered snapshot source; the
    // native view itself is never translated or detached from the watch layout.
    return visualRoot;
}

void YTMUInstallNativeMiniPlayerSwipeIfNeeded(UIViewController *miniPlayerController) {
    if (miniPlayerController == nil || !NSThread.isMainThread) return;
    Class miniPlayerClass = NSClassFromString(@"YTMMiniPlayerViewController");
    if (miniPlayerClass == Nil || ![miniPlayerController isKindOfClass:miniPlayerClass]) return;

    UIView *miniPlayerView = YTMUResolveNativeMiniPlayerView(miniPlayerController);
    if (miniPlayerView == nil) return;
    UIView *visualRootView = YTMUResolveNativeMiniPlayerVisualRoot(miniPlayerController,
                                                                  miniPlayerView);
    if (visualRootView == nil) return;

    YTMUNativeMiniPlayerSwipeHandler *existing = objc_getAssociatedObject(
        miniPlayerController, &YTMUNativeMiniPlayerSwipeAssociationKey);
    if ([existing isKindOfClass:YTMUNativeMiniPlayerSwipeHandler.class]
        && [existing isAttachedToMiniPlayerView:miniPlayerView]) {
        if (YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerVisualShellCollapsed
            && YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerNone) {
            YTMUSetNativeMiniPlayerViewsLayerOpacity(@[visualRootView], 0.0f);
        }
        [existing prepareForPresentation];
        return;
    }

    [existing invalidate];
    YTMUNativeMiniPlayerSwipeHandler *handler =
        [[YTMUNativeMiniPlayerSwipeHandler alloc]
            initWithController:miniPlayerController
                 miniPlayerView:miniPlayerView
                 visualRootView:visualRootView];
    if (YTMUNativePlaybackAdapter.sharedAdapter.nativeMiniPlayerVisualShellCollapsed
        && YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerNone) {
        YTMUSetNativeMiniPlayerViewsLayerOpacity(@[visualRootView], 0.0f);
    }
    objc_setAssociatedObject(miniPlayerController,
                             &YTMUNativeMiniPlayerSwipeAssociationKey,
                             handler,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
