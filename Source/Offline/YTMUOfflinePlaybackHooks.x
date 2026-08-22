#import <AVFoundation/AVFoundation.h>
#import "YTMUOfflinePlaybackManager.h"

%hook AVPlayer

- (void)play {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    if (![manager isOfflinePlayer:self]) {
        [manager onlinePlayerWillStart:self];
    }
    %orig;
}

- (void)playImmediatelyAtRate:(float)rate {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    if (![manager isOfflinePlayer:self]) {
        [manager onlinePlayerWillStart:self];
    }
    %orig;
}

- (void)setRate:(float)rate {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    if (rate > 0 && ![manager isOfflinePlayer:self]) {
        [manager onlinePlayerWillStart:self];
    }
    %orig;
}

%end
