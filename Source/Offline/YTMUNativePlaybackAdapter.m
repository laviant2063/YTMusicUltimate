#import "YTMUNativePlaybackAdapter.h"

#import "YTMUObjectiveCExceptionGuard.h"

#import <objc/message.h>
#import <objc/runtime.h>

#include <string.h>

// YouTube Music 9.14.2's YTMWatchPageLayoutControllerImpl -dismiss selects
// layout 6. This value and both method encodings are verified against the host
// binary before the private layout command is used.
static const long long YTMUNativeMiniPlayerDismissedLayout = 6;
static const CGFloat YTMUNativeMiniPlayerCollapsedVisibleHeightTolerance = 0.5;

static CGFloat YTMUNativeVisibleHeightForView(UIView *view,
                                              UIWindow *window,
                                              CGRect viewport,
                                              BOOL usePresentationLayer) {
    if (view == nil || window == nil || view.window != window) return 0.0;
    CALayer *layer = usePresentationLayer
        ? (CALayer *)view.layer.presentationLayer
        : view.layer;
    if (layer == nil) layer = view.layer;
    CGRect frameInWindow = [layer convertRect:layer.bounds toLayer:window.layer];
    CGRect visibleFrame = CGRectIntersection(frameInWindow, viewport);
    return CGRectIsNull(visibleFrame) || CGRectIsEmpty(visibleFrame)
        ? 0.0
        : CGRectGetHeight(visibleFrame);
}

NSNotificationName const YTMUNativePlaybackWillStartNotification =
    @"YTMUNativePlaybackWillStartNotification";

// BEGIN native empty-state observation helpers
typedef NS_ENUM(NSInteger, YTMUNativeMiniPlayerContentState) {
    YTMUNativeMiniPlayerContentUnknown,
    YTMUNativeMiniPlayerContentEmpty,
    YTMUNativeMiniPlayerContentPresent,
};

static BOOL YTMUNativeEmptyStateMethodHasEncoding(id object, SEL selector,
                                                   const char *expectedEncoding) {
    if (object == nil || ![object respondsToSelector:selector]) return NO;
    Method method = class_getInstanceMethod([object class], selector);
    const char *encoding = method == NULL ? NULL : method_getTypeEncoding(method);
    return encoding != NULL && strcmp(encoding, expectedEncoding) == 0;
}
// END native empty-state observation helpers

@interface YTMUNativeMiniPlayerSnapshot : NSObject
@property (nonatomic, assign) BOOL hidden;
@property (nonatomic, assign) CGFloat alpha;
@property (nonatomic, assign) BOOL userInteractionEnabled;
@end


@implementation YTMUNativeMiniPlayerSnapshot
@end


@interface YTMUNativePlaybackAdapter ()
@property (nonatomic, weak) UIViewController *playerViewController;
@property (nonatomic, weak) UIViewController *watchViewController;
@property (nonatomic, strong) NSHashTable<UIViewController *> *miniPlayerControllers;
@property (nonatomic, strong) NSMapTable<UIViewController *, YTMUNativeMiniPlayerSnapshot *> *miniPlayerSnapshots;
@property (nonatomic, assign) BOOL miniPlayerSuppressed;
@property (nonatomic, assign, readwrite, getter=isNativePlaybackAudible) BOOL nativePlaybackAudible;
@property (nonatomic, assign, readwrite, getter=isNativeMiniPlayerVisualShellCollapsed) BOOL nativeMiniPlayerVisualShellCollapsed;
@property (nonatomic, assign) NSUInteger nativeMiniPlayerLayoutGeneration;
@property (nonatomic, assign) BOOL nativeMiniPlayerRefreshScheduled;
@property (nonatomic, assign) BOOL nativeMiniPlayerEmptyStateReconciliationInProgress;
- (void)scheduleNativeMiniPlayerVisualShellReassertionIfNeeded;
@end


@implementation YTMUNativePlaybackAdapter

+ (YTMUNativePlaybackAdapter *)sharedAdapter {
    static YTMUNativePlaybackAdapter *adapter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adapter = [[YTMUNativePlaybackAdapter alloc] initPrivate];
    });
    return adapter;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _miniPlayerControllers = [NSHashTable weakObjectsHashTable];
        _miniPlayerSnapshots = [NSMapTable weakToStrongObjectsMapTable];
        for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                          YTMUPlaybackOwnershipDidChangeNotification]) {
            [[NSNotificationCenter defaultCenter]
                addObserver:self selector:@selector(nativeMiniPlayerEnvironmentDidChange:)
                       name:name object:nil];
        }
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)init {
    return YTMUNativePlaybackAdapter.sharedAdapter;
}

- (void)performOnMainSynchronously:(dispatch_block_t)block {
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

- (void)nativeMiniPlayerEnvironmentDidChange:(__unused NSNotification *)notification {
    [self scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
}

- (YTMUNativeMiniPlayerContentState)nativeMiniPlayerContentState {
    UIViewController *watch = self.watchViewController;
    Class watchClass = NSClassFromString(@"YTMWatchViewController");
    if (watchClass == Nil || ![watch isKindOfClass:watchClass]
        || !watch.isViewLoaded || watch.view.window == nil) {
        return YTMUNativeMiniPlayerContentUnknown;
    }

    // Read-only getters verified in the 9.14.2 Mach-O. Silence alone is not
    // emptiness: a paused/restoring song, pending model or queued item must stay.
    SEL modelSelector = NSSelectorFromString(@"model");
    SEL videoSelector = NSSelectorFromString(@"activeVideoID");
    SEL queueSelector = NSSelectorFromString(@"queueController");
    SEL playingSelector = NSSelectorFromString(@"isPlaybackVideoPlaying");
    if (!YTMUNativeEmptyStateMethodHasEncoding(watch, modelSelector, "@16@0:8")
        || !YTMUNativeEmptyStateMethodHasEncoding(watch, videoSelector, "@16@0:8")
        || !YTMUNativeEmptyStateMethodHasEncoding(watch, queueSelector, "@16@0:8")
        || !YTMUNativeEmptyStateMethodHasEncoding(watch, playingSelector, "B16@0:8")) {
        return YTMUNativeMiniPlayerContentUnknown;
    }

    __block YTMUNativeMiniPlayerContentState state = YTMUNativeMiniPlayerContentUnknown;
    NSException *exception = nil;
    BOOL readSafely = YTMUPerformObjectiveCBlockSafely(^{
        id (*sendObject)(id, SEL) = (void *)objc_msgSend;
        BOOL (*sendBool)(id, SEL) = (void *)objc_msgSend;
        id model = sendObject(watch, modelSelector);
        id videoID = sendObject(watch, videoSelector);
        if (videoID != nil && ![videoID isKindOfClass:NSString.class]) return;
        if (model != nil || [videoID length] > 0 || sendBool(watch, playingSelector)) {
            state = YTMUNativeMiniPlayerContentPresent;
            return;
        }

        id queue = sendObject(watch, queueSelector);
        if (queue != nil) {
            Class queueClass = NSClassFromString(@"YTQueueController");
            SEL countSelector = NSSelectorFromString(@"queueCount");
            SEL itemSelector = NSSelectorFromString(@"nowPlayingMusicQueueItem");
            if (queueClass == Nil || ![queue isKindOfClass:queueClass]
                || !YTMUNativeEmptyStateMethodHasEncoding(queue, countSelector, "Q16@0:8")
                || !YTMUNativeEmptyStateMethodHasEncoding(queue, itemSelector, "@16@0:8")) return;
            unsigned long long (*sendCount)(id, SEL) = (void *)objc_msgSend;
            if (sendCount(queue, countSelector) > 0 || sendObject(queue, itemSelector) != nil) {
                state = YTMUNativeMiniPlayerContentPresent;
                return;
            }
        }

        UIViewController *player = self.playerViewController;
        if (player != nil) {
            Class playerClass = NSClassFromString(@"YTPlayerViewController");
            SEL currentVideoSelector = NSSelectorFromString(@"currentVideoID");
            if (playerClass == Nil || ![player isKindOfClass:playerClass]
                || !YTMUNativeEmptyStateMethodHasEncoding(player, currentVideoSelector, "@16@0:8")) return;
            id currentVideoID = sendObject(player, currentVideoSelector);
            if (currentVideoID != nil && ![currentVideoID isKindOfClass:NSString.class]) return;
            if ([currentVideoID length] > 0) {
                state = YTMUNativeMiniPlayerContentPresent;
                return;
            }
        }
        state = YTMUNativeMiniPlayerContentEmpty;
    }, &exception);
    if (!readSafely) {
        NSLog(@"[YTMusicUltimate] Native empty-state observation failed: %@", exception.name);
        return YTMUNativeMiniPlayerContentUnknown;
    }
    return state;
}

- (void)reconcileNativeMiniPlayerEmptyState {
    if (YTMUPlaybackCoordinator.sharedCoordinator.owner != YTMUPlaybackOwnerNone
        || self.nativePlaybackAudible || self.miniPlayerSuppressed) return;

    YTMUNativeMiniPlayerContentState content = [self nativeMiniPlayerContentState];
    if (content == YTMUNativeMiniPlayerContentPresent) {
        if (self.nativeMiniPlayerVisualShellCollapsed) {
            // Also release our old cover when the host restores a paused queue.
            // This is a UI invalidation, not a play command or owner transition.
            [self prepareNativeMiniPlayerForPlaybackStart];
        }
        return;
    }
    if (content != YTMUNativeMiniPlayerContentEmpty) return;
    if (self.nativeMiniPlayerVisualShellCollapsed
        && [self nativeMiniPlayerVisualShellIsGeometricallyCollapsed:NULL]) return;

    self.nativeMiniPlayerEmptyStateReconciliationInProgress = YES;
    NSError *collapseError = nil;
    if (![self collapseNativeMiniPlayerVisualShellAfterConfirmedSessionEnd:&collapseError]
        && collapseError != nil) {
        NSLog(@"[YTMusicUltimate] Native empty-state layout failed: %@",
              collapseError.localizedDescription);
    }
    self.nativeMiniPlayerEmptyStateReconciliationInProgress = NO;
}

- (void)scheduleNativeMiniPlayerVisualShellReassertionIfNeeded {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
        });
        return;
    }
    if (self.nativeMiniPlayerRefreshScheduled
        || self.nativeMiniPlayerEmptyStateReconciliationInProgress) return;
    self.nativeMiniPlayerRefreshScheduled = YES;
    NSUInteger generation = self.nativeMiniPlayerLayoutGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.nativeMiniPlayerRefreshScheduled = NO;
        if (generation != strongSelf.nativeMiniPlayerLayoutGeneration) {
            [strongSelf scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
            return;
        }
        NSException *exception = nil;
        BOOL reconciledSafely = YTMUPerformObjectiveCBlockSafely(^{
            [strongSelf reconcileNativeMiniPlayerEmptyState];
        }, &exception);
        strongSelf.nativeMiniPlayerEmptyStateReconciliationInProgress = NO;
        if (!reconciledSafely) {
            NSLog(@"[YTMusicUltimate] Contained native empty-state layout exception: %@",
                  exception.name);
        }
    });
}

- (void)registerPlayerViewController:(UIViewController *)controller {
    if (controller == nil) return;
    [self performOnMainSynchronously:^{
        self.playerViewController = controller;
        [self scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    }];
}

- (void)registerWatchViewController:(UIViewController *)controller {
    if (controller == nil) return;
    [self performOnMainSynchronously:^{
        self.watchViewController = controller;
        SEL playerSelector = NSSelectorFromString(@"playerViewController");
        if ([controller respondsToSelector:playerSelector]) {
            YTMUPerformObjectiveCBlockSafely(^{
                id (*sendObject)(id, SEL) = (void *)objc_msgSend;
                UIViewController *player = sendObject(controller, playerSelector);
                if ([player isKindOfClass:UIViewController.class]) {
                    self.playerViewController = player;
                }
            }, NULL);
        }
        [self scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    }];
}

- (void)applyMiniPlayerSuppressionToControllerWithoutThrowing:(UIViewController *)controller {
    if (controller == nil || !controller.isViewLoaded) return;
    UIView *view = controller.view;
    if (self.miniPlayerSuppressed) {
        if ([self.miniPlayerSnapshots objectForKey:controller] == nil) {
            YTMUNativeMiniPlayerSnapshot *snapshot = [[YTMUNativeMiniPlayerSnapshot alloc] init];
            snapshot.hidden = view.hidden;
            snapshot.alpha = view.alpha;
            snapshot.userInteractionEnabled = view.userInteractionEnabled;
            [self.miniPlayerSnapshots setObject:snapshot forKey:controller];
        }
        view.hidden = YES;
        view.alpha = 0;
        view.userInteractionEnabled = NO;
        return;
    }

    YTMUNativeMiniPlayerSnapshot *snapshot = [self.miniPlayerSnapshots objectForKey:controller];
    if (snapshot != nil) {
        view.hidden = snapshot.hidden;
        view.alpha = snapshot.alpha;
        view.userInteractionEnabled = snapshot.userInteractionEnabled;
        [self.miniPlayerSnapshots removeObjectForKey:controller];
    }
}

- (void)applyMiniPlayerSuppressionToController:(UIViewController *)controller {
    NSException *suppressionException = nil;
    BOOL appliedSafely = YTMUPerformObjectiveCBlockSafely(^{
        [self applyMiniPlayerSuppressionToControllerWithoutThrowing:controller];
    }, &suppressionException);
    if (!appliedSafely) {
        NSLog(@"[YTMusicUltimate] Contained native mini player exception %@: %@",
              suppressionException.name,
              suppressionException.reason);
    }
}

- (void)registerMiniPlayerViewController:(UIViewController *)controller {
    if (controller == nil) return;
    [self performOnMainSynchronously:^{
        [self.miniPlayerControllers addObject:controller];
        if (self.miniPlayerSuppressed) {
            [self applyMiniPlayerSuppressionToController:controller];
        }
        [self scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    }];
}

- (void)setNativeMiniPlayerSuppressed:(BOOL)suppressed {
    [self performOnMainSynchronously:^{
        if (self.miniPlayerSuppressed == suppressed) return;
        self.miniPlayerSuppressed = suppressed;
        for (UIViewController *controller in self.miniPlayerControllers.allObjects) {
            [self applyMiniPlayerSuppressionToController:controller];
        }
        [self scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    }];
}

- (BOOL)isNativeMiniPlayerSuppressed {
    __block BOOL suppressed = NO;
    [self performOnMainSynchronously:^{ suppressed = self.miniPlayerSuppressed; }];
    return suppressed;
}

- (BOOL)watchControllerReportsPlayback {
    UIViewController *watch = self.watchViewController;
    SEL selector = NSSelectorFromString(@"isPlaybackVideoPlaying");
    if (watch == nil || ![watch respondsToSelector:selector]) {
        return self.nativePlaybackAudible;
    }
    __block BOOL isPlaying = self.nativePlaybackAudible;
    NSException *stateException = nil;
    BOOL readSafely = YTMUPerformObjectiveCBlockSafely(^{
        BOOL (*sendBool)(id, SEL) = (void *)objc_msgSend;
        isPlaying = sendBool(watch, selector);
    }, &stateException);
    if (!readSafely) {
        NSLog(@"[YTMusicUltimate] Could not read native playback state %@: %@",
              stateException.name,
              stateException.reason);
    }
    return isPlaying;
}

- (BOOL)requestNativePauseForOfflinePlayback:(NSError **)error {
    __block BOOL accepted = NO;
    __block NSError * __strong pauseRequestError = nil;
    [self performOnMainSynchronously:^{
        UIViewController *player = self.playerViewController;
        if (player == nil && self.watchViewController != nil) {
            SEL playerSelector = NSSelectorFromString(@"playerViewController");
            if ([self.watchViewController respondsToSelector:playerSelector]) {
                __block id resolvedPlayer = nil;
                NSException *resolutionException = nil;
                BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
                    id (*sendObject)(id, SEL) = (void *)objc_msgSend;
                    resolvedPlayer = sendObject(self.watchViewController, playerSelector);
                }, &resolutionException);
                if (!resolvedSafely) {
                    pauseRequestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                                            code:3
                                                        userInfo:@{NSLocalizedDescriptionKey:
                                                                       resolutionException.reason
                                                                           ?: @"YouTube Music playback controls could not be resolved."}];
                    return;
                }
                if ([resolvedPlayer isKindOfClass:UIViewController.class]) {
                    player = resolvedPlayer;
                    self.playerViewController = player;
                }
            }
        }
        SEL pauseSelector = NSSelectorFromString(@"pause");
        if (player == nil || ![player respondsToSelector:pauseSelector]) {
            accepted = !self.nativePlaybackAudible;
            return;
        }
        NSException *pauseException = nil;
        accepted = YTMUPerformObjectiveCBlockSafely(^{
            void (*sendVoid)(id, SEL) = (void *)objc_msgSend;
            sendVoid(player, pauseSelector);
        }, &pauseException);
        if (!accepted) {
            pauseRequestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                                    code:2
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                               pauseException.reason
                                                                   ?: @"YouTube Music playback could not be paused."}];
            return;
        }
        if (![self watchControllerReportsPlayback]) {
            self.nativePlaybackAudible = NO;
        }
    }];

    if (error != NULL) {
        if (accepted) {
            *error = nil;
        } else {
            *error = pauseRequestError
                ?: [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey:
                                                   @"YouTube Music playback controls were not available."}];
        }
    }
    return accepted;
}

- (BOOL)requestNativeSessionEndFromMiniPlayerController:(UIViewController *)controller
                                                  error:(NSError **)error {
    __block BOOL ended = NO;
    __block NSError * __strong requestError = nil;
    [self performOnMainSynchronously:^{
        YTMUPlaybackCoordinator *coordinator = YTMUPlaybackCoordinator.sharedCoordinator;
        if (coordinator.owner != YTMUPlaybackOwnerNative || self.miniPlayerSuppressed) {
            requestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                               code:4
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          @"YouTube Music does not own playback right now."}];
            return;
        }

        UIViewController *watch = self.watchViewController;
        if (watch == nil && controller != nil) {
            SEL parentSelector = NSSelectorFromString(@"parentResponder");
            if ([controller respondsToSelector:parentSelector]) {
                __block id parentResponder = nil;
                NSException *resolutionException = nil;
                BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
                    id (*sendObject)(id, SEL) = (void *)objc_msgSend;
                    parentResponder = sendObject(controller, parentSelector);
                }, &resolutionException);
                if (!resolvedSafely) {
                    requestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                                       code:5
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                                  resolutionException.reason
                                                                      ?: @"The YouTube Music player could not be resolved."}];
                    return;
                }
                Class watchClass = NSClassFromString(@"YTMWatchViewController");
                if (watchClass != Nil && [parentResponder isKindOfClass:watchClass]) {
                    watch = parentResponder;
                    self.watchViewController = watch;
                }
            }
        }

        SEL resetAndHideSelector = NSSelectorFromString(@"resetAndHide");
        if (watch == nil || ![watch respondsToSelector:resetAndHideSelector]) {
            requestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                               code:6
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          @"YouTube Music playback could not be closed safely."}];
            return;
        }

        Method resetAndHideMethod = class_getInstanceMethod(watch.class, resetAndHideSelector);
        const char *typeEncoding = resetAndHideMethod == NULL
            ? NULL
            : method_getTypeEncoding(resetAndHideMethod);
        if (typeEncoding == NULL || strcmp(typeEncoding, "v16@0:8") != 0) {
            requestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                               code:9
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          @"This YouTube Music version has an incompatible close command."}];
            return;
        }

        NSException *resetException = nil;
        BOOL invokedSafely = YTMUPerformObjectiveCBlockSafely(^{
            void (*sendVoid)(id, SEL) = (void *)objc_msgSend;
            sendVoid(watch, resetAndHideSelector);
        }, &resetException);
        if (!invokedSafely) {
            requestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                               code:7
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          resetException.reason
                                                              ?: @"YouTube Music rejected the close request."}];
            return;
        }

        BOOL stillPlaying = [self watchControllerReportsPlayback];
        if (!stillPlaying && coordinator.owner == YTMUPlaybackOwnerNative) {
            self.nativePlaybackAudible = NO;
            [coordinator nativePlaybackSessionDidEnd];
        }
        ended = !stillPlaying && coordinator.owner == YTMUPlaybackOwnerNone;
        if (!ended) {
            requestError = [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                                               code:8
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          @"YouTube Music playback was not confirmed as stopped."}];
        }
    }];

    if (error != NULL) {
        *error = ended ? nil : requestError;
    }
    return ended;
}

- (NSError *)nativeMiniPlayerLayoutErrorWithCode:(NSInteger)code
                                      description:(NSString *)description {
    return [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (id)nativeMiniPlayerLayoutControllerWithError:(NSError **)error {
    UIViewController *watch = self.watchViewController;
    Class watchClass = NSClassFromString(@"YTMWatchViewController");
    if (watch == nil || watchClass == Nil || ![watch isKindOfClass:watchClass]) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:10
                                                    description:@"The YouTube Music watch controller is unavailable."];
        }
        return nil;
    }

    Ivar layoutIvar = class_getInstanceVariable(watch.class, "_watchPageLayoutController");
    const char *layoutType = layoutIvar == NULL ? NULL : ivar_getTypeEncoding(layoutIvar);
    if (layoutIvar == NULL
        || layoutType == NULL
        || strcmp(layoutType, "@\"<YTMWatchPageLayoutControllerInternal>\"") != 0) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:11
                                                    description:@"This YouTube Music version has an incompatible mini-player layout controller."];
        }
        return nil;
    }

    __block id layoutController = nil;
    NSException *resolutionException = nil;
    BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
        layoutController = object_getIvar(watch, layoutIvar);
    }, &resolutionException);
    Class layoutClass = NSClassFromString(@"YTMWatchPageLayoutControllerImpl");
    if (!resolvedSafely
        || layoutController == nil
        || layoutClass == Nil
        || ![layoutController isKindOfClass:layoutClass]) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:12
                                                    description:resolutionException.reason
                                                        ?: @"The YouTube Music mini-player layout could not be resolved."];
        }
        return nil;
    }

    SEL dismissSelector = NSSelectorFromString(@"dismiss");
    SEL currentLayoutSelector = NSSelectorFromString(@"currentLayout");
    SEL switchLayoutSelector = NSSelectorFromString(@"switchToLayout:animated:");
    SEL cancelAnimationSelector = NSSelectorFromString(@"cancelWatchViewAnimation");
    Method dismissMethod = class_getInstanceMethod([layoutController class], dismissSelector);
    Method currentLayoutMethod = class_getInstanceMethod([layoutController class],
                                                          currentLayoutSelector);
    Method switchLayoutMethod = class_getInstanceMethod([layoutController class],
                                                         switchLayoutSelector);
    Method cancelAnimationMethod = class_getInstanceMethod([layoutController class],
                                                            cancelAnimationSelector);
    const char *dismissEncoding = dismissMethod == NULL
        ? NULL
        : method_getTypeEncoding(dismissMethod);
    const char *currentLayoutEncoding = currentLayoutMethod == NULL
        ? NULL
        : method_getTypeEncoding(currentLayoutMethod);
    const char *switchLayoutEncoding = switchLayoutMethod == NULL
        ? NULL
        : method_getTypeEncoding(switchLayoutMethod);
    const char *cancelAnimationEncoding = cancelAnimationMethod == NULL
        ? NULL
        : method_getTypeEncoding(cancelAnimationMethod);
    if (![layoutController respondsToSelector:dismissSelector]
        || ![layoutController respondsToSelector:currentLayoutSelector]
        || ![layoutController respondsToSelector:switchLayoutSelector]
        || ![layoutController respondsToSelector:cancelAnimationSelector]
        || dismissEncoding == NULL
        || currentLayoutEncoding == NULL
        || switchLayoutEncoding == NULL
        || cancelAnimationEncoding == NULL
        || strcmp(dismissEncoding, "v16@0:8") != 0
        || strcmp(currentLayoutEncoding, "q16@0:8") != 0
        || strcmp(switchLayoutEncoding, "v28@0:8q16B24") != 0
        || strcmp(cancelAnimationEncoding, "v16@0:8") != 0) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:13
                                                    description:@"This YouTube Music version has incompatible mini-player layout commands."];
        }
        return nil;
    }

    if (error != NULL) *error = nil;
    return layoutController;
}

- (UIView *)nativeWatchViewWithError:(NSError **)error {
    UIViewController *watchController = self.watchViewController;
    Class watchControllerClass = NSClassFromString(@"YTMWatchViewController");
    Class watchViewClass = NSClassFromString(@"YTMWatchView");
    SEL watchViewSelector = NSSelectorFromString(@"watchView");
    Method watchViewMethod = watchController == nil
        ? NULL
        : class_getInstanceMethod(watchController.class, watchViewSelector);
    const char *watchViewEncoding = watchViewMethod == NULL
        ? NULL
        : method_getTypeEncoding(watchViewMethod);
    if (watchController == nil
        || watchControllerClass == Nil
        || watchViewClass == Nil
        || ![watchController isKindOfClass:watchControllerClass]
        || ![watchController respondsToSelector:watchViewSelector]
        || watchViewEncoding == NULL
        || strcmp(watchViewEncoding, "@16@0:8") != 0) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:17
                                                    description:@"The YouTube Music watch view is unavailable."];
        }
        return nil;
    }

    __block id watchView = nil;
    NSException *watchViewException = nil;
    BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
        id (*sendObject)(id, SEL) = (void *)objc_msgSend;
        watchView = sendObject(watchController, watchViewSelector);
    }, &watchViewException);
    if (!resolvedSafely || ![watchView isKindOfClass:watchViewClass]) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:18
                                                    description:watchViewException.reason
                                                        ?: @"The YouTube Music watch view could not be resolved."];
        }
        return nil;
    }
    if (error != NULL) *error = nil;
    return watchView;
}

- (NSArray<UIView *> *)nativeMiniPlayerVisualShellViewsForWatchView:(UIView *)watchView
                                                              error:(NSError **)error {
    Class gradientClass = NSClassFromString(@"YTMGradientBackgroundView");
    if (watchView == nil || gradientClass == Nil) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:19
                                                    description:@"The native mini-player shell class is unavailable."];
        }
        return nil;
    }

    NSMutableArray<UIView *> *shellViews = [NSMutableArray arrayWithCapacity:3];
    __block BOOL resolvedAllViews = YES;
    NSException *ivarException = nil;
    BOOL resolvedSafely = YTMUPerformObjectiveCBlockSafely(^{
        const char *ivarNames[] = {
            "_containerView",
            "_gradientBackgroundView",
            "_containerShadowView",
        };
        const char *ivarEncodings[] = {
            "@\"YTMGradientBackgroundView\"",
            "@\"YTMGradientBackgroundView\"",
            "@\"UIView\"",
        };
        for (NSUInteger index = 0; index < 3; index++) {
            Ivar ivar = class_getInstanceVariable(watchView.class, ivarNames[index]);
            const char *encoding = ivar == NULL ? NULL : ivar_getTypeEncoding(ivar);
            if (ivar == NULL
                || encoding == NULL
                || strcmp(encoding, ivarEncodings[index]) != 0) {
                resolvedAllViews = NO;
                return;
            }
            id value = object_getIvar(watchView, ivar);
            // The same cold-layout variant handled by the r3 swipe resolver:
            // the main container exists before optional split backgrounds do.
            if (value == nil && index > 0) continue;
            Class expectedClass = index < 2 ? gradientClass : UIView.class;
            if (![value isKindOfClass:expectedClass]) {
                resolvedAllViews = NO;
                return;
            }
            [shellViews addObject:value];
        }
    }, &ivarException);
    if (!resolvedSafely || !resolvedAllViews || shellViews.count == 0) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:20
                                                    description:ivarException.reason
                                                        ?: @"The native mini-player shell views could not be resolved safely."];
        }
        return nil;
    }
    if (error != NULL) *error = nil;
    return shellViews;
}

- (BOOL)nativeMiniPlayerVisualShellIsGeometricallyCollapsed:(NSError **)error {
    NSError *watchViewError = nil;
    UIView *watchView = [self nativeWatchViewWithError:&watchViewError];
    if (watchView == nil) {
        if (error != NULL) *error = watchViewError;
        return NO;
    }

    SEL currentLayoutSelector = NSSelectorFromString(@"currentLayout");
    SEL dismissedSelector = NSSelectorFromString(@"isDismissed");
    Method currentLayoutMethod = class_getInstanceMethod(watchView.class,
                                                          currentLayoutSelector);
    Method dismissedMethod = class_getInstanceMethod(watchView.class, dismissedSelector);
    const char *currentLayoutEncoding = currentLayoutMethod == NULL
        ? NULL
        : method_getTypeEncoding(currentLayoutMethod);
    const char *dismissedEncoding = dismissedMethod == NULL
        ? NULL
        : method_getTypeEncoding(dismissedMethod);
    if (![watchView respondsToSelector:currentLayoutSelector]
        || ![watchView respondsToSelector:dismissedSelector]
        || currentLayoutEncoding == NULL
        || dismissedEncoding == NULL
        || strcmp(currentLayoutEncoding, "q16@0:8") != 0
        || strcmp(dismissedEncoding, "B16@0:8") != 0) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerLayoutErrorWithCode:21
                                                    description:@"This YouTube Music version has incompatible visual layout state APIs."];
        }
        return NO;
    }

    NSError *shellError = nil;
    NSArray<UIView *> *shellViews =
        [self nativeMiniPlayerVisualShellViewsForWatchView:watchView error:&shellError];
    if (shellViews == nil) {
        if (error != NULL) *error = shellError;
        return NO;
    }

    __block BOOL dismissed = NO;
    __block long long watchLayout = -1;
    __block CGFloat maximumModelVisibleHeight = 0.0;
    __block CGFloat maximumPresentationVisibleHeight = 0.0;
    NSException *geometryException = nil;
    BOOL inspectedSafely = YTMUPerformObjectiveCBlockSafely(^{
        [UIView performWithoutAnimation:^{
            [watchView setNeedsLayout];
            [watchView layoutIfNeeded];
            [watchView.window layoutIfNeeded];
        }];

        BOOL (*sendBool)(id, SEL) = (void *)objc_msgSend;
        long long (*sendInteger)(id, SEL) = (void *)objc_msgSend;
        dismissed = sendBool(watchView, dismissedSelector);
        watchLayout = sendInteger(watchView, currentLayoutSelector);

        UIWindow *window = watchView.window;
        if (window == nil) return;
        CGRect viewport = window.bounds;
        SEL pivotSelector = NSSelectorFromString(@"pivotBarView");
        Method pivotMethod = class_getInstanceMethod(watchView.class, pivotSelector);
        const char *pivotEncoding = pivotMethod == NULL
            ? NULL
            : method_getTypeEncoding(pivotMethod);
        if ([watchView respondsToSelector:pivotSelector]
            && pivotEncoding != NULL
            && strcmp(pivotEncoding, "@16@0:8") == 0) {
            id (*sendObject)(id, SEL) = (void *)objc_msgSend;
            UIView *pivotBarView = sendObject(watchView, pivotSelector);
            if ([pivotBarView isKindOfClass:UIView.class]
                && pivotBarView.window == window
                && !pivotBarView.hidden) {
                CGRect pivotFrame = [pivotBarView convertRect:pivotBarView.bounds toView:window];
                CGFloat viewportMaximumY = MIN(CGRectGetMaxY(viewport),
                                               CGRectGetMinY(pivotFrame));
                viewport.size.height = MAX(0.0,
                    viewportMaximumY - CGRectGetMinY(viewport));
            }
        }

        for (UIView *shellView in shellViews) {
            maximumModelVisibleHeight = MAX(
                maximumModelVisibleHeight,
                YTMUNativeVisibleHeightForView(shellView, window, viewport, NO));
            maximumPresentationVisibleHeight = MAX(
                maximumPresentationVisibleHeight,
                YTMUNativeVisibleHeightForView(shellView, window, viewport, YES));
        }
    }, &geometryException);
    BOOL geometricallyCollapsed = inspectedSafely
        && dismissed
        && watchLayout == YTMUNativeMiniPlayerDismissedLayout
        && maximumModelVisibleHeight <= YTMUNativeMiniPlayerCollapsedVisibleHeightTolerance
        && maximumPresentationVisibleHeight
            <= YTMUNativeMiniPlayerCollapsedVisibleHeightTolerance;
    if (!geometricallyCollapsed && error != NULL) {
        NSString *description = geometryException.reason
            ?: [NSString stringWithFormat:
                @"The native mini-player still occupies visible layout space (model %.2f, presentation %.2f).",
                maximumModelVisibleHeight,
                maximumPresentationVisibleHeight];
        *error = [self nativeMiniPlayerLayoutErrorWithCode:22 description:description];
    } else if (error != NULL) {
        *error = nil;
    }
    return geometricallyCollapsed;
}

- (BOOL)collapseNativeMiniPlayerVisualShellAfterConfirmedSessionEnd:(NSError **)error {
    __block BOOL collapsed = NO;
    __block NSError * __strong collapseError = nil;
    [self performOnMainSynchronously:^{
        YTMUPlaybackCoordinator *coordinator = YTMUPlaybackCoordinator.sharedCoordinator;
        if (coordinator.owner != YTMUPlaybackOwnerNone
            || self.nativePlaybackAudible
            || self.miniPlayerSuppressed) {
            collapseError = [self nativeMiniPlayerLayoutErrorWithCode:14
                                                          description:@"The native mini-player cannot be collapsed while playback is active."];
            return;
        }
        NSError *layoutError = nil;
        id layoutController = [self nativeMiniPlayerLayoutControllerWithError:&layoutError];
        if (layoutController == nil) {
            collapseError = layoutError;
            return;
        }

        NSUInteger generation = self.nativeMiniPlayerLayoutGeneration;
        __block BOOL dismissedLayoutSelected = NO;
        NSException *layoutException = nil;
        BOOL invokedSafely = YTMUPerformObjectiveCBlockSafely(^{
            SEL currentLayoutSelector = NSSelectorFromString(@"currentLayout");
            long long (*sendInteger)(id, SEL) = (void *)objc_msgSend;
            long long currentLayout = sendInteger(layoutController, currentLayoutSelector);
            if (currentLayout != YTMUNativeMiniPlayerDismissedLayout) {
                SEL dismissSelector = NSSelectorFromString(@"dismiss");
                void (*sendVoid)(id, SEL) = (void *)objc_msgSend;
                sendVoid(layoutController, dismissSelector);
            }

            // resetAndHide/dismiss may have installed a native property animator.
            // The complete card snapshot still covers the original hierarchy, so
            // finalize that hidden layout synchronously and without exposing a
            // second user-visible animation.
            SEL cancelAnimationSelector = NSSelectorFromString(@"cancelWatchViewAnimation");
            SEL switchLayoutSelector = NSSelectorFromString(@"switchToLayout:animated:");
            void (*sendVoid)(id, SEL) = (void *)objc_msgSend;
            void (*sendLayout)(id, SEL, long long, BOOL) = (void *)objc_msgSend;
            sendVoid(layoutController, cancelAnimationSelector);
            [UIView performWithoutAnimation:^{
                sendLayout(layoutController,
                           switchLayoutSelector,
                           YTMUNativeMiniPlayerDismissedLayout,
                           NO);
            }];
            currentLayout = sendInteger(layoutController, currentLayoutSelector);
            dismissedLayoutSelected =
                currentLayout == YTMUNativeMiniPlayerDismissedLayout;
        }, &layoutException);
        if (!invokedSafely || !dismissedLayoutSelected) {
            collapseError = [self nativeMiniPlayerLayoutErrorWithCode:15
                                                           description:layoutException.reason
                                                               ?: @"The YouTube Music mini-player layout did not dismiss."];
            return;
        }

        NSError *geometryError = nil;
        collapsed = [self nativeMiniPlayerVisualShellIsGeometricallyCollapsed:
            &geometryError];
        if (!collapsed) {
            collapseError = geometryError;
            return;
        }

        if (generation != self.nativeMiniPlayerLayoutGeneration
            || coordinator.owner != YTMUPlaybackOwnerNone
            || self.nativePlaybackAudible) {
            collapsed = NO;
            collapseError = [self nativeMiniPlayerLayoutErrorWithCode:16
                                                           description:@"A newer native playback session replaced the dismissal."];
            return;
        }
        self.nativeMiniPlayerVisualShellCollapsed = YES;
    }];

    if (error != NULL) *error = collapsed ? nil : collapseError;
    return collapsed;
}

- (void)prepareNativeMiniPlayerForPlaybackStart {
    [self performOnMainSynchronously:^{
        self.nativeMiniPlayerLayoutGeneration++;
        self.nativeMiniPlayerVisualShellCollapsed = NO;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YTMUNativePlaybackWillStartNotification
                          object:self];
    }];
}

- (void)nativePlaybackDidStart {
    [self performOnMainSynchronously:^{
        self.nativeMiniPlayerLayoutGeneration++;
        self.nativeMiniPlayerVisualShellCollapsed = NO;
        self.nativePlaybackAudible = YES;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:YTMUNativePlaybackWillStartNotification
                          object:self];
    }];
}

- (void)nativePlaybackDidPause {
    [self performOnMainSynchronously:^{ self.nativePlaybackAudible = NO; }];
}

- (void)nativePlaybackSessionDidEnd {
    [self performOnMainSynchronously:^{
        self.nativeMiniPlayerLayoutGeneration++;
        self.nativePlaybackAudible = NO;
        [self scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    }];
}

- (void)refreshNativePlaybackState {
    [self performOnMainSynchronously:^{
        BOOL wasPlaying = self.nativePlaybackAudible;
        BOOL isPlaying = [self watchControllerReportsPlayback];
        self.nativePlaybackAudible = isPlaying;
        if (isPlaying && !wasPlaying) {
            self.nativeMiniPlayerLayoutGeneration++;
            self.nativeMiniPlayerVisualShellCollapsed = NO;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:YTMUNativePlaybackWillStartNotification
                              object:self];
            [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackDidStart];
        } else if (!isPlaying && wasPlaying) {
            [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackDidPause];
        }
        [self scheduleNativeMiniPlayerVisualShellReassertionIfNeeded];
    }];
}

- (void)showOfflineEndedForNativeToast {
    [self performOnMainSynchronously:^{
        YTMUPerformObjectiveCBlockSafely(^{
            Class toastClass = NSClassFromString(@"YTMToastController");
            SEL selector = NSSelectorFromString(@"showMessage:");
            id toast = toastClass == Nil ? nil : [[toastClass alloc] init];
            if (toast != nil && [toast respondsToSelector:selector]) {
                void (*sendMessage)(id, SEL, id) = (void *)objc_msgSend;
                sendMessage(toast, selector, @"오프라인 재생 종료됨 · YouTube Music으로 전환");
            }
        }, NULL);
    }];
}

@end
