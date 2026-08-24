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

typedef NS_ENUM(NSInteger, YTMUOfflinePlayerMenuAction) {
    YTMUOfflinePlayerMenuActionPlaybackRate = 1,
    YTMUOfflinePlayerMenuActionSleepTimer,
    YTMUOfflinePlayerMenuActionAirPlay,
    YTMUOfflinePlayerMenuActionQueue,
    YTMUOfflinePlayerMenuActionEndPlayback,
};

@interface YTMUOfflinePlayerMenuViewController : UIViewController
@property (nonatomic, weak) UIViewController *hostPresenter;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, copy) YTMUOfflineShowQueueHandler showQueueHandler;
- (instancetype)initWithPresenter:(UIViewController *)presenter
                       sourceView:(UIView *)sourceView
                  showQueueHandler:(YTMUOfflineShowQueueHandler)showQueueHandler;
@end

@implementation YTMUOfflinePlayerMenuViewController

- (instancetype)initWithPresenter:(UIViewController *)presenter
                       sourceView:(UIView *)sourceView
                  showQueueHandler:(YTMUOfflineShowQueueHandler)showQueueHandler {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _hostPresenter = presenter;
        _sourceView = sourceView;
        _showQueueHandler = [showQueueHandler copy];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (UIButton *)menuButtonWithTitle:(NSString *)title
                           symbol:(NSString *)symbol
                            color:(UIColor *)color
                           action:(YTMUOfflinePlayerMenuAction)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = action;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 20);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 14);
    button.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:16 weight:UIFontWeightMedium]
        maximumPointSize:21];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button setTitle:title forState:UIControlStateNormal];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    [button setTitleColor:color forState:UIControlStateNormal];
    button.tintColor = color;
    [button.heightAnchor constraintEqualToConstant:54].active = YES;
    [button addTarget:self action:@selector(menuActionSelected:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.accessibilityViewIsModal = YES;

    UIControl *dimmingControl = [[UIControl alloc] init];
    dimmingControl.translatesAutoresizingMaskIntoConstraints = NO;
    dimmingControl.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.60];
    [dimmingControl addTarget:self action:@selector(dismissMenu:) forControlEvents:UIControlEventTouchUpInside];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.105 alpha:0.99];
    card.layer.cornerRadius = 25;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.12].CGColor;
    card.clipsToBounds = YES;

    UIButton *playbackRate = [self menuButtonWithTitle:
        YTMUPlayerMenuLocalized(@"OFFLINE_PLAYBACK_SPEED", @"Playback Speed")
        symbol:@"speedometer" color:UIColor.whiteColor
        action:YTMUOfflinePlayerMenuActionPlaybackRate];
    UIButton *sleepTimer = [self menuButtonWithTitle:
        YTMUPlayerMenuLocalized(@"OFFLINE_SLEEP_TIMER", @"Sleep Timer")
        symbol:@"clock" color:UIColor.whiteColor
        action:YTMUOfflinePlayerMenuActionSleepTimer];
    UIButton *airPlay = [self menuButtonWithTitle:@"AirPlay"
        symbol:@"airplayaudio" color:UIColor.whiteColor
        action:YTMUOfflinePlayerMenuActionAirPlay];
    UIButton *queue = [self menuButtonWithTitle:
        YTMUPlayerMenuLocalized(@"CURRENT_QUEUE", @"Current Queue")
        symbol:@"list.bullet" color:UIColor.whiteColor
        action:YTMUOfflinePlayerMenuActionQueue];
    queue.enabled = self.showQueueHandler != nil;
    queue.alpha = queue.enabled ? 1 : 0.45;

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.13];
    [separator.heightAnchor constraintEqualToConstant:0.5].active = YES;

    UIButton *endPlayback = [self menuButtonWithTitle:
        YTMUPlayerMenuLocalized(@"OFFLINE_END_PLAYBACK", @"End Offline Playback")
        symbol:@"stop.fill" color:UIColor.systemRedColor
        action:YTMUOfflinePlayerMenuActionEndPlayback];

    UILabel *preservationLabel = [[UILabel alloc] init];
    preservationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    preservationLabel.text = YTMUPlayerMenuLocalized(@"OFFLINE_END_PRESERVES_DATA",
                                                       @"Downloads and playlists will not be deleted.");
    preservationLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont systemFontOfSize:13]
        maximumPointSize:17];
    preservationLabel.adjustsFontForContentSizeCategory = YES;
    preservationLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.48];
    preservationLabel.textAlignment = NSTextAlignmentCenter;
    preservationLabel.numberOfLines = 2;
    [preservationLabel.heightAnchor constraintGreaterThanOrEqualToConstant:46].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        playbackRate, sleepTimer, airPlay, queue, separator, endPlayback, preservationLabel
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;

    [self.view addSubview:dimmingControl];
    [self.view addSubview:card];
    [card addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [dimmingControl.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimmingControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimmingControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimmingControl.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [card.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
    ]];
}

- (void)dismissMenu:(__unused id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)menuActionSelected:(UIButton *)sender {
    YTMUOfflinePlayerMenuAction action = (YTMUOfflinePlayerMenuAction)sender.tag;
    UIViewController *presenter = self.hostPresenter;
    UIView *sourceView = self.sourceView ?: presenter.view;
    YTMUOfflineShowQueueHandler showQueueHandler = [self.showQueueHandler copy];
    [self dismissViewControllerAnimated:YES completion:^{
        switch (action) {
            case YTMUOfflinePlayerMenuActionPlaybackRate:
                YTMUPresentPlaybackRateMenu(presenter, sourceView);
                break;
            case YTMUOfflinePlayerMenuActionSleepTimer:
                YTMUPresentSleepTimerMenu(presenter, sourceView);
                break;
            case YTMUOfflinePlayerMenuActionAirPlay:
                YTMUShowAirPlayPicker(presenter, sourceView);
                break;
            case YTMUOfflinePlayerMenuActionQueue:
                if (showQueueHandler != nil) showQueueHandler();
                break;
            case YTMUOfflinePlayerMenuActionEndPlayback:
                [YTMUPlaybackCoordinator.sharedCoordinator
                    endOfflineSessionWithReason:YTMUOfflineSessionEndReasonUserStop];
                break;
        }
    }];
}

@end

void YTMUPresentOfflinePlayerMenu(UIViewController *presenter,
                                  UIView *sourceView,
                                  YTMUOfflineShowQueueHandler showQueueHandler) {
    if (presenter == nil || sourceView == nil || presenter.presentedViewController != nil) return;
    YTMUOfflinePlayerMenuViewController *menu = [[YTMUOfflinePlayerMenuViewController alloc]
        initWithPresenter:presenter sourceView:sourceView showQueueHandler:showQueueHandler];
    [presenter presentViewController:menu animated:YES completion:nil];
}
