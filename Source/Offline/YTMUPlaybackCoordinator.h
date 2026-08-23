#import <Foundation/Foundation.h>

#import "YTMUPlaybackCoordinatorPolicy.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTMUOfflineSessionEndReason) {
    YTMUOfflineSessionEndReasonUserStop = 0,
    YTMUOfflineSessionEndReasonNativePlaybackStarted = 1,
    YTMUOfflineSessionEndReasonQueueRemoved = 2,
    YTMUOfflineSessionEndReasonFatalError = 3,
    YTMUOfflineSessionEndReasonSleepTimer = 4,
};

FOUNDATION_EXPORT NSNotificationName const YTMUPlaybackOwnershipDidChangeNotification;

@protocol YTMUNativePlaybackControlling <NSObject>
@property (nonatomic, assign, readonly, getter=isNativePlaybackAudible) BOOL nativePlaybackAudible;
- (BOOL)requestNativePauseForOfflinePlayback:(NSError **)error;
- (void)setNativeMiniPlayerSuppressed:(BOOL)suppressed;
- (void)showOfflineEndedForNativeToast;
@end

@protocol YTMUOfflineSessionControlling <NSObject>
@property (nonatomic, assign, readonly, getter=isOfflineSessionActive) BOOL offlineSessionActive;
- (void)endOfflineSessionWithReason:(YTMUOfflineSessionEndReason)reason;
@end

typedef void (^YTMUPlaybackOwnershipCompletion)(BOOL granted, NSError * _Nullable error);

@interface YTMUPlaybackCoordinator : NSObject

@property (class, nonatomic, readonly) YTMUPlaybackCoordinator *sharedCoordinator;
@property (nonatomic, assign, readonly) YTMUPlaybackOwner owner;
@property (nonatomic, assign, readonly) YTMUPlaybackOwner targetOwner;
@property (nonatomic, assign, readonly, getter=isNativeAudioPlaying) BOOL nativeAudioPlaying;
@property (nonatomic, assign, readonly) BOOL offlineControlsShouldBeActive;

- (instancetype)initWithNativeAdapter:(id<YTMUNativePlaybackControlling>)nativeAdapter
                     offlineController:(nullable id<YTMUOfflineSessionControlling>)offlineController NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)requestOfflinePlaybackWithCompletion:(YTMUPlaybackOwnershipCompletion)completion;
- (void)offlinePlaybackDidStart;
- (void)offlineSessionDidEndWithReason:(YTMUOfflineSessionEndReason)reason;
- (void)endOfflineSessionWithReason:(YTMUOfflineSessionEndReason)reason;

- (void)nativePlaybackWillStart;
- (void)nativePlaybackDidStart;
- (void)nativePlaybackDidPause;
- (void)nativePlaybackSessionDidEnd;

@end

NS_ASSUME_NONNULL_END

