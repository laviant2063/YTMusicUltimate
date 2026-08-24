#import "YTMUNativePlaybackAdapter.h"

#import "YTMUObjectiveCExceptionGuard.h"

#import <objc/message.h>

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
        [self applyMiniPlayerSuppressionToController:controller];
    }];
}

- (void)setNativeMiniPlayerSuppressed:(BOOL)suppressed {
    [self performOnMainSynchronously:^{
        self.miniPlayerSuppressed = suppressed;
        for (UIViewController *controller in self.miniPlayerControllers.allObjects) {
            [self applyMiniPlayerSuppressionToController:controller];
        }
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

- (void)nativePlaybackDidStart {
    [self performOnMainSynchronously:^{ self.nativePlaybackAudible = YES; }];
}

- (void)nativePlaybackDidPause {
    [self performOnMainSynchronously:^{ self.nativePlaybackAudible = NO; }];
}

- (void)nativePlaybackSessionDidEnd {
    [self performOnMainSynchronously:^{ self.nativePlaybackAudible = NO; }];
}

- (void)refreshNativePlaybackState {
    [self performOnMainSynchronously:^{
        BOOL wasPlaying = self.nativePlaybackAudible;
        BOOL isPlaying = [self watchControllerReportsPlayback];
        self.nativePlaybackAudible = isPlaying;
        if (isPlaying && !wasPlaying) {
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
