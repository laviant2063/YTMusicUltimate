#import "YTMUOfflinePlaybackManager.h"

#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

#include <math.h>
#include <stdlib.h>

NSNotificationName const YTMUOfflinePlaybackDidChangeNotification = @"YTMUOfflinePlaybackDidChangeNotification";
NSNotificationName const YTMUOfflinePlaybackProgressNotification = @"YTMUOfflinePlaybackProgressNotification";
NSNotificationName const YTMUOfflinePlaybackErrorNotification = @"YTMUOfflinePlaybackErrorNotification";

@interface YTMUOfflinePlaybackManager ()
@property (nonatomic, strong, readwrite) AVPlayer *player;
@property (nonatomic, copy, readwrite) NSArray<YTMUOfflineTrack *> *originalQueue;
@property (nonatomic, copy, readwrite) NSArray<YTMUOfflineTrack *> *queue;
@property (nonatomic, assign, readwrite) NSInteger currentIndex;
@property (nonatomic, assign, readwrite, getter=isShuffled) BOOL shuffled;
@property (nonatomic, assign, readwrite, getter=isPlaying) BOOL playing;
@property (nonatomic, assign, readwrite, getter=isOfflineSessionActive) BOOL offlineSessionActive;
@property (nonatomic, assign, readwrite) YTMUOfflineRepeatMode repeatMode;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) NSHashTable<AVPlayer *> *onlinePlayers;
@property (nonatomic, assign) BOOL resumeAfterInterruption;
@property (nonatomic, strong, nullable) NSURL *loadedAudioURL;
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
        _onlinePlayers = [NSHashTable weakObjectsHashTable];

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
        [self configureRemoteCommands];
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

- (void)pauseKnownOnlinePlayers {
    @synchronized (self.onlinePlayers) {
        for (AVPlayer *onlinePlayer in self.onlinePlayers) {
            if (onlinePlayer != nil && onlinePlayer != self.player && onlinePlayer.rate > 0) {
                [onlinePlayer pause];
            }
        }
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

    if (index < 0 || index >= (NSInteger)availableTracks.count) {
        index = 0;
    }
    self.originalQueue = availableTracks;
    self.queue = availableTracks;
    self.currentIndex = index;
    self.shuffled = NO;
    self.offlineSessionActive = YES;

    if (shuffle) {
        [self enableShufflePreservingCurrentTrack];
    }
    [self loadCurrentTrackAndPlay:YES preservingTime:0];
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
    self.offlineSessionActive = YES;
    [self pauseKnownOnlinePlayers];
    if (![self activateAudioSession]) {
        return;
    }
    if (self.duration > 0 && self.currentTime >= self.duration - 0.25) {
        [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    [self.player play];
    self.playing = YES;
    [self postChange];
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
    YTMUOfflineTrack *track = self.currentTrack;
    if (track == nil) {
        [self clearQueue];
        return;
    }
    NSURL *audioURL = [self audioURLForTrack:track];
    if (![[NSFileManager defaultManager] fileExistsAtPath:audioURL.path]) {
        [self postErrorMessage:[NSString stringWithFormat:@"%@ is missing and was skipped.", track.title] error:nil];
        [self skipUnavailableCurrentTrack];
        return;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    if (!asset.playable) {
        [self postErrorMessage:[NSString stringWithFormat:@"%@ could not be played and was skipped.", track.title] error:nil];
        [self skipUnavailableCurrentTrack];
        return;
    }
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];

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
    self.loadedAudioURL = audioURL;
    if (time > 0) {
        [self.player seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)
               toleranceBefore:kCMTimeZero
                toleranceAfter:kCMTimeZero];
    }
    self.playing = NO;
    [self postChange];
    if (autoplay) {
        [self play];
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
    BOOL wasOfflineSessionActive = self.offlineSessionActive;
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.originalQueue = @[];
    self.queue = @[];
    self.currentIndex = NSNotFound;
    self.playing = NO;
    self.shuffled = NO;
    self.offlineSessionActive = NO;
    self.loadedAudioURL = nil;
    if (wasOfflineSessionActive) {
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    }
    [self deactivateAudioSessionIfIdle];
    [self postChange];
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
            [self play];
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

- (BOOL)isOfflinePlayer:(AVPlayer *)player {
    return player == self.player;
}

- (void)onlinePlayerWillStart:(AVPlayer *)player {
    if (player == nil || player == self.player) {
        return;
    }
    @synchronized (self.onlinePlayers) {
        [self.onlinePlayers addObject:player];
    }
    if (!self.offlineSessionActive) {
        return;
    }
    void (^pauseOfflinePlayback)(void) = ^{
        if (self.offlineSessionActive) {
            [self.player pause];
            self.playing = NO;
            self.offlineSessionActive = NO;
            [self postChange];
        }
    };
    if (NSThread.isMainThread) {
        pauseOfflinePlayback();
    } else {
        dispatch_async(dispatch_get_main_queue(), pauseOfflinePlayback);
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

- (void)configureRemoteCommands {
    MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
    __weak typeof(self) weakSelf = self;
    [commands.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || weakSelf.currentTrack == nil) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf play];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || weakSelf.currentTrack == nil) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || weakSelf.currentTrack == nil) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf togglePlayback];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || weakSelf.currentTrack == nil) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf next];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || weakSelf.currentTrack == nil) return MPRemoteCommandHandlerStatusCommandFailed;
        [weakSelf previous];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || ![event isKindOfClass:MPChangePlaybackPositionCommandEvent.class]) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        [weakSelf seekToTime:((MPChangePlaybackPositionCommandEvent *)event).positionTime];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.changeShuffleModeCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || ![event isKindOfClass:MPChangeShuffleModeCommandEvent.class]) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        MPShuffleType requested = ((MPChangeShuffleModeCommandEvent *)event).shuffleType;
        BOOL shouldShuffle = requested != MPShuffleTypeOff;
        if (weakSelf.shuffled != shouldShuffle) [weakSelf toggleShuffle];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.changeRepeatModeCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (!weakSelf.offlineSessionActive || ![event isKindOfClass:MPChangeRepeatModeCommandEvent.class]) {
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

- (void)updateNowPlayingInfo {
    if (!self.offlineSessionActive || self.currentTrack == nil) {
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
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.playing ? 1.0 : 0.0);
    info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);

    UIImage *artwork = [self artworkForTrack:track];
    if (artwork != nil) {
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:artwork.size
                                                                          requestHandler:^UIImage *(__unused CGSize size) {
            return artwork;
        }];
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

@end
