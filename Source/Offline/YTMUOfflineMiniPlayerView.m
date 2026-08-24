#import "YTMUOfflineMiniPlayerView.h"

#import "YTMUOfflineNowPlayingViewController.h"
#import "YTMUOfflinePlaybackManager.h"
#import "YTMUOfflinePlayerVisualPolicy.h"
#import "YTMUOfflinePlayerMenu.h"
#import "YTMUMiniPlayerSwipePolicy.h"
#import "YTMUObjectiveCExceptionGuard.h"
#import "YTMUPlaybackCoordinator.h"
#import "../Headers/Localization.h"
#import "../Headers/YTMToastController.h"

static const CGFloat YTMUOfflineMinimumTouchDimension = 44.0;
static const NSTimeInterval YTMUOfflineSwipeAnimationDuration = 0.22;
static const CGFloat YTMUOfflineSwipeMaximumFade = 0.35;

static NSString *YTMUMiniPlayerLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

@interface YTMUOfflineMiniPlayerView () <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) UIPanGestureRecognizer *dismissPanGesture;
@property (nonatomic, assign) BOOL sessionActive;
@property (nonatomic, assign) BOOL swipeInProgress;
@property (nonatomic, assign) BOOL swipeRestoring;
@property (nonatomic, assign) BOOL swipeDismissCommitted;
@property (nonatomic, assign) NSUInteger swipeGeneration;
@end


@implementation YTMUOfflineMiniPlayerView

- (instancetype)initWithPresenter:(UIViewController *)presenter {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _presenter = presenter;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.105 alpha:0.98];
        self.layer.cornerRadius = 18;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.14].CGColor;
        self.clipsToBounds = YES;
        self.hidden = YES;
        self.alpha = 0;
        _heightConstraint = [self.heightAnchor constraintEqualToConstant:0];
        _heightConstraint.active = YES;

        _artworkView = [[UIImageView alloc] init];
        _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = 8;
        _artworkView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
            scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]
            maximumPointSize:18];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.numberOfLines = 1;

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _artistLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
            scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightRegular]
            maximumPointSize:15];
        _artistLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.58];
        _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _artistLabel.adjustsFontForContentSizeCategory = YES;
        _artistLabel.numberOfLines = 1;

        _badgeLabel = [[UILabel alloc] init];
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeLabel.text = YTMUMiniPlayerLocalized(@"OFFLINE_BADGE", @"Offline");
        _badgeLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
        _badgeLabel.textColor = UIColor.systemBlueColor;
        _badgeLabel.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.17];
        _badgeLabel.layer.cornerRadius = 7;
        _badgeLabel.clipsToBounds = YES;
        _badgeLabel.textAlignment = NSTextAlignmentCenter;

        _playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
        _playPauseButton.tintColor = UIColor.whiteColor;
        _playPauseButton.accessibilityLabel = YTMUMiniPlayerLocalized(@"PLAY_PAUSE", @"Play or pause");
        [_playPauseButton addTarget:self action:@selector(togglePlayback:) forControlEvents:UIControlEventTouchUpInside];

        _nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _nextButton.translatesAutoresizingMaskIntoConstraints = NO;
        _nextButton.tintColor = UIColor.whiteColor;
        _nextButton.accessibilityLabel = YTMUMiniPlayerLocalized(@"NEXT", @"Next");
        [_nextButton setImage:[UIImage systemImageNamed:@"forward.end.fill"] forState:UIControlStateNormal];
        [_nextButton addTarget:self action:@selector(next:) forControlEvents:UIControlEventTouchUpInside];

        _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _moreButton.translatesAutoresizingMaskIntoConstraints = NO;
        _moreButton.tintColor = UIColor.whiteColor;
        _moreButton.accessibilityLabel = YTMUMiniPlayerLocalized(@"MORE", @"More");
        [_moreButton setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
        [_moreButton addTarget:self action:@selector(showMore:) forControlEvents:UIControlEventTouchUpInside];

        [self addSubview:_artworkView];
        [self addSubview:_titleLabel];
        [self addSubview:_artistLabel];
        [self addSubview:_badgeLabel];
        [self addSubview:_playPauseButton];
        [self addSubview:_nextButton];
        [self addSubview:_moreButton];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPlayer:)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];

        _dismissPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(handleDismissPan:)];
        _dismissPanGesture.delegate = self;
        _dismissPanGesture.maximumNumberOfTouches = 1;
        _dismissPanGesture.cancelsTouchesInView = NO;
        [self addGestureRecognizer:_dismissPanGesture];
        [tap requireGestureRecognizerToFail:_dismissPanGesture];

        UIAccessibilityCustomAction *endPlaybackAction = [[UIAccessibilityCustomAction alloc]
            initWithName:YTMUMiniPlayerLocalized(@"OFFLINE_END_PLAYBACK", @"End Offline Playback")
                  target:self
                selector:@selector(accessibilityEndOfflinePlayback:)];
        _titleLabel.accessibilityCustomActions = @[endPlaybackAction];

        [NSLayoutConstraint activateConstraints:@[
            [_artworkView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_artworkView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_artworkView.widthAnchor constraintEqualToConstant:60],
            [_artworkView.heightAnchor constraintEqualToConstant:60],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_artworkView.trailingAnchor constant:10],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_playPauseButton.leadingAnchor constant:-6],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:9],

            [_artistLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_artistLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1],
            [_artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_playPauseButton.leadingAnchor constant:-6],
            [_badgeLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_badgeLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:3],
            [_badgeLabel.widthAnchor constraintEqualToConstant:50],
            [_badgeLabel.heightAnchor constraintEqualToConstant:15],
            [_badgeLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-7],

            [_playPauseButton.trailingAnchor constraintEqualToAnchor:_nextButton.leadingAnchor constant:-1],
            [_playPauseButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_playPauseButton.widthAnchor constraintEqualToConstant:YTMUOfflineMinimumTouchDimension],
            [_playPauseButton.heightAnchor constraintEqualToConstant:48],
            [_nextButton.trailingAnchor constraintEqualToAnchor:_moreButton.leadingAnchor constant:-1],
            [_nextButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_nextButton.widthAnchor constraintEqualToConstant:YTMUOfflineMinimumTouchDimension],
            [_nextButton.heightAnchor constraintEqualToConstant:48],
            [_moreButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_moreButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_moreButton.widthAnchor constraintEqualToConstant:YTMUOfflineMinimumTouchDimension],
            [_moreButton.heightAnchor constraintEqualToConstant:48],
        ]];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackChanged:)
                                                     name:YTMUOfflinePlaybackDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification object:nil];
        [self updateUI];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, UIViewNoIntrinsicMetric);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *view = touch.view;
    while (view != nil && view != self) {
        if ([view isKindOfClass:UIControl.class]) return NO;
        view = view.superview;
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.dismissPanGesture) return YES;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:self];
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUPlaybackCoordinator *coordinator = YTMUPlaybackCoordinator.sharedCoordinator;
    return YTMUMiniPlayerSwipeCanBegin(coordinator.owner,
                                        YTMUPlaybackOwnerOffline,
                                        manager.offlineSessionActive,
                                        manager.currentTrack != nil,
                                        false,
                                        velocity.x,
                                        velocity.y);
}

- (BOOL)offlineSwipeCanContinue {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    return manager.offlineSessionActive
        && manager.currentTrack != nil
        && YTMUPlaybackCoordinator.sharedCoordinator.owner == YTMUPlaybackOwnerOffline;
}

- (void)restoreSwipeAnimated:(BOOL)animated {
    NSUInteger generation = ++self.swipeGeneration;
    self.swipeInProgress = NO;
    self.swipeRestoring = animated;
    self.swipeDismissCommitted = NO;
    self.userInteractionEnabled = YES;
    BOOL shouldBeVisible = YTMUOfflinePlaybackManager.sharedManager.offlineSessionActive
        && YTMUOfflinePlaybackManager.sharedManager.currentTrack != nil;
    void (^animations)(void) = ^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = shouldBeVisible ? 1.0 : 0.0;
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (generation != self.swipeGeneration) return;
        self.swipeRestoring = NO;
        [self updateUI];
    };
    if (animated) {
        [UIView animateWithDuration:YTMUOfflineSwipeAnimationDuration
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:animations
                         completion:completion];
    } else {
        [self.layer removeAllAnimations];
        animations();
        completion(YES);
    }
}

- (void)showOfflineEndFailure {
    NSException *toastException = nil;
    BOOL shownSafely = YTMUPerformObjectiveCBlockSafely(^{
        Class toastClass = NSClassFromString(@"YTMToastController");
        id toast = toastClass == Nil ? nil : [[toastClass alloc] init];
        if ([toast respondsToSelector:@selector(showMessage:)]) {
            [(YTMToastController *)toast showMessage:YTMUMiniPlayerLocalized(
                @"OFFLINE_END_FAILED", @"Offline playback could not be ended.")];
        }
    }, &toastException);
    if (!shownSafely) {
        NSLog(@"[YTMusicUltimate] Could not show offline swipe error %@: %@",
              toastException.name,
              toastException.reason);
    }
}

- (void)finishCommittedDismissalForGeneration:(NSUInteger)generation announce:(BOOL)announce {
    if (generation != self.swipeGeneration) return;
    if (YTMUOfflinePlaybackManager.sharedManager.offlineSessionActive) {
        [self restoreSwipeAnimated:NO];
        return;
    }

    self.swipeGeneration++;
    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = NO;
    self.sessionActive = NO;
    self.accessibilityElementsHidden = YES;
    self.heightConstraint.constant = 0;
    self.hidden = YES;
    self.alpha = 0;
    self.transform = CGAffineTransformIdentity;
    self.userInteractionEnabled = YES;
    [self.superview setNeedsLayout];
    [self.superview layoutIfNeeded];
    if (announce) {
        UIAccessibilityPostNotification(
            UIAccessibilityAnnouncementNotification,
            YTMUMiniPlayerLocalized(@"OFFLINE_PLAYBACK_ENDED", @"Offline playback has ended."));
    }
}

- (void)animateCommittedDismissalForGeneration:(NSUInteger)generation {
    CGFloat cardHeight = MAX(CGRectGetHeight(self.bounds), self.heightConstraint.constant);
    CGFloat distance = MAX(120.0, cardHeight + self.safeAreaInsets.bottom + 24.0);
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:YTMUOfflineSwipeAnimationDuration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        weakSelf.transform = CGAffineTransformMakeTranslation(0, distance);
        weakSelf.alpha = 0;
    } completion:^(__unused BOOL finished) {
        [weakSelf finishCommittedDismissalForGeneration:generation announce:YES];
    }];
}

- (BOOL)commitOfflineSwipeDismissal {
    if (self.swipeDismissCommitted || ![self offlineSwipeCanContinue]) {
        [self restoreSwipeAnimated:YES];
        return NO;
    }

    self.swipeInProgress = NO;
    self.swipeRestoring = NO;
    self.swipeDismissCommitted = YES;
    self.userInteractionEnabled = NO;
    NSUInteger generation = ++self.swipeGeneration;
    YTMUPlaybackCoordinator *coordinator = YTMUPlaybackCoordinator.sharedCoordinator;
    NSException *endException = nil;
    BOOL endedSafely = YTMUPerformObjectiveCBlockSafely(^{
        [coordinator endOfflineSessionWithReason:YTMUOfflineSessionEndReasonUserStop];
    }, &endException);
    if (!endedSafely) {
        NSLog(@"[YTMusicUltimate] Offline swipe dismissal failed %@: %@",
              endException.name,
              endException.reason);
        [self restoreSwipeAnimated:YES];
        [self showOfflineEndFailure];
        return NO;
    }

    BOOL sessionEnded = !YTMUOfflinePlaybackManager.sharedManager.offlineSessionActive
        && coordinator.owner == YTMUPlaybackOwnerNone;
    if (!sessionEnded) {
        [self restoreSwipeAnimated:YES];
        [self showOfflineEndFailure];
        return NO;
    }

    [self animateCommittedDismissalForGeneration:generation];
    return YES;
}

- (void)handleDismissPan:(UIPanGestureRecognizer *)gesture {
    if (self.swipeDismissCommitted) return;
    UIView *coordinateView = self.superview ?: self;
    CGPoint translation = [gesture translationInView:coordinateView];
    CGPoint velocity = [gesture velocityInView:coordinateView];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            if (![self offlineSwipeCanContinue]) {
                [self restoreSwipeAnimated:YES];
                return;
            }
            [self.layer removeAllAnimations];
            self.swipeGeneration++;
            self.swipeInProgress = YES;
            self.swipeRestoring = NO;
            self.userInteractionEnabled = YES;
            break;
        case UIGestureRecognizerStateChanged: {
            if (!self.swipeInProgress || ![self offlineSwipeCanContinue]) {
                [self restoreSwipeAnimated:YES];
                return;
            }
            CGFloat downwardTranslation = MAX(0.0, translation.y);
            CGFloat cardHeight = MAX(CGRectGetHeight(self.bounds), self.heightConstraint.constant);
            double progress = YTMUMiniPlayerSwipeProgress(cardHeight, downwardTranslation);
            self.transform = CGAffineTransformMakeTranslation(0, downwardTranslation);
            self.alpha = 1.0 - YTMUOfflineSwipeMaximumFade * progress;
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (!self.swipeInProgress || ![self offlineSwipeCanContinue]) {
                [self restoreSwipeAnimated:YES];
                return;
            }
            CGFloat cardHeight = MAX(CGRectGetHeight(self.bounds), self.heightConstraint.constant);
            if (YTMUMiniPlayerSwipeShouldCommit(cardHeight,
                                                translation.x,
                                                translation.y,
                                                velocity.x,
                                                velocity.y)) {
                [self commitOfflineSwipeDismissal];
            } else {
                [self restoreSwipeAnimated:YES];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self restoreSwipeAnimated:YES];
            break;
        default:
            break;
    }
}

- (BOOL)accessibilityEndOfflinePlayback:(__unused UIAccessibilityCustomAction *)action {
    if (![self offlineSwipeCanContinue]) return NO;
    self.swipeInProgress = YES;
    return [self commitOfflineSwipeDismissal];
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)notification {
    if (self.swipeDismissCommitted
        && !YTMUOfflinePlaybackManager.sharedManager.offlineSessionActive) {
        [self.layer removeAllAnimations];
        [self finishCommittedDismissalForGeneration:self.swipeGeneration announce:YES];
    } else if (self.swipeInProgress || self.swipeRestoring || self.swipeDismissCommitted) {
        [self restoreSwipeAnimated:NO];
    }
}

- (void)playbackChanged:(__unused NSNotification *)notification {
    [self updateUI];
}

- (void)updateUI {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateUI]; });
        return;
    }
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUOfflineTrack *track = manager.currentTrack;
    CGFloat targetHeight = YTMUOfflineMiniPlayerHeight(manager.offlineSessionActive, track != nil);
    BOOL active = targetHeight > 0;

    if (self.swipeDismissCommitted) {
        if (!active) {
            self.playPauseButton.enabled = NO;
            self.nextButton.enabled = NO;
            self.moreButton.enabled = NO;
            return;
        }
        [self restoreSwipeAnimated:NO];
        return;
    } else if ((self.swipeInProgress || self.swipeRestoring) && !active) {
        self.swipeGeneration++;
        self.swipeInProgress = NO;
        self.swipeRestoring = NO;
        self.transform = CGAffineTransformIdentity;
        self.userInteractionEnabled = YES;
    }

    BOOL visibilityChanged = active != self.sessionActive;
    self.sessionActive = active;
    self.accessibilityElementsHidden = !active;
    self.heightConstraint.constant = targetHeight;
    if (active) self.hidden = NO;

    self.titleLabel.text = track.title.length > 0 ? track.title : YTMUMiniPlayerLocalized(@"OFFLINE_PLAYER", @"Offline Player");
    self.artistLabel.text = track.artist ?: @"";
    UIImage *artwork = nil;
    if (track.artworkFileName.length > 0) {
        NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL
            URLByAppendingPathComponent:track.artworkFileName];
        artwork = [UIImage imageWithContentsOfFile:url.path];
    }
    self.artworkView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    self.artworkView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    NSString *symbol = manager.playing ? @"pause.fill" : @"play.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    self.playPauseButton.accessibilityValue = manager.playing
        ? YTMUMiniPlayerLocalized(@"PLAYING", @"Playing")
        : YTMUMiniPlayerLocalized(@"PAUSED", @"Paused");
    self.playPauseButton.enabled = active;
    self.nextButton.enabled = active && manager.queue.count > 1;
    self.moreButton.enabled = active;

    if (self.swipeInProgress || self.swipeRestoring) {
        self.hidden = NO;
        self.heightConstraint.constant = targetHeight;
        return;
    }

    if (visibilityChanged) {
        [self.superview setNeedsLayout];
        __weak typeof(self) weakSelf = self;
        [UIView animateWithDuration:0.2
                         animations:^{
            weakSelf.alpha = active ? 1 : 0;
            [weakSelf.superview layoutIfNeeded];
        } completion:^(__unused BOOL finished) {
            if (!weakSelf.sessionActive) weakSelf.hidden = YES;
        }];
    } else {
        self.hidden = !active;
        self.alpha = active ? 1 : 0;
    }
}

- (void)togglePlayback:(__unused id)sender {
    [YTMUOfflinePlaybackManager.sharedManager togglePlayback];
}

- (void)next:(__unused id)sender {
    [YTMUOfflinePlaybackManager.sharedManager next];
}

- (void)showMore:(UIView *)sender {
    __weak typeof(self) weakSelf = self;
    YTMUPresentOfflinePlayerMenu(self.presenter, sender, ^{
        [weakSelf openPlayer:nil];
    });
}

- (void)openPlayer:(__unused id)sender {
    if (self.presenter == nil || !YTMUOfflinePlaybackManager.sharedManager.offlineSessionActive
        || self.presenter.presentedViewController != nil) {
        return;
    }
    YTMUOfflineNowPlayingViewController *controller = [[YTMUOfflineNowPlayingViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.presenter presentViewController:navigation animated:YES completion:nil];
}

@end
