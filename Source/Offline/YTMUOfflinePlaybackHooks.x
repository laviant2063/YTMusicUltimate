#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

#import "YTMUObjectiveCExceptionGuard.h"
#import "YTMUNativePlaybackAdapter.h"
#import "YTMUOfflineDiagnostics.h"
#import "YTMUPlaybackCoordinator.h"

static BOOL YTMUPrepareForNativePlayback(UIViewController *controller) {
    __block BOOL allowed = NO;
    NSException *transitionException = nil;
    BOOL completedSafely = YTMUPerformObjectiveCBlockSafely(^{
        [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:controller];
        allowed = [YTMUPlaybackCoordinator.sharedCoordinator prepareForNativePlayback];
    }, &transitionException);
    if (!completedSafely) {
        YTMUOfflineDiagnosticsLogException(@"native-play-hook", nil, transitionException);
    }
    return completedSafely && allowed;
}

static BOOL YTMUPrepareForNativeWatchPlayback(UIViewController *controller) {
    __block BOOL allowed = NO;
    NSException *transitionException = nil;
    BOOL completedSafely = YTMUPerformObjectiveCBlockSafely(^{
        [YTMUNativePlaybackAdapter.sharedAdapter registerWatchViewController:controller];
        allowed = [YTMUPlaybackCoordinator.sharedCoordinator prepareForNativePlayback];
    }, &transitionException);
    if (!completedSafely) {
        YTMUOfflineDiagnosticsLogException(@"native-watch-hook", nil, transitionException);
    }
    return completedSafely && allowed;
}

%group YTMUPlayerViewControllerHooks

%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:self];
}

- (void)play {
    if (!YTMUPrepareForNativePlayback(self)) return;
    %orig;
}

- (void)resumePlayback {
    if (!YTMUPrepareForNativePlayback(self)) return;
    %orig;
}

- (void)replayWithSeekSource:(int)source {
    if (!YTMUPrepareForNativePlayback(self)) return;
    %orig(source);
}

- (void)pause {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:self];
    dispatch_async(dispatch_get_main_queue(), ^{
        [YTMUNativePlaybackAdapter.sharedAdapter refreshNativePlaybackState];
    });
}

- (void)pauseWithStoppageReason:(int)reason {
    %orig(reason);
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:self];
    dispatch_async(dispatch_get_main_queue(), ^{
        [YTMUNativePlaybackAdapter.sharedAdapter refreshNativePlaybackState];
    });
}

- (void)playbackControllerStateDidChange:(id)controller {
    %orig(controller);
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:self];
    [YTMUNativePlaybackAdapter.sharedAdapter refreshNativePlaybackState];
}

%end

%end

%group YTMUWatchViewControllerHooks

%hook YTMWatchViewController

- (void)viewDidLoad {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerWatchViewController:self];
}

- (void)playbackControllerDidPlay {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerWatchViewController:self];
    [YTMUNativePlaybackAdapter.sharedAdapter nativePlaybackDidStart];
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackDidStart];
}

- (void)playbackControllerDidPause {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerWatchViewController:self];
    [YTMUNativePlaybackAdapter.sharedAdapter nativePlaybackDidPause];
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackDidPause];
}

- (void)playbackControllerPlayerStateDidChange {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerWatchViewController:self];
    [YTMUNativePlaybackAdapter.sharedAdapter refreshNativePlaybackState];
}

- (long long)handlePlayCommand:(id)command {
    if (!YTMUPrepareForNativeWatchPlayback(self)) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }
    return %orig(command);
}

- (long long)handleTogglePlayPauseCommand:(id)command {
    if (!YTMUNativePlaybackAdapter.sharedAdapter.nativePlaybackAudible) {
        if (!YTMUPrepareForNativeWatchPlayback(self)) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
    }
    return %orig(command);
}

- (void)didTapPlayButton {
    if (!YTMUPrepareForNativeWatchPlayback(self)) return;
    %orig;
}

- (void)watchViewDidTapPlayButton:(id)view {
    if (!YTMUPrepareForNativeWatchPlayback(self)) return;
    %orig(view);
}

- (void)loadWithModel:(id)model fromView:(id)view expand:(BOOL)expand startPlayback:(BOOL)startPlayback {
    if (startPlayback && !YTMUPrepareForNativeWatchPlayback(self)) return;
    %orig(model, view, expand, startPlayback);
}

- (void)loadWithModel:(id)model fromView:(id)view pageLayout:(long long)layout startPlayback:(BOOL)startPlayback {
    if (startPlayback && !YTMUPrepareForNativeWatchPlayback(self)) return;
    %orig(model, view, layout, startPlayback);
}

- (void)loadWithModel:(id)model startPlayback:(BOOL)startPlayback {
    if (startPlayback && !YTMUPrepareForNativeWatchPlayback(self)) return;
    %orig(model, startPlayback);
}

- (void)reset {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter nativePlaybackSessionDidEnd];
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackSessionDidEnd];
}

- (void)resetPlayer {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter nativePlaybackSessionDidEnd];
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackSessionDidEnd];
}

- (void)resetAndHide {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter nativePlaybackSessionDidEnd];
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackSessionDidEnd];
}

%end

%end

%group YTMUMiniPlayerViewControllerHooks

%hook YTMMiniPlayerViewController

- (void)viewDidLoad {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerMiniPlayerViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    [YTMUNativePlaybackAdapter.sharedAdapter registerMiniPlayerViewController:self];
}

%end

%end

%ctor {
    if (NSClassFromString(@"YTPlayerViewController") != Nil) {
        %init(YTMUPlayerViewControllerHooks,
              YTPlayerViewController = NSClassFromString(@"YTPlayerViewController"));
    }
    if (NSClassFromString(@"YTMWatchViewController") != Nil) {
        %init(YTMUWatchViewControllerHooks,
              YTMWatchViewController = NSClassFromString(@"YTMWatchViewController"));
    }
    if (NSClassFromString(@"YTMMiniPlayerViewController") != Nil) {
        %init(YTMUMiniPlayerViewControllerHooks,
              YTMMiniPlayerViewController = NSClassFromString(@"YTMMiniPlayerViewController"));
    }
}
