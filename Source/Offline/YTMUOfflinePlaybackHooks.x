#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "YTMUNativeMiniPlayerSwipeController.h"
#import "YTMUNativePlaybackAdapter.h"
#import "YTMUPlaybackCoordinator.h"

static void YTMUNativePlaybackWillStart(void) {
    [YTMUNativePlaybackAdapter.sharedAdapter prepareNativeMiniPlayerForPlaybackStart];
    [YTMUPlaybackCoordinator.sharedCoordinator nativePlaybackWillStart];
}

static void YTMUPrepareForNativePlayback(UIViewController *controller) {
    [YTMUNativePlaybackAdapter.sharedAdapter registerPlayerViewController:controller];
    YTMUNativePlaybackWillStart();
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

- (void)replayWithSeekSource:(int)source {
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
    YTMUNativePlaybackWillStart();
    return %orig(command);
}

- (long long)handleTogglePlayPauseCommand:(id)command {
    if (!YTMUNativePlaybackAdapter.sharedAdapter.nativePlaybackAudible) {
        YTMUNativePlaybackWillStart();
    }
    return %orig(command);
}

- (void)didTapPlayButton {
    YTMUNativePlaybackWillStart();
    %orig;
}

- (void)watchViewDidTapPlayButton:(id)view {
    YTMUNativePlaybackWillStart();
    %orig(view);
}

- (void)loadWithModel:(id)model fromView:(id)view expand:(BOOL)expand startPlayback:(BOOL)startPlayback {
    if (startPlayback) YTMUNativePlaybackWillStart();
    else if (model != nil) [YTMUNativePlaybackAdapter.sharedAdapter prepareNativeMiniPlayerForPlaybackStart];
    %orig(model, view, expand, startPlayback);
}

- (void)loadWithModel:(id)model fromView:(id)view pageLayout:(long long)layout startPlayback:(BOOL)startPlayback {
    if (startPlayback) YTMUNativePlaybackWillStart();
    else if (model != nil) [YTMUNativePlaybackAdapter.sharedAdapter prepareNativeMiniPlayerForPlaybackStart];
    %orig(model, view, layout, startPlayback);
}

- (void)loadWithModel:(id)model startPlayback:(BOOL)startPlayback {
    if (startPlayback) YTMUNativePlaybackWillStart();
    else if (model != nil) [YTMUNativePlaybackAdapter.sharedAdapter prepareNativeMiniPlayerForPlaybackStart];
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
    YTMUInstallNativeMiniPlayerSwipeIfNeeded(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    [YTMUNativePlaybackAdapter.sharedAdapter registerMiniPlayerViewController:self];
    YTMUInstallNativeMiniPlayerSwipeIfNeeded(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    // Initial viewWillAppear may run before the watch view has a window.
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
