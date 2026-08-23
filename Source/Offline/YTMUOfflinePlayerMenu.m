#import "YTMUOfflinePlayerMenu.h"

#import <AVKit/AVKit.h>

#import "YTMUOfflinePlaybackManager.h"
#import "YTMUPlaybackCoordinator.h"
#import "../Headers/Localization.h"

#include <math.h>

static NSString *YTMUPlayerMenuLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

static void YTMUConfigurePopover(UIAlertController *alert, UIView *sourceView) {
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover == nil) return;
    popover.sourceView = sourceView;
    popover.sourceRect = sourceView.bounds;
}

static UIButton *YTMUFindButtonInView(UIView *view) {
    if ([view isKindOfClass:UIButton.class]) return (UIButton *)view;
    for (UIView *subview in view.subviews) {
        UIButton *button = YTMUFindButtonInView(subview);
        if (button != nil) return button;
    }
    return nil;
}

static void YTMUShowAirPlayPicker(UIViewController *presenter, UIView *sourceView) {
    AVRoutePickerView *picker = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    picker.prioritizesVideoDevices = NO;
    picker.alpha = 0.01;
    picker.center = [sourceView.superview convertPoint:sourceView.center toView:presenter.view];
    [presenter.view addSubview:picker];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIButton *button = YTMUFindButtonInView(picker);
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [picker removeFromSuperview]; });
    });
}

static void YTMUPresentPlaybackRateMenu(UIViewController *presenter, UIView *sourceView) {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:YTMUPlayerMenuLocalized(@"OFFLINE_PLAYBACK_SPEED", @"Playback Speed")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *rates = @[@0.5f, @0.75f, @1.0f, @1.25f, @1.5f, @2.0f];
    for (NSNumber *rate in rates) {
        NSString *title = [NSString stringWithFormat:@"%@%.2gx",
            fabsf(rate.floatValue - YTMUOfflinePlaybackManager.sharedManager.playbackRate) < 0.01f ? @"✓ " : @"",
            rate.floatValue];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [YTMUOfflinePlaybackManager.sharedManager setPlaybackRate:rate.floatValue];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:YTMUPlayerMenuLocalized(@"CANCEL", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    YTMUConfigurePopover(sheet, sourceView);
    [presenter presentViewController:sheet animated:YES completion:nil];
}

static void YTMUPresentSleepTimerMenu(UIViewController *presenter, UIView *sourceView) {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:YTMUPlayerMenuLocalized(@"OFFLINE_SLEEP_TIMER", @"Sleep Timer")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSDictionary *> *options = @[
        @{@"title": YTMUPlayerMenuLocalized(@"OFFLINE_TIMER_OFF", @"Off"), @"seconds": @0},
        @{@"title": YTMUPlayerMenuLocalized(@"OFFLINE_TIMER_15", @"15 minutes"), @"seconds": @(15 * 60)},
        @{@"title": YTMUPlayerMenuLocalized(@"OFFLINE_TIMER_30", @"30 minutes"), @"seconds": @(30 * 60)},
        @{@"title": YTMUPlayerMenuLocalized(@"OFFLINE_TIMER_60", @"60 minutes"), @"seconds": @(60 * 60)},
    ];
    for (NSDictionary *option in options) {
        [sheet addAction:[UIAlertAction actionWithTitle:option[@"title"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [YTMUOfflinePlaybackManager.sharedManager setSleepTimerInterval:[option[@"seconds"] doubleValue]];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:YTMUPlayerMenuLocalized(@"CANCEL", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    YTMUConfigurePopover(sheet, sourceView);
    [presenter presentViewController:sheet animated:YES completion:nil];
}

void YTMUPresentOfflinePlayerMenu(UIViewController *presenter,
                                  UIView *sourceView,
                                  YTMUOfflineShowQueueHandler showQueueHandler) {
    if (presenter == nil || sourceView == nil || presenter.presentedViewController != nil) return;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:nil
                         message:YTMUPlayerMenuLocalized(@"OFFLINE_END_PRESERVES_DATA",
                                                         @"Downloads and playlists will not be deleted.")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:YTMUPlayerMenuLocalized(@"OFFLINE_PLAYBACK_SPEED", @"Playback Speed")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ YTMUPresentPlaybackRateMenu(presenter, sourceView); });
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:YTMUPlayerMenuLocalized(@"OFFLINE_SLEEP_TIMER", @"Sleep Timer")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ YTMUPresentSleepTimerMenu(presenter, sourceView); });
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"AirPlay"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ YTMUShowAirPlayPicker(presenter, sourceView); });
    }]];
    if (showQueueHandler != nil) {
        [sheet addAction:[UIAlertAction actionWithTitle:YTMUPlayerMenuLocalized(@"CURRENT_QUEUE", @"Current Queue")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), showQueueHandler);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:YTMUPlayerMenuLocalized(@"OFFLINE_END_PLAYBACK", @"End Offline Playback")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [YTMUPlaybackCoordinator.sharedCoordinator endOfflineSessionWithReason:YTMUOfflineSessionEndReasonUserStop];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:YTMUPlayerMenuLocalized(@"CANCEL", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    YTMUConfigurePopover(sheet, sourceView);
    [presenter presentViewController:sheet animated:YES completion:nil];
}
