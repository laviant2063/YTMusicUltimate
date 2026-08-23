#import "YTMUOfflineMiniPlayerView.h"

#import "YTMUOfflineNowPlayingViewController.h"
#import "YTMUOfflinePlaybackManager.h"
#import "YTMUOfflinePlayerMenu.h"
#import "../Headers/Localization.h"

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
@property (nonatomic, assign) BOOL sessionActive;
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

        _artworkView = [[UIImageView alloc] init];
        _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = 8;
        _artworkView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _artistLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _artistLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.58];
        _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _badgeLabel = [[UILabel alloc] init];
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeLabel.text = YTMUMiniPlayerLocalized(@"OFFLINE_BADGE", @"Offline");
        _badgeLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
        _badgeLabel.textColor = UIColor.systemPinkColor;
        _badgeLabel.backgroundColor = [UIColor.systemPinkColor colorWithAlphaComponent:0.14];
        _badgeLabel.layer.cornerRadius = 7;
        _badgeLabel.clipsToBounds = YES;
        _badgeLabel.textAlignment = NSTextAlignmentCenter;

        _playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
        _playPauseButton.tintColor = UIColor.whiteColor;
        [_playPauseButton addTarget:self action:@selector(togglePlayback:) forControlEvents:UIControlEventTouchUpInside];

        _nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _nextButton.translatesAutoresizingMaskIntoConstraints = NO;
        _nextButton.tintColor = UIColor.whiteColor;
        [_nextButton setImage:[UIImage systemImageNamed:@"forward.end.fill"] forState:UIControlStateNormal];
        [_nextButton addTarget:self action:@selector(next:) forControlEvents:UIControlEventTouchUpInside];

        _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _moreButton.translatesAutoresizingMaskIntoConstraints = NO;
        _moreButton.tintColor = UIColor.whiteColor;
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

        [NSLayoutConstraint activateConstraints:@[
            [_artworkView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_artworkView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_artworkView.widthAnchor constraintEqualToConstant:56],
            [_artworkView.heightAnchor constraintEqualToConstant:56],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_artworkView.trailingAnchor constant:10],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_playPauseButton.leadingAnchor constant:-6],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:self.centerYAnchor constant:-3],

            [_badgeLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_badgeLabel.topAnchor constraintEqualToAnchor:self.centerYAnchor constant:4],
            [_badgeLabel.widthAnchor constraintEqualToConstant:48],
            [_badgeLabel.heightAnchor constraintEqualToConstant:15],
            [_artistLabel.leadingAnchor constraintEqualToAnchor:_badgeLabel.trailingAnchor constant:6],
            [_artistLabel.centerYAnchor constraintEqualToAnchor:_badgeLabel.centerYAnchor],
            [_artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_playPauseButton.leadingAnchor constant:-6],

            [_playPauseButton.trailingAnchor constraintEqualToAnchor:_nextButton.leadingAnchor constant:-1],
            [_playPauseButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_playPauseButton.widthAnchor constraintEqualToConstant:40],
            [_playPauseButton.heightAnchor constraintEqualToConstant:48],
            [_nextButton.trailingAnchor constraintEqualToAnchor:_moreButton.leadingAnchor constant:-1],
            [_nextButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_nextButton.widthAnchor constraintEqualToConstant:38],
            [_nextButton.heightAnchor constraintEqualToConstant:48],
            [_moreButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_moreButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_moreButton.widthAnchor constraintEqualToConstant:34],
            [_moreButton.heightAnchor constraintEqualToConstant:48],
        ]];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackChanged:)
                                                     name:YTMUOfflinePlaybackDidChangeNotification object:nil];
        [self updateUI];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, self.sessionActive ? 78 : 0);
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

- (void)playbackChanged:(__unused NSNotification *)notification {
    [self updateUI];
}

- (void)updateUI {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUOfflineTrack *track = manager.currentTrack;
    BOOL active = manager.offlineSessionActive && track != nil;
    BOOL visibilityChanged = active != self.sessionActive;
    self.sessionActive = active;
    self.hidden = !active;
    self.accessibilityElementsHidden = !active;

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
    self.playPauseButton.enabled = active;
    self.nextButton.enabled = active && manager.queue.count > 1;
    self.moreButton.enabled = active;

    if (visibilityChanged) {
        [self invalidateIntrinsicContentSize];
        [self.superview setNeedsLayout];
        [UIView animateWithDuration:0.2 animations:^{ [self.superview layoutIfNeeded]; }];
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
