#import "YTMUNativeMiniPlayerSwipeController.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "YTMUMiniPlayerSwipePolicy.h"
#import "YTMUNativePlaybackAdapter.h"
#import "YTMUObjectiveCExceptionGuard.h"
#import "YTMUPlaybackCoordinator.h"
#import "../Headers/Localization.h"

static const NSTimeInterval YTMUNativeSwipeRestoreDuration = 0.22;
static const CGFloat YTMUNativeSwipeMaximumFade = 0.35;
static char YTMUNativeMiniPlayerSwipeAssociationKey;

static NSString *YTMUNativeSwipeLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

@interface YTMUNativeMiniPlayerSwipeHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *miniPlayerController;
@property (nonatomic, weak) UIView *miniPlayerView;
@property (nonatomic, weak) UIPanGestureRecognizer *panGesture;
@property (nonatomic, assign) CGAffineTransform originalTransform;
@property (nonatomic, assign) CGFloat originalAlpha;
@property (nonatomic, assign) BOOL originalInteractionEnabled;
@property (nonatomic, assign) BOOL swipeInProgress;
@property (nonatomic, assign) BOOL swipeRestoring;
@property (nonatomic, assign) BOOL swipeDismissCommitted;
@property (nonatomic, assign) NSUInteger swipeGeneration;
- (instancetype)initWithController:(UIViewController *)controller
                    miniPlayerView:(UIView *)miniPlayerView;
- (BOOL)isAttachedToMiniPlayerView:(UIView *)miniPlayerView;
- (void)prepareForPresentation;
- (void)invalidate;
- (BOOL)nativeSwipeCanContinue;
- (void)restoreSwipeAnimated:(BOOL)animated;
- (void)showEndFailure:(NSError *)error;
- (BOOL)commitDismissal;
- (void)cancelSwipeForExternalStateChange;
- (void)applicationDidEnterBackground:(NSNotification *)notification;
- (void)playbackOwnershipDidChange:(NSNotification *)notification;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
@end

@implementation YTMUNativeMiniPlayerSwipeHandler

- (instancetype)initWithController:(UIViewController *)controller
                    miniPlayerView:(UIView *)miniPlayerView {
    self = [super init];
    if (self) {
        _miniPlayerController = controller;
        _miniPlayerView = miniPlayerView;
        _originalTransform = miniPlayerView.transform;
        _originalAlpha = miniPlayerView.alpha;
        _originalInteractionEnabled = miniPlayerView.userInteractionEnabled;

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
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self invalidate];
}

- (BOOL)isAttachedToMiniPlayerView:(UIView *)miniPlayerView {
    return self.miniPlayerView == miniPlayerView
        && self.panGesture.view == miniPlayerView;
}

- (void)invalidate {
    self.swipeGeneration++;
    UIPanGestureRecognizer *pan = self.panGesture;
    pan.delegate = nil;
    [pan.view removeGestureRecognizer:pan];
    self.panGesture = nil;
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = NO;
}

- (void)prepareForPresentation {
    if (YTMUPlaybackCoordinator.sharedCoordinator.owner != YTMUPlaybackOwnerNative) return;
    UIView *view = self.miniPlayerView;
    if (view == nil) return;
    if (self.swipeInProgress || self.swipeRestoring || self.swipeDismissCommitted) {
        [self restoreSwipeAnimated:NO];
    }
    self.swipeGeneration++;
    [view.layer removeAllAnimations];
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = NO;
    self.originalTransform = view.transform;
    self.originalAlpha = view.alpha;
    self.originalInteractionEnabled = view.userInteractionEnabled;
}

- (BOOL)nativeSwipeCanContinue {
    UIView *view = self.miniPlayerView;
    UIViewController *controller = self.miniPlayerController;
    YTMUNativePlaybackAdapter *adapter = YTMUNativePlaybackAdapter.sharedAdapter;
    return view != nil
        && controller != nil
        && view.window != nil
        && !view.hidden
        && !adapter.nativeMiniPlayerSuppressed
        && YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerNative;
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

- (void)restoreSwipeAnimated:(BOOL)animated {
    UIView *view = self.miniPlayerView;
    if (view == nil) return;
    NSUInteger generation = ++self.swipeGeneration;
    self.swipeInProgress = NO;
    self.swipeRestoring = animated;
    self.swipeDismissCommitted = NO;
    view.userInteractionEnabled = self.originalInteractionEnabled;
    void (^animations)(void) = ^{
        view.transform = self.originalTransform;
        view.alpha = self.originalAlpha;
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (generation != self.swipeGeneration) return;
        self.swipeRestoring = NO;
    };
    if (animated) {
        [UIView animateWithDuration:YTMUNativeSwipeRestoreDuration
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                                  | UIViewAnimationOptionCurveEaseOut
                         animations:animations
                         completion:completion];
    } else {
        [view.layer removeAllAnimations];
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

- (BOOL)commitDismissal {
    if (self.swipeDismissCommitted || ![self nativeSwipeCanContinue]) {
        [self restoreSwipeAnimated:YES];
        return NO;
    }

    UIView *view = self.miniPlayerView;
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = YES;
    view.userInteractionEnabled = NO;
    self.swipeGeneration++;

    NSError *endError = nil;
    BOOL ended = [YTMUNativePlaybackAdapter.sharedAdapter
        requestNativeSessionEndFromMiniPlayerController:self.miniPlayerController
                                                   error:&endError];
    if (!ended) {
        [self restoreSwipeAnimated:YES];
        [self showEndFailure:endError];
        return NO;
    }

    [view.layer removeAllAnimations];
    view.transform = self.originalTransform;
    view.alpha = self.originalAlpha;
    view.userInteractionEnabled = self.originalInteractionEnabled;
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = NO;
    return YES;
}

- (void)cancelSwipeForExternalStateChange {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cancelSwipeForExternalStateChange];
        });
        return;
    }
    if (self.swipeDismissCommitted
        || (!self.swipeInProgress && !self.swipeRestoring)) {
        return;
    }
    self.panGesture.enabled = NO;
    [self restoreSwipeAnimated:NO];
    self.panGesture.enabled = YES;
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)notification {
    [self cancelSwipeForExternalStateChange];
}

- (void)playbackOwnershipDidChange:(__unused NSNotification *)notification {
    if (YTMUPlaybackCoordinator.sharedCoordinator.owner != YTMUPlaybackOwnerNative) {
        [self cancelSwipeForExternalStateChange];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *view = self.miniPlayerView;
    if (view == nil || self.swipeDismissCommitted) return;
    CGPoint translation = [gesture translationInView:view];
    CGPoint velocity = [gesture velocityInView:view];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            if (![self nativeSwipeCanContinue]) {
                [self restoreSwipeAnimated:NO];
                return;
            }
            [view.layer removeAllAnimations];
            self.swipeGeneration++;
            self.originalTransform = view.transform;
            self.originalAlpha = view.alpha;
            self.originalInteractionEnabled = view.userInteractionEnabled;
            self.swipeInProgress = YES;
            self.swipeRestoring = NO;
            break;
        case UIGestureRecognizerStateChanged: {
            if (!self.swipeInProgress || ![self nativeSwipeCanContinue]) {
                [self restoreSwipeAnimated:YES];
                return;
            }
            CGFloat downwardTranslation = MAX(0.0, translation.y);
            CGFloat cardHeight = CGRectGetHeight(view.bounds);
            double progress = YTMUMiniPlayerSwipeProgress(cardHeight, downwardTranslation);
            view.transform = CGAffineTransformTranslate(
                self.originalTransform, 0, downwardTranslation);
            view.alpha = self.originalAlpha * (1.0 - YTMUNativeSwipeMaximumFade * progress);
            break;
        }
        case UIGestureRecognizerStateEnded:
            if (!self.swipeInProgress || ![self nativeSwipeCanContinue]) {
                [self restoreSwipeAnimated:YES];
                return;
            }
            if (YTMUMiniPlayerSwipeShouldCommit(
                    CGRectGetHeight(view.bounds),
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

void YTMUInstallNativeMiniPlayerSwipeIfNeeded(UIViewController *miniPlayerController) {
    if (miniPlayerController == nil || !NSThread.isMainThread) return;
    Class miniPlayerClass = NSClassFromString(@"YTMMiniPlayerViewController");
    if (miniPlayerClass == Nil || ![miniPlayerController isKindOfClass:miniPlayerClass]) return;

    UIView *miniPlayerView = YTMUResolveNativeMiniPlayerView(miniPlayerController);
    if (miniPlayerView == nil) return;

    YTMUNativeMiniPlayerSwipeHandler *existing = objc_getAssociatedObject(
        miniPlayerController, &YTMUNativeMiniPlayerSwipeAssociationKey);
    if ([existing isKindOfClass:YTMUNativeMiniPlayerSwipeHandler.class]
        && [existing isAttachedToMiniPlayerView:miniPlayerView]) {
        [existing prepareForPresentation];
        return;
    }

    [existing invalidate];
    YTMUNativeMiniPlayerSwipeHandler *handler =
        [[YTMUNativeMiniPlayerSwipeHandler alloc]
            initWithController:miniPlayerController miniPlayerView:miniPlayerView];
    objc_setAssociatedObject(miniPlayerController,
                             &YTMUNativeMiniPlayerSwipeAssociationKey,
                             handler,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
