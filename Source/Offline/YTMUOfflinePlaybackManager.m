#import "YTMUOfflinePlaybackManager.h"

#import "YTMUObjectiveCExceptionGuard.h"
#import "YTMUOfflineDiagnostics.h"

#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

#include <math.h>
#include <stdlib.h>

NSNotificationName const YTMUOfflinePlaybackDidChangeNotification = @"YTMUOfflinePlaybackDidChangeNotification";
NSNotificationName const YTMUOfflinePlaybackProgressNotification = @"YTMUOfflinePlaybackProgressNotification";
NSNotificationName const YTMUOfflinePlaybackErrorNotification = @"YTMUOfflinePlaybackErrorNotification";

static NSError *YTMUOfflineErrorFromException(NSException *exception, NSString *operation) {
    NSString *reason = exception.reason.length > 0 ? exception.reason : exception.name;
    NSString *description = [NSString stringWithFormat:@"%@ failed: %@", operation, reason ?: @"unknown error"];
    return [NSError errorWithDomain:@"YTMUOfflinePlaybackRuntimeErrorDomain"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static void YTMULogContainedException(NSException *exception, NSString *operation) {
    if (exception == nil) return;
    YTMUOfflineDiagnosticsLogException(operation, nil, exception);
}

@interface YTMUOfflinePlaybackManager ()
@property (nonatomic, strong, readwrite) AVPlayer *player;
@property (nonatomic, copy, readwrite) NSArray<YTMUOfflineTrack *> *originalQueue;
@property (nonatomic, copy, readwrite) NSArray<YTMUOfflineTrack *> *queue;
@property (nonatomic, assign, readwrite) NSInteger currentIndex;
@property (nonatomic, assign, readwrite, getter=isShuffled) BOOL shuffled;
@property (nonatomic, assign, readwrite, getter=isPlaying) BOOL playing;
@property (nonatomic, assign, readwrite, getter=isOfflineSessionActive) BOOL offlineSessionActive;
@property (nonatomic, assign, readwrite) YTMUOfflineRepeatMode repeatMode;
@property (nonatomic, assign, readwrite) float playbackRate;
@property (nonatomic, strong, readwrite, nullable) NSDate *sleepTimerEndDate;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, assign) BOOL resumeAfterInterruption;
@property (nonatomic, strong, nullable) NSURL *loadedAudioURL;
@property (nonatomic, strong, nullable) NSTimer *sleepTimer;
@property (nonatomic, assign) NSUInteger playbackRequestGeneration;
@property (nonatomic, strong, nullable) MPNowPlayingSession *nowPlayingSession API_AVAILABLE(ios(16.0));
@property (nonatomic, strong, nullable) MPNowPlayingInfoCenter *offlineNowPlayingInfoCenter;
@property (nonatomic, strong, nullable) MPRemoteCommandCenter *offlineRemoteCommandCenter;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *remoteCommandRegistrations;
- (void)requestOfflinePlaybackWithCompletionSafely:(YTMUPlaybackOwnershipCompletion)completion;
- (void)loadCurrentTrackAndPlayUnchecked:(BOOL)autoplay preservingTime:(NSTimeInterval)time;
@end

@implementation YTMUOfflinePlaybackManager

+ (YTMUOfflinePlaybackManager *)sharedManager {
    static YTMUOfflinePlaybackManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[YTMUOfflinePlaybackManager alloc] initPrivate];
    });
    return manager;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _player = [[AVPlayer alloc] init];
        _originalQueue = @[];
        _queue = @[];
        _currentIndex = NSNotFound;
        _repeatMode = YTMUOfflineRepeatModeOff;
        _playbackRate = 1.0;
        _remoteCommandRegistrations = [NSMutableArray array];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemDidFinish:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemFailed:)
                                                     name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(libraryDidChange:)
                                                     name:YTMUOfflineLibraryDidChangeNotification
                                                   object:YTMUOfflineLibrary.sharedLibrary];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(audioSessionInterrupted:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:AVAudioSession.sharedInstance];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(audioRouteChanged:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:AVAudioSession.sharedInstance];

        __weak typeof(self) weakSelf = self;
        _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC)
                                                              queue:dispatch_get_main_queue()
                                                         usingBlock:^(__unused CMTime time) {
            [weakSelf updateNowPlayingInfo];
            [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflinePlaybackProgressNotification
                                                                object:weakSelf];
        }];
    }
    return self;
}

- (instancetype)init {
    return YTMUOfflinePlaybackManager.sharedManager;
}

- (void)dealloc {
    if (self.timeObserver != nil) {
        [self.player removeTimeObserver:self.timeObserver];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (YTMUOfflineTrack *)currentTrack {
    if (self.currentIndex == NSNotFound || self.currentIndex < 0
        || self.currentIndex >= (NSInteger)self.queue.count) {
        return nil;
    }
    return self.queue[(NSUInteger)self.currentIndex];
}

- (NSTimeInterval)currentTime {
    NSTimeInterval value = CMTimeGetSeconds(self.player.currentTime);
    return isfinite(value) && value >= 0 ? value : 0;
}

- (NSTimeInterval)duration {
    NSTimeInterval value = CMTimeGetSeconds(self.player.currentItem.duration);
    return isfinite(value) && value >= 0 ? value : 0;
}

- (NSURL *)audioURLForTrack:(YTMUOfflineTrack *)track {
    return [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL URLByAppendingPathComponent:track.fileName];
}

- (UIImage *)artworkForTrack:(YTMUOfflineTrack *)track {
    if (track.artworkFileName.length == 0) {
        return nil;
    }
    NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL
        URLByAppendingPathComponent:track.artworkFileName];
    return [UIImage imageWithContentsOfFile:url.path];
}

- (void)postChange {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self postChange]; });
        return;
    }
    [self updateNowPlayingInfo];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflinePlaybackDidChangeNotification object:self];
}

- (void)postErrorMessage:(NSString *)message error:(nullable NSError *)error {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self postErrorMessage:message error:error]; });
        return;
    }
    NSMutableDictionary *userInfo = [@{@"message": message ?: @"Unable to play this downloaded song."} mutableCopy];
    if (error != nil) {
        userInfo[@"error"] = error;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflinePlaybackErrorNotification
                                                        object:self
                                                      userInfo:userInfo];
}

- (BOOL)activateAudioSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    BOOL configured = [session setCategory:AVAudioSessionCategoryPlayback
                                      mode:AVAudioSessionModeDefault
                                   options:0
                                     error:&error];
    if (configured) {
        configured = [session setActive:YES error:&error];
    }
    if (!configured) {
        [self postErrorMessage:@"Offline audio could not start." error:error];
    }
    return configured;
}

- (void)deactivateAudioSessionIfIdle {
    if (self.playing) {
        return;
    }
    [AVAudioSession.sharedInstance setActive:NO
                                 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                       error:nil];
}

- (void)performOnMainSynchronously:(dispatch_block_t)block {
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

- (void)requestOfflinePlaybackWithCompletionSafely:(YTMUPlaybackOwnershipCompletion)completion {
    NSException *ownershipException = nil;
    BOOL requestStartedSafely = YTMUPerformObjectiveCBlockSafely(^{
        [YTMUPlaybackCoordinator.sharedCoordinator requestOfflinePlaybackWithCompletion:completion];
    }, &ownershipException);
    if (requestStartedSafely) return;

    YTMULogContainedException(ownershipException, @"offline playback ownership transition");
    YTMUPerformObjectiveCBlockSafely(^{
        [YTMUPlaybackCoordinator.sharedCoordinator
            offlineSessionDidEndWithReason:YTMUOfflineSessionEndReasonFatalError];
    }, NULL);
    YTMUPerformObjectiveCBlockSafely(^{
        [self postErrorMessage:@"Offline playback controls could not be activated safely."
                         error:YTMUOfflineErrorFromException(ownershipException, @"Playback ownership")];
    }, NULL);
}

- (void)beginPlayingAfterOwnershipGranted {
    NSString *trackID = self.currentTrack.trackID;
    if (self.currentTrack == nil || self.player.currentItem == nil) {
        YTMUOfflineDiagnosticsLog(@"play-request", trackID, @"rejected-no-current-item");
        [self endOfflineSessionWithReason:YTMUOfflineSessionEndReasonFatalError];
        [self postErrorMessage:@"Choose a downloaded song first." error:nil];
        return;
    }

    __block BOOL audioSessionActivated = NO;
    NSException *startException = nil;
    BOOL startCompletedSafely = YTMUPerformObjectiveCBlockSafely(^{
        self.offlineSessionActive = YES;
        YTMUOfflineDiagnosticsLog(@"audio-session", trackID, @"activation-requested");
        audioSessionActivated = [self activateAudioSession];
        if (!audioSessionActivated) return;
        [self activateOfflineMediaControls];
        if (self.duration > 0 && self.currentTime >= self.duration - 0.25) {
            [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        }
        YTMUOfflineDiagnosticsLog(@"play-request", trackID, @"avplayer-play");
        [self.player playImmediatelyAtRate:self.playbackRate];
        self.playing = YES;
        [YTMUPlaybackCoordinator.sharedCoordinator offlinePlaybackDidStart];
        YTMUOfflineDiagnosticsLog(@"play-request", trackID, @"started");
        [self postChange];
    }, &startException);

    if (!startCompletedSafely) {
        YTMUOfflineDiagnosticsLogException(@"play-request", trackID, startException);
        YTMULogContainedException(startException, @"offline playback startup");
        YTMUPerformObjectiveCBlockSafely(^{
            [self endOfflineSessionWithReason:YTMUOfflineSessionEndReasonFatalError];
        }, NULL);
        YTMUPerformObjectiveCBlockSafely(^{
            [self postErrorMessage:@"Offline playback could not start safely."
                             error:YTMUOfflineErrorFromException(startException, @"Offline playback")];
        }, NULL);
        return;
    }
    if (!audioSessionActivated) {
        [self endOfflineSessionWithReason:YTMUOfflineSessionEndReasonFatalError];
    }
}

- (void)playTracks:(NSArray<YTMUOfflineTrack *> *)tracks
    startingAtIndex:(NSInteger)index
             shuffle:(BOOL)shuffle {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self playTracks:tracks startingAtIndex:index shuffle:shuffle];
        });
        return;
    }

    YTMUOfflineTrack *selectedTrack = index >= 0 && index < (NSInteger)tracks.count
        ? tracks[(NSUInteger)index] : tracks.firstObject;
    BOOL selectedFileExists = selectedTrack != nil
        && [[NSFileManager defaultManager] fileExistsAtPath:[self audioURLForTrack:selectedTrack].path];
    YTMUOfflineDiagnosticsLogTrack(@"track-selected", selectedTrack.trackID, selectedFileExists);

    NSMutableArray<YTMUOfflineTrack *> *availableTracks = [NSMutableArray array];
    for (YTMUOfflineTrack *track in tracks) {
        NSURL *url = [self audioURLForTrack:track];
        if (track.trackID.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            [availableTracks addObject:track];
        }
    }
    if (availableTracks.count == 0) {
        [self clearQueue];
        [self postErrorMessage:@"This offline playlist is empty." error:nil];
        return;
    }

    NSUInteger availableSelectedIndex = selectedTrack == nil ? NSNotFound
        : [availableTracks indexOfObjectPassingTest:^BOOL(YTMUOfflineTrack *track,
                                                          __unused NSUInteger candidateIndex,
                                                          __unused BOOL *stop) {
            return [track.trackID isEqualToString:selectedTrack.trackID];
        }];
    if (availableSelectedIndex != NSNotFound) {
        index = (NSInteger)availableSelectedIndex;
    } else {
        index = MAX(0, MIN(index, (NSInteger)availableTracks.count - 1));
    }
    NSUInteger generation = ++self.playbackRequestGeneration;
    NSArray<YTMUOfflineTrack *> *requestedTracks = availableTracks.copy;
    NSInteger requestedIndex = index;
    [self requestOfflinePlaybackWithCompletionSafely:^(BOOL granted, NSError *error) {
        if (generation != self.playbackRequestGeneration) return;
        if (!granted) {
            YTMUOfflineDiagnosticsLog(@"ownership-offline", selectedTrack.trackID, @"rejected");
            [self postErrorMessage:@"Offline playback could not start." error:error];
            return;
        }
        YTMUOfflineDiagnosticsLog(@"ownership-offline", selectedTrack.trackID, @"granted");
        self.originalQueue = requestedTracks;
        self.queue = requestedTracks;
        self.currentIndex = requestedIndex;
        self.shuffled = NO;
        self.offlineSessionActive = YES;
        if (shuffle) {
            [self enableShufflePreservingCurrentTrack];
        }
        [self loadCurrentTrackAndPlay:YES preservingTime:0];
    }];
}

- (void)playSingleTrack:(YTMUOfflineTrack *)track {
    [self playTracks:@[track] startingAtIndex:0 shuffle:NO];
}

- (void)play {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self play]; });
        return;
    }
    if (self.currentTrack == nil) {
        [self postErrorMessage:@"Choose a downloaded song first." error:nil];
        return;
    }
    NSUInteger generation = ++self.playbackRequestGeneration;
    [self requestOfflinePlaybackWithCompletionSafely:^(BOOL granted, NSError *error) {
        if (generation != self.playbackRequestGeneration) return;
        if (!granted) {
            [self postErrorMessage:@"Offline playback could not start." error:error];
            return;
        }
        [self beginPlayingAfterOwnershipGranted];
    }];
}

- (void)pause {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self pause]; });
        return;
    }
    [self.player pause];
    self.playing = NO;
    [self postChange];
}

- (void)togglePlayback {
    self.playing ? [self pause] : [self play];
}

- (void)next {
    YTMUOfflineRepeatMode manualMode = self.repeatMode == YTMUOfflineRepeatModeAll
        ? YTMUOfflineRepeatModeAll : YTMUOfflineRepeatModeOff;
    size_t nextIndex = YTMUOfflineNextIndex(self.queue.count, (size_t)self.currentIndex, manualMode);
    if (nextIndex == YTMUOfflineNoIndex) {
        [self pause];
        if (self.duration > 0) {
            [self seekToTime:self.duration];
        }
        return;
    }
    self.currentIndex = (NSInteger)nextIndex;
    [self loadCurrentTrackAndPlay:YES preservingTime:0];
}

- (void)previous {
    if (self.currentTrack == nil) {
        return;
    }
    if (self.currentTime > 3.0) {
        [self seekToTime:0];
        return;
    }
    YTMUOfflineRepeatMode manualMode = self.repeatMode == YTMUOfflineRepeatModeAll
        ? YTMUOfflineRepeatModeAll : YTMUOfflineRepeatModeOff;
    size_t previousIndex = YTMUOfflinePreviousIndex(self.queue.count, (size_t)self.currentIndex, manualMode);
    if (previousIndex == YTMUOfflineNoIndex) {
        return;
    }
    self.currentIndex = (NSInteger)previousIndex;
    [self loadCurrentTrackAndPlay:YES preservingTime:0];
}

- (void)seekToTime:(NSTimeInterval)time {
    if (self.player.currentItem == nil) {
        return;
    }
    NSTimeInterval bounded = MAX(0, self.duration > 0 ? MIN(time, self.duration) : time);
    [self.player seekToTime:CMTimeMakeWithSeconds(bounded, NSEC_PER_SEC)
           toleranceBefore:CMTimeMakeWithSeconds(0.05, NSEC_PER_SEC)
            toleranceAfter:CMTimeMakeWithSeconds(0.05, NSEC_PER_SEC)];
    [self updateNowPlayingInfo];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflinePlaybackProgressNotification object:self];
}

- (void)enableShufflePreservingCurrentTrack {
    if (self.originalQueue.count == 0 || self.currentTrack == nil) {
        return;
    }
    NSUInteger originalCurrentIndex = [self.originalQueue indexOfObjectPassingTest:^BOOL(YTMUOfflineTrack *track, NSUInteger idx, BOOL *stop) {
        return [track.trackID isEqualToString:self.currentTrack.trackID];
    }];
    if (originalCurrentIndex == NSNotFound) {
        originalCurrentIndex = 0;
    }

    size_t count = self.originalQueue.count;
    size_t *order = calloc(count, sizeof(size_t));
    if (order == NULL) {
        [self postErrorMessage:@"Shuffle could not be enabled." error:nil];
        return;
    }
    uint64_t seed = ((uint64_t)arc4random() << 32) | arc4random();
    YTMUOfflineBuildShuffledOrder(count, originalCurrentIndex, seed, order);
    NSMutableArray *shuffledQueue = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        [shuffledQueue addObject:self.originalQueue[order[index]]];
    }
    free(order);

    self.queue = shuffledQueue;
    self.currentIndex = 0;
    self.shuffled = YES;
}

- (void)toggleShuffle {
    YTMUOfflineTrack *currentTrack = self.currentTrack;
    if (currentTrack == nil) {
        return;
    }
    if (!self.shuffled) {
        [self enableShufflePreservingCurrentTrack];
    } else {
        self.queue = self.originalQueue;
        NSUInteger restoredIndex = [self.queue indexOfObjectPassingTest:^BOOL(YTMUOfflineTrack *track, NSUInteger idx, BOOL *stop) {
            return [track.trackID isEqualToString:currentTrack.trackID];
        }];
        self.currentIndex = restoredIndex == NSNotFound ? 0 : (NSInteger)restoredIndex;
        self.shuffled = NO;
    }
    [self postChange];
}

- (void)cycleRepeatMode {
    switch (self.repeatMode) {
        case YTMUOfflineRepeatModeOff:
            self.repeatMode = YTMUOfflineRepeatModeAll;
            break;
        case YTMUOfflineRepeatModeAll:
            self.repeatMode = YTMUOfflineRepeatModeOne;
            break;
        case YTMUOfflineRepeatModeOne:
            self.repeatMode = YTMUOfflineRepeatModeOff;
            break;
    }
    [self postChange];
}

- (void)playQueueIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.queue.count) {
        return;
    }
    self.currentIndex = index;
    self.offlineSessionActive = YES;
    [self loadCurrentTrackAndPlay:YES preservingTime:0];
}

- (void)moveQueueItemFromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)destinationIndex {
    if (sourceIndex < 0 || destinationIndex < 0
        || sourceIndex >= (NSInteger)self.queue.count || destinationIndex >= (NSInteger)self.queue.count
        || sourceIndex == destinationIndex) {
        return;
    }
    YTMUOfflineTrack *current = self.currentTrack;
    NSMutableArray *mutableQueue = [self.queue mutableCopy];
    YTMUOfflineTrack *moved = mutableQueue[(NSUInteger)sourceIndex];
    [mutableQueue removeObjectAtIndex:(NSUInteger)sourceIndex];
    [mutableQueue insertObject:moved atIndex:(NSUInteger)destinationIndex];
    self.queue = mutableQueue;
    if (!self.shuffled) {
        self.originalQueue = mutableQueue;
    }
    NSUInteger newCurrentIndex = [mutableQueue indexOfObjectPassingTest:^BOOL(YTMUOfflineTrack *track, NSUInteger idx, BOOL *stop) {
        return [track.trackID isEqualToString:current.trackID];
    }];
    self.currentIndex = newCurrentIndex == NSNotFound ? 0 : (NSInteger)newCurrentIndex;
    [self postChange];
}

- (void)loadCurrentTrackAndPlay:(BOOL)autoplay preservingTime:(NSTimeInterval)time {
    NSException *loadException = nil;
    BOOL loadedSafely = YTMUPerformObjectiveCBlockSafely(^{
        [self loadCurrentTrackAndPlayUnchecked:autoplay preservingTime:time];
    }, &loadException);
    if (loadedSafely) return;

    YTMUOfflineDiagnosticsLogException(@"track-load", self.currentTrack.trackID, loadException);
    YTMULogContainedException(loadException, @"offline track loading");
    YTMUPerformObjectiveCBlockSafely(^{
        [self endOfflineSessionWithReason:YTMUOfflineSessionEndReasonFatalError];
    }, NULL);
    YTMUPerformObjectiveCBlockSafely(^{
        [self postErrorMessage:@"This downloaded song could not be opened safely."
                         error:YTMUOfflineErrorFromException(loadException, @"Downloaded song")];
    }, NULL);
}

- (void)loadCurrentTrackAndPlayUnchecked:(BOOL)autoplay preservingTime:(NSTimeInterval)time {
    YTMUOfflineTrack *track = self.currentTrack;
    if (track == nil) {
        [self clearQueue];
        return;
    }
    NSURL *audioURL = [self audioURLForTrack:track];
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:audioURL.path];
    YTMUOfflineDiagnosticsLogTrack(@"track-load", track.trackID, fileExists);
    if (!fileExists) {
        [self postErrorMessage:[NSString stringWithFormat:@"%@ is missing and was skipped.", track.title] error:nil];
        [self skipUnavailableCurrentTrack];
        return;
    }

    YTMUOfflineDiagnosticsLog(@"player-item", track.trackID, @"asset-create");
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    if (!asset.playable) {
        YTMUOfflineDiagnosticsLog(@"player-item", track.trackID, @"asset-not-playable");
        [self postErrorMessage:[NSString stringWithFormat:@"%@ could not be played and was skipped.", track.title] error:nil];
        [self skipUnavailableCurrentTrack];
        return;
    }
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    YTMUOfflineDiagnosticsLog(@"player-item", track.trackID, @"created");

    AVMutableMetadataItem *titleItem = [AVMutableMetadataItem metadataItem];
    titleItem.key = AVMetadataCommonKeyTitle;
    titleItem.keySpace = AVMetadataKeySpaceCommon;
    titleItem.value = track.title.length > 0 ? track.title : track.fileName.stringByDeletingPathExtension;
    NSMutableArray *metadata = [NSMutableArray arrayWithObject:titleItem];
    if (track.artist.length > 0) {
        AVMutableMetadataItem *artistItem = [AVMutableMetadataItem metadataItem];
        artistItem.key = AVMetadataCommonKeyArtist;
        artistItem.keySpace = AVMetadataKeySpaceCommon;
        artistItem.value = track.artist;
        [metadata addObject:artistItem];
    }
    UIImage *artwork = [self artworkForTrack:track];
    if (artwork != nil) {
        AVMutableMetadataItem *artworkItem = [AVMutableMetadataItem metadataItem];
        artworkItem.key = AVMetadataCommonKeyArtwork;
        artworkItem.keySpace = AVMetadataKeySpaceCommon;
        artworkItem.value = UIImagePNGRepresentation(artwork);
        [metadata addObject:artworkItem];
    }
    item.externalMetadata = metadata;

    [self.player replaceCurrentItemWithPlayerItem:item];
    YTMUOfflineDiagnosticsLog(@"player-item", track.trackID, @"installed");
    self.loadedAudioURL = audioURL;
    if (time > 0) {
        [self.player seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)
               toleranceBefore:kCMTimeZero
                toleranceAfter:kCMTimeZero];
    }
    self.playing = NO;
    [self postChange];
    if (autoplay) {
        [self beginPlayingAfterOwnershipGranted];
    }
}

- (void)skipUnavailableCurrentTrack {
    if (self.queue.count <= 1) {
        [self clearQueue];
        return;
    }
    NSMutableArray *queue = [self.queue mutableCopy];
    NSInteger removedIndex = self.currentIndex;
    [queue removeObjectAtIndex:(NSUInteger)removedIndex];
    self.queue = queue;
    size_t adjusted = YTMUOfflineAdjustedIndexAfterRemoval(queue.count + 1, (size_t)removedIndex, (size_t)removedIndex);
    self.currentIndex = adjusted == YTMUOfflineNoIndex ? NSNotFound : (NSInteger)adjusted;
    [self loadCurrentTrackAndPlay:YES preservingTime:0];
}

- (void)clearQueue {
    [self endOfflineSessionWithReason:YTMUOfflineSessionEndReasonQueueRemoved];
}

- (void)endOfflineSessionWithReason:(YTMUOfflineSessionEndReason)reason {
    [self performOnMainSynchronously:^{
        BOOL hadRuntimeState = self.offlineSessionActive
            || self.player.currentItem != nil
            || self.queue.count > 0;
        if (!hadRuntimeState) return;

        YTMUOfflineDiagnosticsLog(@"offline-session-end", self.currentTrack.trackID,
                                  [NSString stringWithFormat:@"reason=%ld", (long)reason]);
        self.playbackRequestGeneration++;
        [self.player pause];
        [self.player replaceCurrentItemWithPlayerItem:nil];
        self.originalQueue = @[];
        self.queue = @[];
        self.currentIndex = NSNotFound;
        self.playing = NO;
        self.shuffled = NO;
        self.repeatMode = YTMUOfflineRepeatModeOff;
        self->_playbackRate = 1.0;
        self.offlineSessionActive = NO;
        self.loadedAudioURL = nil;
        self.resumeAfterInterruption = NO;
        [self cancelSleepTimer];
        [self stopOfflineMediaControls];
        [self deactivateAudioSessionIfIdle];
        [self postChange];
        [YTMUPlaybackCoordinator.sharedCoordinator offlineSessionDidEndWithReason:reason];
    }];
}

- (void)playerItemDidFinish:(NSNotification *)notification {
    if (notification.object != self.player.currentItem || self.currentTrack == nil) {
        return;
    }
    size_t nextIndex = YTMUOfflineNextIndex(self.queue.count, (size_t)self.currentIndex, self.repeatMode);
    if (nextIndex == YTMUOfflineNoIndex) {
        [self.player pause];
        self.playing = NO;
        [self postChange];
        [self deactivateAudioSessionIfIdle];
        return;
    }
    if ((NSInteger)nextIndex == self.currentIndex) {
        [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            [self beginPlayingAfterOwnershipGranted];
        }];
        return;
    }
    self.currentIndex = (NSInteger)nextIndex;
    [self loadCurrentTrackAndPlay:YES preservingTime:0];
}

- (void)playerItemFailed:(NSNotification *)notification {
    if (notification.object != self.player.currentItem) {
        return;
    }
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    NSString *title = self.currentTrack.title ?: @"This song";
    [self postErrorMessage:[NSString stringWithFormat:@"%@ could not be played and was skipped.", title] error:error];
    [self skipUnavailableCurrentTrack];
}

- (void)libraryDidChange:(NSNotification *)notification {
    if (self.queue.count == 0) {
        return;
    }
    NSString *currentTrackID = self.currentTrack.trackID;
    NSInteger oldIndex = self.currentIndex;
    BOOL wasPlaying = self.playing;
    NSTimeInterval oldTime = self.currentTime;

    NSMutableDictionary<NSString *, YTMUOfflineTrack *> *tracksByID = [NSMutableDictionary dictionary];
    for (YTMUOfflineTrack *track in YTMUOfflineLibrary.sharedLibrary.tracks) {
        tracksByID[track.trackID] = track;
    }
    NSArray *(^remap)(NSArray *) = ^NSArray *(NSArray<YTMUOfflineTrack *> *source) {
        NSMutableArray *result = [NSMutableArray array];
        for (YTMUOfflineTrack *track in source) {
            YTMUOfflineTrack *replacement = tracksByID[track.trackID];
            if (replacement != nil) {
                [result addObject:replacement];
            }
        }
        return result;
    };
    self.originalQueue = remap(self.originalQueue);
    self.queue = remap(self.queue);
    if (self.queue.count == 0) {
        [self clearQueue];
        return;
    }

    NSUInteger remappedIndex = [self.queue indexOfObjectPassingTest:^BOOL(YTMUOfflineTrack *track, NSUInteger idx, BOOL *stop) {
        return [track.trackID isEqualToString:currentTrackID];
    }];
    BOOL currentWasRemoved = remappedIndex == NSNotFound;
    self.currentIndex = currentWasRemoved ? MIN(oldIndex, (NSInteger)self.queue.count - 1) : (NSInteger)remappedIndex;

    NSURL *newURL = [self audioURLForTrack:self.currentTrack];
    if (currentWasRemoved || ![newURL isEqual:self.loadedAudioURL]) {
        [self loadCurrentTrackAndPlay:wasPlaying preservingTime:currentWasRemoved ? 0 : oldTime];
    } else {
        [self postChange];
    }
}

- (void)audioSessionInterrupted:(NSNotification *)notification {
    AVAudioSessionInterruptionType type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        self.resumeAfterInterruption = self.playing;
        [self pause];
        return;
    }
    AVAudioSessionInterruptionOptions options = [notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
    if (self.resumeAfterInterruption && (options & AVAudioSessionInterruptionOptionShouldResume) != 0) {
        self.resumeAfterInterruption = NO;
        [self play];
    }
}

- (void)audioRouteChanged:(NSNotification *)notification {
    AVAudioSessionRouteChangeReason reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable && self.offlineSessionActive) {
        [self pause];
    }
}

- (void)addRemoteTargetToCommand:(MPRemoteCommand *)command
                         handler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *event))handler {
    if (command == nil || handler == nil) return;
    __block id token = nil;
    NSException *registrationException = nil;
    BOOL registeredSafely = YTMUPerformObjectiveCBlockSafely(^{
        token = [command addTargetWithHandler:handler];
    }, &registrationException);
    if (!registeredSafely) {
        YTMULogContainedException(registrationException, @"remote command registration");
        return;
    }
    if (token != nil) {
        [self.remoteCommandRegistrations addObject:@{@"command": command, @"token": token}];
    }
}

- (BOOL)offlineRemoteCommandsCanControlPlayback {
    return self.offlineSessionActive
        && self.currentTrack != nil
        && YTMUPlaybackCoordinator.sharedCoordinator.offlineControlsShouldBeActive;
}

- (BOOL)tryActivateIsolatedMediaControls {
    if (@available(iOS 16.0, *)) {
        Class sessionClass = NSClassFromString(@"MPNowPlayingSession");
        SEL initializer = NSSelectorFromString(@"initWithPlayers:");
        if (sessionClass == Nil || ![sessionClass instancesRespondToSelector:initializer]) {
            return NO;
        }

        __block MPNowPlayingSession *createdSession = nil;
        __block MPNowPlayingInfoCenter *createdInfoCenter = nil;
        __block MPRemoteCommandCenter *createdCommandCenter = nil;
        NSException *sessionException = nil;
        BOOL createdSafely = YTMUPerformObjectiveCBlockSafely(^{
            createdSession = [(MPNowPlayingSession *)[sessionClass alloc] initWithPlayers:@[self.player]];
            createdSession.automaticallyPublishesNowPlayingInfo = NO;
            createdInfoCenter = createdSession.nowPlayingInfoCenter;
            createdCommandCenter = createdSession.remoteCommandCenter;
        }, &sessionException);
        if (!createdSafely || createdSession == nil || createdInfoCenter == nil || createdCommandCenter == nil) {
            YTMULogContainedException(sessionException, @"isolated Now Playing session creation");
            return NO;
        }

        self.nowPlayingSession = createdSession;
        self.offlineNowPlayingInfoCenter = createdInfoCenter;
        self.offlineRemoteCommandCenter = createdCommandCenter;

        NSException *activationException = nil;
        BOOL activatedSafely = YTMUPerformObjectiveCBlockSafely(^{
            [createdSession becomeActiveIfPossibleWithCompletion:^(__unused BOOL success) {}];
        }, &activationException);
        if (!activatedSafely) {
            YTMULogContainedException(activationException, @"isolated Now Playing session activation");
            self.nowPlayingSession = nil;
            self.offlineNowPlayingInfoCenter = nil;
            self.offlineRemoteCommandCenter = nil;
            return NO;
        }
        return YES;
    }
    return NO;
}

- (void)fallBackToSharedMediaControls {
    self.offlineNowPlayingInfoCenter = MPNowPlayingInfoCenter.defaultCenter;
    self.offlineRemoteCommandCenter = MPRemoteCommandCenter.sharedCommandCenter;
}

- (void)activateOfflineMediaControls {
    if (self.offlineRemoteCommandCenter != nil) return;

    if (![self tryActivateIsolatedMediaControls]) {
        [self fallBackToSharedMediaControls];
    }

    MPRemoteCommandCenter *commands = self.offlineRemoteCommandCenter;
    __weak typeof(self) weakSelf = self;
    [self addRemoteTargetToCommand:commands.playCommand handler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf play];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemoteTargetToCommand:commands.pauseCommand handler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemoteTargetToCommand:commands.togglePlayPauseCommand handler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf togglePlayback];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemoteTargetToCommand:commands.nextTrackCommand handler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf next];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemoteTargetToCommand:commands.previousTrackCommand handler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf previous];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemoteTargetToCommand:commands.changePlaybackPositionCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]
            || ![event isKindOfClass:MPChangePlaybackPositionCommandEvent.class]) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        [weakSelf seekToTime:((MPChangePlaybackPositionCommandEvent *)event).positionTime];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemoteTargetToCommand:commands.changeShuffleModeCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]
            || ![event isKindOfClass:MPChangeShuffleModeCommandEvent.class]) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        MPShuffleType requested = ((MPChangeShuffleModeCommandEvent *)event).shuffleType;
        BOOL shouldShuffle = requested != MPShuffleTypeOff;
        if (weakSelf.shuffled != shouldShuffle) [weakSelf toggleShuffle];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemoteTargetToCommand:commands.changeRepeatModeCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (![weakSelf offlineRemoteCommandsCanControlPlayback]
            || ![event isKindOfClass:MPChangeRepeatModeCommandEvent.class]) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        MPRepeatType requested = ((MPChangeRepeatModeCommandEvent *)event).repeatType;
        YTMUOfflineRepeatMode target = requested == MPRepeatTypeOne ? YTMUOfflineRepeatModeOne
            : (requested == MPRepeatTypeAll ? YTMUOfflineRepeatModeAll : YTMUOfflineRepeatModeOff);
        weakSelf.repeatMode = target;
        [weakSelf postChange];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)stopOfflineMediaControls {
    NSException *nowPlayingException = nil;
    YTMUPerformObjectiveCBlockSafely(^{
        self.offlineNowPlayingInfoCenter.nowPlayingInfo = nil;
    }, &nowPlayingException);
    YTMULogContainedException(nowPlayingException, @"Now Playing cleanup");

    for (NSDictionary<NSString *, id> *registration in self.remoteCommandRegistrations.copy) {
        MPRemoteCommand *command = registration[@"command"];
        id token = registration[@"token"];
        if (command != nil && token != nil) {
            NSException *removalException = nil;
            YTMUPerformObjectiveCBlockSafely(^{
                [command removeTarget:token];
            }, &removalException);
            YTMULogContainedException(removalException, @"remote command cleanup");
        }
    }
    [self.remoteCommandRegistrations removeAllObjects];
    self.offlineRemoteCommandCenter = nil;
    self.offlineNowPlayingInfoCenter = nil;
    if (@available(iOS 16.0, *)) {
        NSException *sessionException = nil;
        YTMUPerformObjectiveCBlockSafely(^{
            [self.nowPlayingSession removePlayer:self.player];
        }, &sessionException);
        YTMULogContainedException(sessionException, @"isolated Now Playing session cleanup");
        self.nowPlayingSession = nil;
    }
}

- (void)setPlaybackRate:(float)playbackRate {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setPlaybackRate:playbackRate]; });
        return;
    }
    _playbackRate = MIN(2.0f, MAX(0.5f, playbackRate));
    if (self.playing) {
        [self.player playImmediatelyAtRate:self.playbackRate];
    }
    [self postChange];
}

- (void)setSleepTimerInterval:(NSTimeInterval)interval {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setSleepTimerInterval:interval]; });
        return;
    }
    [self cancelSleepTimer];
    if (interval <= 0 || !self.offlineSessionActive) {
        [self postChange];
        return;
    }
    self.sleepTimerEndDate = [NSDate dateWithTimeIntervalSinceNow:interval];
    __weak typeof(self) weakSelf = self;
    self.sleepTimer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:NO block:^(__unused NSTimer *timer) {
        [YTMUPlaybackCoordinator.sharedCoordinator endOfflineSessionWithReason:YTMUOfflineSessionEndReasonSleepTimer];
        weakSelf.sleepTimer = nil;
        weakSelf.sleepTimerEndDate = nil;
    }];
    [self postChange];
}

- (void)cancelSleepTimer {
    [self.sleepTimer invalidate];
    self.sleepTimer = nil;
    self.sleepTimerEndDate = nil;
}

- (void)updateNowPlayingInfo {
    if (!self.offlineSessionActive || self.currentTrack == nil
        || !YTMUPlaybackCoordinator.sharedCoordinator.offlineControlsShouldBeActive) {
        return;
    }
    YTMUOfflineTrack *track = self.currentTrack;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = track.title.length > 0 ? track.title : track.fileName.stringByDeletingPathExtension;
    if (track.artist.length > 0) {
        info[MPMediaItemPropertyArtist] = track.artist;
    }
    if (self.duration > 0) {
        info[MPMediaItemPropertyPlaybackDuration] = @(self.duration);
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.playing ? self.playbackRate : 0.0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(self.playbackRate);
    info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);
    info[MPNowPlayingInfoPropertyExternalContentIdentifier] = track.trackID;

    UIImage *artwork = [self artworkForTrack:track];
    if (artwork != nil) {
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:artwork.size
                                                                          requestHandler:^UIImage *(__unused CGSize size) {
            return artwork;
        }];
    }
    NSException *nowPlayingException = nil;
    BOOL publishedSafely = YTMUPerformObjectiveCBlockSafely(^{
        self.offlineNowPlayingInfoCenter.nowPlayingInfo = info;
    }, &nowPlayingException);
    if (!publishedSafely) {
        YTMULogContainedException(nowPlayingException, @"Now Playing publication");
    }
}

@end
