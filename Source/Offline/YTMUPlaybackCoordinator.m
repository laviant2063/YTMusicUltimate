#import "YTMUPlaybackCoordinator.h"

#import "YTMUObjectiveCExceptionGuard.h"
#import "YTMUOfflineDiagnostics.h"

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
- (void)showNativeTransitionFailureWithMessage:(__unused NSString *)message {}
@end

@interface YTMUPlaybackCoordinator ()
@property (nonatomic, strong) id<YTMUNativePlaybackControlling> nativeAdapter;
@property (nonatomic, strong, nullable) id<YTMUOfflineSessionControlling> injectedOfflineController;
@property (nonatomic, assign) YTMUPlaybackOwnershipState ownershipState;
@property (nonatomic, assign, readwrite, getter=isNativeAudioPlaying) BOOL nativeAudioPlaying;
@property (nonatomic, strong) NSMutableArray<YTMUPlaybackOwnershipCompletion> *pendingOfflineCompletions;
@property (nonatomic, assign) NSUInteger transitionGeneration;
@property (nonatomic, assign) BOOL shouldShowNativeTransitionToast;
@property (nonatomic, assign) BOOL nativePreparationInProgress;
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
    YTMUOfflineDiagnosticsLog(@"ownership-offline", nil, granted ? @"granted" : @"rejected");
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
        __block NSError * __strong pauseError = nil;
        __block BOOL pauseAccepted = NO;
        NSException *pauseException = nil;
        YTMUOfflineDiagnosticsLog(@"native-stop-request", nil, @"requested-for-offline");
        BOOL pauseRequestedSafely = YTMUPerformObjectiveCBlockSafely(^{
            pauseAccepted = [self.nativeAdapter requestNativePauseForOfflinePlayback:&pauseError];
        }, &pauseException);
        if (!pauseRequestedSafely || !pauseAccepted) {
            YTMUOfflineDiagnosticsLogException(@"native-stop-request", nil, pauseException);
            NSError *error = pauseError ?: [self errorWithCode:YTMUPlaybackCoordinatorErrorNativePauseFailed
                                                   description:@"YouTube Music playback could not be stopped."];
            [self finishPendingOfflineTransitionGranted:NO error:error];
            return;
        }
        if (!self.nativeAdapter.nativePlaybackAudible) {
            YTMUOfflineDiagnosticsLog(@"native-stop-result", nil, @"confirmed");
            self.nativeAudioPlaying = NO;
            [self finishPendingOfflineTransitionGranted:YES error:nil];
            return;
        }
        YTMUOfflineDiagnosticsLog(@"native-stop-result", nil, @"awaiting-confirmation");

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
                YTMUOfflineDiagnosticsLog(@"native-stop-result", nil, @"confirmed-after-wait");
                self.nativeAudioPlaying = NO;
                [self finishPendingOfflineTransitionGranted:YES error:nil];
                return;
            }
            YTMUOfflineDiagnosticsLog(@"native-stop-result", nil, @"timed-out");
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
        YTMUOfflineDiagnosticsLog(@"ownership", nil, @"offline");
        [self postOwnershipChange];
    }];
}

- (void)offlineSessionDidEndWithReason:(__unused YTMUOfflineSessionEndReason)reason {
    [self performOnMainSynchronously:^{
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackEndOfflineSession(self.ownershipState);
        [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
        YTMUOfflineDiagnosticsLog(@"ownership-offline", nil, @"session-ended");
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
        BOOL stateCanContainOfflinePlayback = self.owner == YTMUPlaybackOwnerOffline
            || (self.owner == YTMUPlaybackOwnerTransitioning
                && (self.targetOwner == YTMUPlaybackOwnerOffline
                    || self.ownershipState.fallbackOwner == YTMUPlaybackOwnerOffline));
        if (!stateCanContainOfflinePlayback) return;

        id<YTMUOfflineSessionControlling> offlineController = self.offlineController;
        __block BOOL hadOfflineSession = self.owner == YTMUPlaybackOwnerOffline;
        NSException *inspectionException = nil;
        BOOL inspectedSafely = offlineController == nil
            || YTMUPerformObjectiveCBlockSafely(^{
                hadOfflineSession = hadOfflineSession || offlineController.offlineSessionActive;
            }, &inspectionException);
        if (!inspectedSafely) {
            YTMUOfflineDiagnosticsLogException(@"offline-session-inspection", nil, inspectionException);
            return;
        }
        if (hadOfflineSession) {
            if (offlineController == nil) {
                YTMUOfflineDiagnosticsLog(@"offline-session-end", nil, @"controller-unavailable");
                return;
            }
            NSException *endException = nil;
            BOOL endedSafely = YTMUPerformObjectiveCBlockSafely(^{
                [offlineController endOfflineSessionWithReason:reason];
            }, &endException);
            if (!endedSafely) {
                YTMUOfflineDiagnosticsLogException(@"offline-session-end", nil, endException);
                return;
            }
        }
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackEndOfflineSession(self.ownershipState);
        [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
        YTMUOfflineDiagnosticsLog(@"offline-session-end", nil, @"completed");
        [self postOwnershipChange];
    }];
}

- (BOOL)prepareForNativePlayback {
    __block BOOL nativePlaybackAllowed = NO;
    [self performOnMainSynchronously:^{
        if (self.owner == YTMUPlaybackOwnerTransitioning
            && self.targetOwner == YTMUPlaybackOwnerOffline) {
            NSError *error = [self errorWithCode:YTMUPlaybackCoordinatorErrorTransitionCancelled
                                      description:@"Offline playback was cancelled because YouTube Music started."];
            [self finishPendingOfflineTransitionGranted:NO error:error];
        }

        if (self.owner == YTMUPlaybackOwnerNative
            || (self.owner == YTMUPlaybackOwnerTransitioning
                && self.targetOwner == YTMUPlaybackOwnerNative)) {
            nativePlaybackAllowed = !self.nativePreparationInProgress;
            if (!nativePlaybackAllowed) {
                YTMUOfflineDiagnosticsLog(@"ownership-transition", nil,
                                          @"duplicate-native-request-blocked");
            }
            return;
        }

        if (self.owner == YTMUPlaybackOwnerNone) {
            self.transitionGeneration++;
            self.ownershipState = YTMUPlaybackBeginTransition(self.ownershipState,
                                                              YTMUPlaybackOwnerNative);
            YTMUOfflineDiagnosticsLog(@"ownership-transition", nil, @"none-to-native");
            [self postOwnershipChange];
            nativePlaybackAllowed = YES;
            return;
        }

        id<YTMUOfflineSessionControlling> offlineController = self.offlineController;
        if (offlineController == nil) {
            [self.nativeAdapter showNativeTransitionFailureWithMessage:
                @"오프라인 재생을 안전하게 종료할 수 없어 YouTube Music 재생을 취소했습니다."];
            YTMUOfflineDiagnosticsLog(@"offline-to-native", nil, @"controller-unavailable");
            return;
        }

        __block BOOL hadOfflineSession = self.owner == YTMUPlaybackOwnerOffline;
        NSException *inspectionException = nil;
        BOOL inspectedSafely = YTMUPerformObjectiveCBlockSafely(^{
            hadOfflineSession = hadOfflineSession || offlineController.offlineSessionActive;
        }, &inspectionException);
        if (!inspectedSafely) {
            YTMUOfflineDiagnosticsLogException(@"offline-to-native-inspection", nil, inspectionException);
            [self.nativeAdapter showNativeTransitionFailureWithMessage:
                @"오프라인 재생 상태를 확인할 수 없어 YouTube Music 재생을 취소했습니다."];
            return;
        }

        YTMUPlaybackOwnershipState previousOwnershipState = self.ownershipState;
        self.nativePreparationInProgress = YES;
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackBeginTransition(self.ownershipState,
                                                          YTMUPlaybackOwnerNative);
        YTMUOfflineDiagnosticsLog(@"ownership-transition", nil, @"offline-to-native");
        [self postOwnershipChange];
        if (!hadOfflineSession) {
            [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
            self.nativePreparationInProgress = NO;
            nativePlaybackAllowed = YES;
            return;
        }

        NSException *endException = nil;
        BOOL endedSafely = YTMUPerformObjectiveCBlockSafely(^{
            [offlineController endOfflineSessionWithReason:YTMUOfflineSessionEndReasonNativePlaybackStarted];
        }, &endException);
        __block BOOL offlineStillActive = YES;
        NSException *verificationException = nil;
        BOOL verifiedSafely = endedSafely && YTMUPerformObjectiveCBlockSafely(^{
            offlineStillActive = offlineController.offlineSessionActive;
        }, &verificationException);

        if (!endedSafely || !verifiedSafely || offlineStillActive) {
            YTMUOfflineDiagnosticsLogException(@"offline-to-native-end", nil,
                                               endException ?: verificationException);
            self.transitionGeneration++;
            self.ownershipState = previousOwnershipState;
            self.nativePreparationInProgress = NO;
            [self.nativeAdapter setNativeMiniPlayerSuppressed:YES];
            [self postOwnershipChange];
            [self.nativeAdapter showNativeTransitionFailureWithMessage:
                @"오프라인 재생을 안전하게 종료할 수 없어 YouTube Music 재생을 취소했습니다."];
            YTMUOfflineDiagnosticsLog(@"offline-to-native", nil, @"rejected");
            return;
        }

        self.shouldShowNativeTransitionToast = YES;
        if (self.owner == YTMUPlaybackOwnerTransitioning
            && self.targetOwner == YTMUPlaybackOwnerNative
            && self.ownershipState.fallbackOwner == YTMUPlaybackOwnerOffline) {
            self.ownershipState = YTMUPlaybackEndOfflineSession(self.ownershipState);
            [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
            [self postOwnershipChange];
        }
        YTMUOfflineDiagnosticsLog(@"offline-to-native", nil, @"offline-ended-before-native");
        self.nativePreparationInProgress = NO;
        nativePlaybackAllowed = YES;
    }];
    return nativePlaybackAllowed;
}

- (void)nativePlaybackWillStart {
    [self prepareForNativePlayback];
}

- (void)nativePlaybackDidStart {
    [self performOnMainSynchronously:^{
        if (self.nativePreparationInProgress) {
            __block BOOL pauseAccepted = NO;
            NSException *pauseException = nil;
            BOOL pauseRequestedSafely = YTMUPerformObjectiveCBlockSafely(^{
                pauseAccepted = [self.nativeAdapter requestNativePauseForOfflinePlayback:NULL];
            }, &pauseException);
            if (!pauseRequestedSafely) {
                YTMUOfflineDiagnosticsLogException(@"unexpected-native-start", nil, pauseException);
            } else {
                YTMUOfflineDiagnosticsLog(@"unexpected-native-start", nil,
                                          pauseAccepted ? @"pause-requested" : @"pause-rejected");
            }
            self.nativeAudioPlaying = self.nativeAdapter.nativePlaybackAudible;
            [self postOwnershipChange];
            return;
        }
        if (self.owner == YTMUPlaybackOwnerOffline
            || (self.owner == YTMUPlaybackOwnerTransitioning
            && self.targetOwner == YTMUPlaybackOwnerOffline)) {
            if (![self prepareForNativePlayback]) {
                YTMUPerformObjectiveCBlockSafely(^{
                    [self.nativeAdapter requestNativePauseForOfflinePlayback:NULL];
                }, NULL);
                self.nativeAudioPlaying = self.nativeAdapter.nativePlaybackAudible;
                [self postOwnershipChange];
                return;
            }
        }
        self.transitionGeneration++;
        self.ownershipState = YTMUPlaybackOwnershipStateMake(YTMUPlaybackOwnerNative);
        self.nativeAudioPlaying = YES;
        [self.nativeAdapter setNativeMiniPlayerSuppressed:NO];
        YTMUOfflineDiagnosticsLog(@"ownership", nil, @"native");
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
