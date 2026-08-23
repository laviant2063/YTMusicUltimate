#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "YTMUOfflineLibrary.h"
#import "YTMUOfflinePlaybackPolicy.h"
#import "YTMUPlaybackCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const YTMUOfflinePlaybackDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const YTMUOfflinePlaybackProgressNotification;
FOUNDATION_EXPORT NSNotificationName const YTMUOfflinePlaybackErrorNotification;

@interface YTMUOfflinePlaybackManager : NSObject <YTMUOfflineSessionControlling>

@property (class, nonatomic, readonly) YTMUOfflinePlaybackManager *sharedManager;
@property (nonatomic, strong, readonly) AVPlayer *player;
@property (nonatomic, copy, readonly) NSArray<YTMUOfflineTrack *> *originalQueue;
@property (nonatomic, copy, readonly) NSArray<YTMUOfflineTrack *> *queue;
@property (nonatomic, assign, readonly) NSInteger currentIndex;
@property (nonatomic, strong, readonly, nullable) YTMUOfflineTrack *currentTrack;
@property (nonatomic, assign, readonly, getter=isShuffled) BOOL shuffled;
@property (nonatomic, assign, readonly, getter=isPlaying) BOOL playing;
@property (nonatomic, assign, readonly, getter=isOfflineSessionActive) BOOL offlineSessionActive;
@property (nonatomic, assign, readonly) YTMUOfflineRepeatMode repeatMode;
@property (nonatomic, assign, readonly) NSTimeInterval currentTime;
@property (nonatomic, assign, readonly) NSTimeInterval duration;
@property (nonatomic, assign, readonly) float playbackRate;
@property (nonatomic, strong, readonly, nullable) NSDate *sleepTimerEndDate;

- (void)playTracks:(NSArray<YTMUOfflineTrack *> *)tracks
    startingAtIndex:(NSInteger)index
             shuffle:(BOOL)shuffle;
- (void)playSingleTrack:(YTMUOfflineTrack *)track;
- (void)play;
- (void)pause;
- (void)togglePlayback;
- (void)next;
- (void)previous;
- (void)seekToTime:(NSTimeInterval)time;
- (void)toggleShuffle;
- (void)cycleRepeatMode;
- (void)playQueueIndex:(NSInteger)index;
- (void)moveQueueItemFromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)destinationIndex;
- (void)setPlaybackRate:(float)playbackRate;
- (void)setSleepTimerInterval:(NSTimeInterval)interval;
- (void)cancelSleepTimer;
- (void)endOfflineSessionWithReason:(YTMUOfflineSessionEndReason)reason;

@end

NS_ASSUME_NONNULL_END
