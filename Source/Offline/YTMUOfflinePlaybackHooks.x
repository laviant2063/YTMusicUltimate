#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "YTMUNativePlaybackAdapter.h"
#import "YTMUPlaybackCoordinator.h"

static void YTMUPrepareForNativePlayback(UIViewController *controller) {
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:controller];
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
}

%group YTMUPlayerViewControllerHooks

%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:self];
}

- (void)play {
    YTMUPrepareForNativePlayback(self);
    %orig;
}

- (void)resumePlayback {
    YTMUPrepareForNativePlayback(self);
    %orig;
}

- (void)replayWithSeekSource:(NSInteger)source {
    YTMUPrepareForNativePlayback(self);
    %orig(source);
}

- (void)pause {
    %orig;
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:self];
    dispatch_async(dispatch_get_main_queue(), ^{
        [YTMUNativePlaybackAdapter.sharedAdapter refreshNativePlaybackState];
    });
}

- (void)pauseWithStoppageReason:(NSInteger)reason {
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

- (void)handlePlayCommand:(id)command {
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
    %orig(command);
}

- (void)handleTogglePlayPauseCommand:(id)command {
    if (!YTMUNativePlaybackAdapter.sharedAdapter.nativePlaybackAudible) {
        [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
    }
    %orig(command);
}

- (void)didTapPlayButton {
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
    %orig;
}

- (void)watchViewDidTapPlayButton:(id)view {
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
    %orig(view);
}

- (void)loadWithModel:(id)model fromView:(id)view expand:(BOOL)expand startPlayback:(BOOL)startPlayback {
    if (startPlayback) [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
    %orig(model, view, expand, startPlayback);
}

- (void)loadWithModel:(id)model fromView:(id)view pageLayout:(id)layout startPlayback:(BOOL)startPlayback {
    if (startPlayback) [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
    %orig(model, view, layout, startPlayback);
}

- (void)loadWithModel:(id)model startPlayback:(BOOL)startPlayback {
    if (startPlayback) [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
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
