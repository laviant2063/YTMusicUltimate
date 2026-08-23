#import "YTMUPlaybackCoordinator.h"

#import <objc/message.h>

NSNotificationName const YTMUPlaybackOwnershipDidChangeNotification =
    @"YTMUPlaybackOwnershipDidChangeNotification";

static NSString *const YTMUPlaybackCoordinatorErrorDomain = @"YTMUPlaybackCoordinatorErrorDomain";
static NSTimeInterval const YTMUNativePauseConfirmationTimeout = 1.0;

typedef NS_ENUM(NSInteger, YTMUPlaybackCoordinatorErrorCode) {
    YTMUPlaybackCoordinatorErrorNativePauseFailed = 1,
    YTMUPlaybackCoordinatorErrorNativePauseTimedOut = 2,
    YTMUPlaybackCoordinatorErrorTransitionCancelled = 3,
};

@interface YTMUNullNativePlaybackAdapter : NSObject <YTMUNativePlaybackControlling>
@end

@implementation YTMUNullNativePlaybackAdapter
- (BOOL)isNativePlaybackAudible { return NO; }
- (BOOL)requestNativePauseForOfflinePlayback:(NSError **)error {
    if (error != NULL) *error = nil;
    return YES;
}
- (void)setNativeMiniPlayerSuppressed:(__unused BOOL)suppressed {}
- (void)showOfflineEndedForNativeToast {}
@end

@interface YTMUPlaybackCoordinator ()
@property (nonatomic, strong) id<YTMUNativePlaybackControlling> nativeAdapter;
@property (nonatomic, strong, nullable) id<YTMUOfflineSessionControlling> injectedOfflineController;
@property (nonatomic, assign) YTMUPlaybackOwnershipState ownershipState;
@property (nonatomic, assign, readwrite, getter=isNativeAudioPlaying) BOOL nativeAudioPlaying;
@property (nonatomic, strong) NSMutableArray<YTMUPlaybackOwnershipCompletion> *pendingOfflineCompletions;
@property (nonatomic, assign) NSUInteger transitionGeneration;
@property (nonatomic, assign) BOOL shouldShowNativeTransitionToast;
@end

@implementation YTMUPlaybackCoordinator

+ (YTMUPlaybackCoordinator *)sharedCoordinator {
    static YTMUPlaybackCoordinator *coordinator = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<YTMUNativePlaybackControlling> nativeAdapter = nil;
        Class adapterClass = NSClassFromString(@"YTMUNativePlaybackAdapter");
        SEL sharedAdapterSelector = NSSelectorFromString(@"sharedAdapter");
        if (adapterClass != Nil && [adapterClass respondsToSelector:sharedAdapterSelector]) {
            id (*sendSharedAdapter)(id, SEL) = (void *)objc_msgSend;
            nativeAdapter = sendSharedAdapter(adapterClass, sharedAdapterSelector);
        }
        if (nativeAdapter == nil) {
            nativeAdapter = [[YTMUNullNativePlaybackAdapter alloc] init];
        }
        coordinator = [[YTMUPlaybackCoordinator alloc] initWithNativeAdapter:nativeAdapter
                                                           offlineController:nil];
    });
    return coordinator;
}

- (instancetype)initWithNativeAdapter:(id<YTMUNativePlaybackControlling>)nativeAdapter
                     offlineController:(id<YTMUOfflineSessionControlling>)offlineController {
    self = [super init];
    if (self) {
        _nativeAdapter = nativeAdapter ?: [[YTMUNullNativePlaybackAdapter alloc] init];
        _injectedOfflineController = offlineController;
        _ownershipState = YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwnerNone);
        _pendingOfflineCompletions = [NSMutableArray array];
    }
    return self;
}

- (id<YTMUOfflineSessionControlling>)offlineController {
    if (self.injectedOfflineController != nil) {
        return self.injectedOfflineController;
    }
    Class managerClass = NSClassFromString(@"YTMUOfflinePlaybackManager");
    SEL sharedManagerSelector = NSSelectorFromString(@"sharedManager");
    if (managerClass == Nil || ![managerClass respondsToSelector:sharedManagerSelector]) {
        return nil;
    }
    id (*sendSharedManager)(id, SEL) = (void *)objc_msgSend;
    id manager = sendSharedManager(managerClass, sharedManagerSelector);
    return [manager conformsToProtocol:@protocol(YTMUOfflineSessionControlling)] ? manager : nil;
}

- (YTMUPlaybackOwner)owner {
    return self.ownershipState.owner;
}

- (YTMUPlaybackOwner)targetOwner {
    return self.ownershipState.targetOwner;
}

- (BOOL)offlineControlsShouldBeActive {
    return YTMUPlaybackOfflineControlsAreActive(self.ownershipState);
}

- (void)performOnMainSynchronously:(dispatch_block_t)block {
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

- (void)postOwnershipChange {
    NSAssert(NSThread.isMainThread, @"Playback ownership must be mutated on the main thread.");
    [[NSNotificationCenter defaultCenter]
        postNotificationName:YTMUPlaybackOwnershipDidChangeNotification
                      object:self];
}

- (NSError *)errorWithCode:(YTMUPlaybackCoordinatorErrorCode)code description:(NSString *)description {
    return [NSError errorWithDomain:YTMUPlaybackCoordinatorErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (void)finishPendingOfflineTransitionGranted:(BOOL)granted error:(NSError *)error {
    NSAssert(NSThread.isMainThread, @"Playback ownership must be mutated on the main thread.");
    if (self.owner != YTMUPlaybackOwnerTransitioning
        || self.targetOwner != YTMUPlaybackOwnerOffline) {
        return;
    }

    self.transitionGeneration++;
    self.ownershipState = YTMUPlaybackCompleteTransition(self.ownershipState, granted);
    [self.nativeAdapter setNativeMiniPlayerSuppressed:granted];
    NSArray<YTMUPlaybackOwnershipCompletion> *completions = self.pendingOfflineCompletions.copy;
    [self.pendingOfflineCompletions removeAllObjects];
    [self postOwnershipChange];
    for (YTMUPlaybackOwnershipCompletion completion in completions) {
        completion(granted, error);
    }
}

- (void)requestOfflinePlaybackWithCompletion:(YTMUPlaybackOwnershipCompletion)completion {
    if (completion == nil) {
        return;
    }
    [self performOnMainSynchronously:^{
        if (self.owner == YTMUPlaybackOwnerOffline) {
            [self.nativeAdapter setNativeMiniPlayerSuppressed:YES];
            completion(YES, nil);
            return;
        }
        if (self.owner == YTMUPlaybackOwnerTransitioning
            && self.targetOwner == YTMUPlaybackOwnerOffline) {
            [self.pendingOfflineCompletions addObject:[completion copy]];
            return;
        }

        self.ownershipState = YTMUPlaybackBeginTransition(self.ownershipState,
                                                          YTMUPlaybackOwnerOffline);
        [self.pendingOfflineCompletions addObject:[completion copy]];
        [self postOwnershipChange];

        if (!self.nativeAdapter.nativePlaybackAudible) {
            self.nativeAudioPlaying = NO;
            [self finishPendingOfflineTransitionGranted:YES error:nil];
            return;
        }

        self.nativeAudioPlaying = YES;
        NSError *pauseError = nil;
        if (![self.nativeAdapter requestNativePauseForOfflinePlayback:&pauseError]) {
            NSError *error = pauseError ?: [self errorWithCode:YTMUPlaybackCoordinatorErrorNativePauseFailed
                                                   description:@"YouTube Music playback could not be stopped."];
            [self finishPendingOfflineTransitionGranted:NO error:error];
            return;
        }
        if (!self.nativeAdapter.nativePlaybackAudible) {
            self.nativeAudioPlaying = NO;
            [self finishPendingOfflineTransitionGranted:YES error:nil];
            return;
        }

        NSUInteger generation = ++self.transitionGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(YTMUNativePauseConfirmationTimeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != self.transitionGeneration
                || self.owner != YTMUPlaybackOwnerTransitioning
                || self.targetOwner != YTMUPlaybackOwnerOffline) {
                return;
            }
            if (!self.nativeAdapter.nativePlaybackAudible) {
                self.nativeAudioPlaying = NO;
                [self finishPendingOfflineTransitionGranted:YES error:nil];
                return;
            }
            NSError *error = [self errorWithCode:YTMUPlaybackCoordinatorErrorNativePauseTimedOut
                                      description:@"YouTube Music playback did not stop in time."];
            [self finishPendingOfflineTransitionGranted:NO error:error];
        });
    }];
}

- (void)offlinePlaybackDidStart {
    [self performOnMainSynchronously:^{
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwnerOffline);
        self.nativeAudioPlaying = NO;
        [self.nativeAdapter setNativeMiniPlayerSuppressed:YES];
        [self postOwnershipChange];
    }];
}

- (void)offlineSessionDidEndWithReason:(__unused YTMUOfflineSessionEndReason)reason {
    [self performOnMainSynchronously:^{
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackEndOfflineSession(self.ownershipState);
        [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
        if (self.pendingOfflineCompletions.count > 0) {
            NSError *error = [self errorWithCode:YTMUPlaybackCoordinatorErrorTransitionCancelled
                                      description:@"Offline playback was cancelled."];
            NSArray<YTMUPlaybackOwnershipCompletion> *completions = self.pendingOfflineCompletions.copy;
            [self.pendingOfflineCompletions removeAllObjects];
            for (YTMUPlaybackOwnershipCompletion completion in completions) {
                completion(NO, error);
            }
        }
        [self postOwnershipChange];
    }];
}

- (void)endOfflineSessionWithReason:(YTMUOfflineSessionEndReason)reason {
    [self performOnMainSynchronously:^{
        id<YTMUOfflineSessionControlling> offlineController = self.offlineController;
        BOOL hadOfflineSession = self.owner == YTMUPlaybackOwnerOffline
            || offlineController.offlineSessionActive;
        if (hadOfflineSession) {
            [offlineController endOfflineSessionWithReason:reason];
        }
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackEndOfflineSession(self.ownershipState);
        [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
        [self postOwnershipChange];
    }];
}

- (void)nativePlaybackWillStart {
    [self performOnMainSynchronously:^{
        if (self.owner == YTMUPlaybackOwnerTransitioning
            && self.targetOwner == YTMUPlaybackOwnerOffline) {
            NSError *error = [self errorWithCode:YTMUPlaybackCoordinatorErrorTransitionCancelled
                                      description:@"Offline playback was cancelled because YouTube Music started."];
            [self finishPendingOfflineTransitionGranted:NO error:error];
        }
        id<YTMUOfflineSessionControlling> offlineController = self.offlineController;
        BOOL hadOfflineSession = self.owner == YTMUPlaybackOwnerOffline
            || offlineController.offlineSessionActive;
        self.shouldShowNativeTransitionToast = self.shouldShowNativeTransitionToast || hadOfflineSession;
        if (self.owner == YTMUPlaybackOwnerTransitioning
            && self.targetOwner == YTMUPlaybackOwnerNative) {
            if (hadOfflineSession) {
                [offlineController endOfflineSessionWithReason:YTMUOfflineSessionEndReasonNativePlaybackStarted];
            }
            return;
        }
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackBeginTransition(self.ownershipState,
                                                          YTMUPlaybackOwnerNative);
        [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
        [self postOwnershipChange];
        if (hadOfflineSession) {
            [offlineController endOfflineSessionWithReason:YTMUOfflineSessionEndReasonNativePlaybackStarted];
        }
    }];
}

- (void)nativePlaybackDidStart {
    [self performOnMainSynchronously:^{
        id<YTMUOfflineSessionControlling> offlineController = self.offlineController;
        if (self.owner == YTMUPlaybackOwnerOffline || offlineController.offlineSessionActive) {
            [self nativePlaybackWillStart];
        }
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwnerNative);
        self.nativeAudioPlaying = YES;
        [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
        [self postOwnershipChange];
        if (self.shouldShowNativeTransitionToast) {
            self.shouldShowNativeTransitionToast = NO;
            [self.nativeAdapter showOfflineEndedForNativeToast];
        }
    }];
}

- (void)nativePlaybackDidPause {
    [self performOnMainSynchronously:^{
        self.nativeAudioPlaying = NO;
        if (self.owner == YTMUPlaybackOwnerTransitioning
            && self.targetOwner == YTMUPlaybackOwnerOffline
            && !self.nativeAdapter.nativePlaybackAudible) {
            [self finishPendingOfflineTransitionGranted:YES error:nil];
            return;
        }
        [self postOwnershipChange];
    }];
}

- (void)nativePlaybackSessionDidEnd {
    [self performOnMainSynchronously:^{
        self.nativeAudioPlaying = NO;
        if (self.owner == YTMUPlaybackOwnerNative) {
            self.ownershipState = YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwnerNone);
        }
        [self postOwnershipChange];
    }];
}

@end
