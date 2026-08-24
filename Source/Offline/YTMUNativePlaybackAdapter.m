#import "YTMUNativePlaybackAdapter.h"

#import "YTMUNativeMiniPlayerVisibilityPolicy.h"
#import "YTMUObjectiveCExceptionGuard.h"

#import <objc/message.h>
#import <objc/runtime.h>

#include <string.h>

// YouTube Music 9.14.2's YTMWatchPageLayoutControllerImpl -dismiss sets layout 6.
static const long long YTMUNativeMiniPlayerDismissedLayout = 6;

@interface YTMUNativeMiniPlayerSnapshot : NSObject
@property (nonatomic, assign) BOOL hidden;
@property (nonatomic, assign) CGFloat alpha;
@property (nonatomic, assign) BOOL userInteractionEnabled;
@property (nonatomic, assign) CGAffineTransform transform;
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
@property (nonatomic, assign) BOOL nativeSessionActive;
@property (nonatomic, assign) BOOL nativeSessionEndConfirmed;
@property (nonatomic, assign, readwrite, getter=isNativeEmptyMiniPlayerCollapsed) BOOL nativeEmptyMiniPlayerCollapsed;
@property (nonatomic, assign) NSUInteger nativeMiniPlayerVisibilityGeneration;
- (YTMUNativeMiniPlayerVisibilityAction)nativeMiniPlayerVisibilityAction;
- (void)applyMiniPlayerSuppressionToController:(UIViewController *)controller;
- (void)applyNativeMiniPlayerVisibilityState;
- (void)restoreNativeMiniPlayerForPlaybackStart;
- (void)collapseEmptyNativeMiniPlayerAfterConfirmedSessionEnd;
- (BOOL)collapseEmptyNativeMiniPlayerAfterConfirmedSessionEndForGeneration:(NSUInteger)generation
                                                                      error:(NSError * _Nullable __autoreleasing * _Nullable)error;
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
    }
    return self;
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

- (void)registerPlayerViewController:(UIViewController *)controller {
    if (controller == nil) return;
    [self performOnMainSynchronously:^{ self.playerViewController = controller; }];
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
        [self applyNativeMiniPlayerVisibilityState];
    }];
}

- (YTMUNativeMiniPlayerVisibilityAction)nativeMiniPlayerVisibilityAction {
    YTMUPlaybackCoordinator *coordinator = YTMUPlaybackCoordinator.sharedCoordinator;
    return YTMUNativeMiniPlayerVisibilityActionForState(
        coordinator.owner,
        coordinator.targetOwner,
        self.nativeSessionActive,
        self.nativeSessionEndConfirmed,
        self.miniPlayerSuppressed,
        self.nativeEmptyMiniPlayerCollapsed);
}

- (void)applyMiniPlayerSuppressionToControllerWithoutThrowing:(UIViewController *)controller {
    if (controller == nil || !controller.isViewLoaded) return;
    UIView *view = controller.view;
    YTMUNativeMiniPlayerVisibilityAction action = [self nativeMiniPlayerVisibilityAction];
    if (action == YTMUNativeMiniPlayerVisibilityActionSuppressForOffline) {
        if ([self.miniPlayerSnapshots objectForKey:controller] == nil) {
            YTMUNativeMiniPlayerSnapshot *snapshot = [[YTMUNativeMiniPlayerSnapshot alloc] init];
            snapshot.hidden = view.hidden;
            snapshot.alpha = view.alpha;
            snapshot.userInteractionEnabled = view.userInteractionEnabled;
            snapshot.transform = view.transform;
            [self.miniPlayerSnapshots setObject:snapshot forKey:controller];
        }
        view.hidden = YES;
        view.alpha = 0;
        view.userInteractionEnabled = NO;
        return;
    }

    YTMUNativeMiniPlayerSnapshot *snapshot = [self.miniPlayerSnapshots objectForKey:controller];
    // Offline suppression and an ended native session are independent. Keep the
    // suppression snapshot hidden until a real native playback start restores it.
    BOOL shouldKeepSuppressionSnapshotHidden =
        action == YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed;
    if (snapshot != nil && !shouldKeepSuppressionSnapshotHidden) {
        view.hidden = snapshot.hidden;
        view.alpha = snapshot.alpha;
        view.userInteractionEnabled = snapshot.userInteractionEnabled;
        view.transform = snapshot.transform;
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
        [self applyMiniPlayerSuppressionToController:controller];
        if ([self nativeMiniPlayerVisibilityAction]
            == YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed) {
            [self collapseEmptyNativeMiniPlayerAfterConfirmedSessionEnd];
        }
    }];
}

- (void)setNativeMiniPlayerSuppressed:(BOOL)suppressed {
    [self performOnMainSynchronously:^{
        if (self.miniPlayerSuppressed == suppressed) return;
        self.miniPlayerSuppressed = suppressed;
        [self applyNativeMiniPlayerVisibilityState];
    }];
}

- (BOOL)isNativeMiniPlayerSuppressed {
    __block BOOL suppressed = NO;
    [self performOnMainSynchronously:^{ suppressed = self.miniPlayerSuppressed; }];
    return suppressed;
}

- (NSError *)nativeMiniPlayerErrorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:@"YTMUNativePlaybackAdapterErrorDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (id)nativeLayoutControllerForWatchController:(UIViewController *)watch
                                          error:(NSError **)error {
    Class watchClass = NSClassFromString(@"YTMWatchViewController");
    if (watch == nil || watchClass == Nil || ![watch isKindOfClass:watchClass]) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerErrorWithCode:10
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
            *error = [self nativeMiniPlayerErrorWithCode:11
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
            *error = [self nativeMiniPlayerErrorWithCode:12
                                              description:resolutionException.reason
                                                  ?: @"The YouTube Music mini-player layout could not be resolved."];
        }
        return nil;
    }

    SEL dismissSelector = NSSelectorFromString(@"dismiss");
    SEL currentLayoutSelector = NSSelectorFromString(@"currentLayout");
    Method dismissMethod = class_getInstanceMethod([layoutController class], dismissSelector);
    Method currentLayoutMethod = class_getInstanceMethod([layoutController class], currentLayoutSelector);
    const char *dismissEncoding = dismissMethod == NULL ? NULL : method_getTypeEncoding(dismissMethod);
    const char *currentLayoutEncoding = currentLayoutMethod == NULL
        ? NULL
        : method_getTypeEncoding(currentLayoutMethod);
    if (![layoutController respondsToSelector:dismissSelector]
        || ![layoutController respondsToSelector:currentLayoutSelector]
        || dismissEncoding == NULL
        || currentLayoutEncoding == NULL
        || strcmp(dismissEncoding, "v16@0:8") != 0
        || strcmp(currentLayoutEncoding, "q16@0:8") != 0) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerErrorWithCode:13
                                              description:@"This YouTube Music version has incompatible mini-player layout commands."];
        }
        return nil;
    }
    if (error != NULL) *error = nil;
    return layoutController;
}

- (BOOL)collapseEmptyNativeMiniPlayerAfterConfirmedSessionEndForGeneration:(NSUInteger)generation
                                                                      error:(NSError **)error {
    YTMUNativeMiniPlayerVisibilityAction action = [self nativeMiniPlayerVisibilityAction];
    if (generation != self.nativeMiniPlayerVisibilityGeneration
        || action != YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed) {
        if (error != NULL) *error = nil;
        return NO;
    }

    NSError *layoutError = nil;
    id layoutController = [self nativeLayoutControllerForWatchController:self.watchViewController
                                                                    error:&layoutError];
    if (layoutController == nil) {
        if (error != NULL) *error = layoutError;
        return NO;
    }

    __block BOOL collapsed = NO;
    NSException *collapseException = nil;
    BOOL invokedSafely = YTMUPerformObjectiveCBlockSafely(^{
        SEL currentLayoutSelector = NSSelectorFromString(@"currentLayout");
        long long (*sendInteger)(id, SEL) = (void *)objc_msgSend;
        long long currentLayout = sendInteger(layoutController, currentLayoutSelector);
        if (currentLayout != YTMUNativeMiniPlayerDismissedLayout) {
            SEL dismissSelector = NSSelectorFromString(@"dismiss");
            void (*sendVoid)(id, SEL) = (void *)objc_msgSend;
            sendVoid(layoutController, dismissSelector);
            currentLayout = sendInteger(layoutController, currentLayoutSelector);
        }
        collapsed = currentLayout == YTMUNativeMiniPlayerDismissedLayout;
    }, &collapseException);
    if (!invokedSafely || !collapsed) {
        if (error != NULL) {
            *error = [self nativeMiniPlayerErrorWithCode:14
                                              description:collapseException.reason
                                                  ?: @"The YouTube Music mini-player could not be collapsed."];
        }
        return NO;
    }

    if (generation != self.nativeMiniPlayerVisibilityGeneration
        || [self nativeMiniPlayerVisibilityAction]
            != YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed) {
        if (error != NULL) *error = nil;
        return NO;
    }
    self.nativeEmptyMiniPlayerCollapsed = YES;
    if (error != NULL) *error = nil;
    return YES;
}

- (void)collapseEmptyNativeMiniPlayerAfterConfirmedSessionEnd {
    NSAssert(NSThread.isMainThread, @"Native mini-player layout must be updated on the main thread.");
    NSUInteger generation = self.nativeMiniPlayerVisibilityGeneration;
    NSError *collapseError = nil;
    BOOL collapsed = [self collapseEmptyNativeMiniPlayerAfterConfirmedSessionEndForGeneration:generation
                                                                                         error:&collapseError];
    if (!collapsed && collapseError != nil) {
        NSLog(@"[YTMusicUltimate] Native empty mini-player collapse failed: %@",
              collapseError.localizedDescription);
    }
}

- (void)applyNativeMiniPlayerVisibilityState {
    NSAssert(NSThread.isMainThread, @"Native mini-player visibility must be updated on the main thread.");
    YTMUNativeMiniPlayerVisibilityAction action = [self nativeMiniPlayerVisibilityAction];
    for (UIViewController *controller in self.miniPlayerControllers.allObjects) {
        [self applyMiniPlayerSuppressionToController:controller];
    }
    if (action == YTMUNativeMiniPlayerVisibilityActionEnsureEmptyShellCollapsed) {
        [self collapseEmptyNativeMiniPlayerAfterConfirmedSessionEnd];
    } else if (action == YTMUNativeMiniPlayerVisibilityActionRestoreForNativePlayback) {
        self.nativeEmptyMiniPlayerCollapsed = NO;
    }
}

- (void)restoreNativeMiniPlayerForPlaybackStart {
    NSAssert(NSThread.isMainThread, @"Native mini-player restore must run on the main thread.");
    self.nativeMiniPlayerVisibilityGeneration++;
    self.nativeSessionActive = YES;
    self.nativeSessionEndConfirmed = NO;
    self.nativeEmptyMiniPlayerCollapsed = NO;
    [self applyNativeMiniPlayerVisibilityState];
}

- (void)prepareNativeMiniPlayerForPlaybackStart {
    [self performOnMainSynchronously:^{
        [self restoreNativeMiniPlayerForPlaybackStart];
    }];
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

        NSError *layoutError = nil;
        if ([self nativeLayoutControllerForWatchController:watch error:&layoutError] == nil) {
            requestError = layoutError;
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
        if (ended) {
            self.nativeSessionActive = NO;
            self.nativeSessionEndConfirmed = YES;
            NSUInteger generation = self.nativeMiniPlayerVisibilityGeneration;
            NSError *collapseError = nil;
            if (![self collapseEmptyNativeMiniPlayerAfterConfirmedSessionEndForGeneration:generation
                                                                                     error:&collapseError]) {
                ended = NO;
                requestError = collapseError
                    ?: [self nativeMiniPlayerErrorWithCode:15
                                               description:@"YouTube Music stopped, but its empty mini-player could not be collapsed."];
            }
        }
        if (!ended) {
            requestError = requestError
                ?: [self nativeMiniPlayerErrorWithCode:8
                                           description:@"YouTube Music playback was not confirmed as stopped."];
        }
    }];

    if (error != NULL) {
        *error = ended ? nil : requestError;
    }
    return ended;
}

- (void)nativePlaybackDidStart {
    [self performOnMainSynchronously:^{
        [self restoreNativeMiniPlayerForPlaybackStart];
        self.nativePlaybackAudible = YES;
    }];
}

- (void)nativePlaybackDidPause {
    [self performOnMainSynchronously:^{ self.nativePlaybackAudible = NO; }];
}

- (void)nativePlaybackSessionDidEnd {
    [self performOnMainSynchronously:^{
        self.nativePlaybackAudible = NO;
        self.nativeSessionActive = NO;
        self.nativeSessionEndConfirmed = YES;
        self.nativeEmptyMiniPlayerCollapsed = NO;
        NSUInteger generation = ++self.nativeMiniPlayerVisibilityGeneration;
        // resetAndHide internally calls reset and then collapse. Let that stack
        // unwind before moving from its visible collapsed layout to dismissed.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.nativeMiniPlayerVisibilityGeneration) return;
            [self applyNativeMiniPlayerVisibilityState];
        });
    }];
}

- (void)refreshNativePlaybackState {
    [self performOnMainSynchronously:^{
        BOOL wasPlaying = self.nativePlaybackAudible;
        BOOL isPlaying = [self watchControllerReportsPlayback];
        self.nativePlaybackAudible = isPlaying;
        if (isPlaying && !wasPlaying) {
            [self restoreNativeMiniPlayerForPlaybackStart];
            self.nativePlaybackAudible = YES;
            [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackDidStart];
        } else if (!isPlaying && wasPlaying) {
            [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackDidPause];
        }
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
