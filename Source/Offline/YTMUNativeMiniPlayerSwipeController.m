#import "YTMUNativeMiniPlayerSwipeController.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "YTMUMiniPlayerSwipePolicy.h"
#import "YTMUNativePlaybackAdapter.h"
#import "YTMUObjectiveCExceptionGuard.h"
#import "YTMUPlaybackCoordinator.h"
#import "../Headers/Localization.h"

static const NSTimeInterval YTMUNativeSwipeRestoreDuration = 0.22;
static const NSTimeInterval YTMUNativeSwipeCommitDuration = 0.18;
static const CGFloat YTMUNativeSwipeMaximumFade = 0.35;
static const CGFloat YTMUNativeSwipeFinishPadding = 12.0;
static char YTMUNativeMiniPlayerSwipeAssociationKey;

static NSString *YTMUNativeSwipeLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

static void YTMUSetNativeMiniPlayerLayerOpacity(UIView *view, float opacity) {
    if (view == nil) return;
    [UIView performWithoutAnimation:^{ view.layer.opacity = opacity; }];
}

@interface YTMUNativeMiniPlayerSwipeHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *miniPlayerController;
@property (nonatomic, weak) UIView *miniPlayerView;
@property (nonatomic, weak) UIView *visualRootView;
@property (nonatomic, weak) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UIView *animationSnapshot;
@property (nonatomic, strong) UIView *interactionBlocker;
@property (nonatomic, assign) CGAffineTransform animationOriginalTransform;
@property (nonatomic, assign) CGFloat animationOriginalAlpha;
@property (nonatomic, assign) BOOL visualRootOriginalHidden;
@property (nonatomic, assign) CGFloat visualRootOriginalAlpha;
@property (nonatomic, assign) CGAffineTransform visualRootOriginalTransform;
@property (nonatomic, assign) BOOL visualRootOriginalInteractionEnabled;
@property (nonatomic, assign) float visualRootOriginalLayerOpacity;
@property (nonatomic, assign) CGRect visualRootBoundsAtSwipeStart;
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
    return visualRootView != nil
        && animationView != nil
        && animationView.superview == visualRootView.superview
        && CGRectEqualToRect(visualRootView.bounds, self.visualRootBoundsAtSwipeStart);
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
    UIView *containerView = visualRootView.superview;
    if (miniPlayerView == nil
        || visualRootView == nil
        || containerView == nil
        || (miniPlayerView != visualRootView
            && ![miniPlayerView isDescendantOfView:visualRootView])) {
        return NO;
    }

    [self discardAnimationSnapshot];
    self.visualRootOriginalHidden = visualRootView.hidden;
    self.visualRootOriginalAlpha = visualRootView.alpha;
    self.visualRootOriginalTransform = visualRootView.transform;
    self.visualRootOriginalInteractionEnabled = visualRootView.userInteractionEnabled;
    self.visualRootOriginalLayerOpacity = visualRootView.layer.opacity;
    self.visualRootBoundsAtSwipeStart = visualRootView.bounds;

    UIView *snapshot = [visualRootView snapshotViewAfterScreenUpdates:NO];
    if (snapshot == nil) return NO;
    snapshot.frame = [visualRootView convertRect:visualRootView.bounds toView:containerView];
    snapshot.userInteractionEnabled = NO;
    snapshot.isAccessibilityElement = NO;
    snapshot.accessibilityElementsHidden = YES;
    UIView *interactionBlocker = [[UIView alloc] initWithFrame:snapshot.frame];
    interactionBlocker.backgroundColor = UIColor.clearColor;
    interactionBlocker.userInteractionEnabled = YES;
    interactionBlocker.isAccessibilityElement = NO;
    interactionBlocker.accessibilityElementsHidden = YES;
    [containerView insertSubview:interactionBlocker aboveSubview:visualRootView];
    [containerView insertSubview:snapshot aboveSubview:interactionBlocker];

    self.animationSnapshot = snapshot;
    self.interactionBlocker = interactionBlocker;
    self.animationOriginalTransform = snapshot.transform;
    self.animationOriginalAlpha = snapshot.alpha;
    YTMUSetNativeMiniPlayerLayerOpacity(visualRootView, 0.0f);
    return YES;
}

- (void)discardAnimationSnapshot {
    UIView *snapshot = self.animationSnapshot;
    UIView *interactionBlocker = self.interactionBlocker;
    self.animationSnapshot = nil;
    self.interactionBlocker = nil;
    if (snapshot != nil) {
        [snapshot.layer removeAllAnimations];
        // Only the transient view created by this handler is removed. Native
        // YouTube Music views remain in their original hierarchy.
        [snapshot removeFromSuperview];
    }
    [interactionBlocker removeFromSuperview];
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
    YTMUSetNativeMiniPlayerLayerOpacity(
        visualRootView,
        keepEndedShellCovered ? 0.0f : self.visualRootOriginalLayerOpacity);
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
    self.visualRootCoveredAfterConfirmedSessionEnd = YES;
    if (!collapsed) {
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
            YTMUSetNativeMiniPlayerLayerOpacity(visualRootView, 0.0f);
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
        YTMUSetNativeMiniPlayerLayerOpacity(visualRootView, 0.0f);
    }
    objc_setAssociatedObject(miniPlayerController,
                             &YTMUNativeMiniPlayerSwipeAssociationKey,
                             handler,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
