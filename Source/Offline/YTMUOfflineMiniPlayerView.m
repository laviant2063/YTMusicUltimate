#import "YTMUOfflineMiniPlayerView.h"

#import "YTMUOfflineNowPlayingViewController.h"
#import "YTMUOfflinePlaybackManager.h"

@interface YTMUOfflineMiniPlayerView ()
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@end

@implementation YTMUOfflineMiniPlayerView

- (instancetype)initWithPresenter:(UIViewController *)presenter {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _presenter = presenter;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.15].CGColor;

        _artworkView = [[UIImageView alloc] init];
        _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = 6;
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

        _playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
        _playPauseButton.tintColor = UIColor.whiteColor;
        [_playPauseButton addTarget:self action:@selector(togglePlayback:) forControlEvents:UIControlEventTouchUpInside];

        _nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _nextButton.translatesAutoresizingMaskIntoConstraints = NO;
        _nextButton.tintColor = UIColor.whiteColor;
        [_nextButton setImage:[UIImage systemImageNamed:@"forward.end.fill"] forState:UIControlStateNormal];
        [_nextButton addTarget:self action:@selector(next:) forControlEvents:UIControlEventTouchUpInside];

        [self addSubview:_artworkView];
        [self addSubview:_titleLabel];
        [self addSubview:_artistLabel];
        [self addSubview:_playPauseButton];
        [self addSubview:_nextButton];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPlayer:)]];

        [NSLayoutConstraint activateConstraints:@[
            [_artworkView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_artworkView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_artworkView.widthAnchor constraintEqualToConstant:48],
            [_artworkView.heightAnchor constraintEqualToConstant:48],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_artworkView.trailingAnchor constant:10],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_playPauseButton.leadingAnchor constant:-8],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:self.centerYAnchor constant:-1],
            [_artistLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_artistLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_artistLabel.topAnchor constraintEqualToAnchor:self.centerYAnchor constant:2],
            [_playPauseButton.trailingAnchor constraintEqualToAnchor:_nextButton.leadingAnchor constant:-4],
            [_playPauseButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_playPauseButton.widthAnchor constraintEqualToConstant:42],
            [_playPauseButton.heightAnchor constraintEqualToConstant:42],
            [_nextButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_nextButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_nextButton.widthAnchor constraintEqualToConstant:38],
            [_nextButton.heightAnchor constraintEqualToConstant:42],
        ]];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackChanged:)
                                                     name:YTMUOfflinePlaybackDidChangeNotification object:nil];
        [self updateUI];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)playbackChanged:(NSNotification *)notification {
    [self updateUI];
}

- (void)updateUI {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUOfflineTrack *track = manager.currentTrack;
    self.titleLabel.text = track.title.length > 0 ? track.title : @"Offline player";
    self.artistLabel.text = track != nil ? track.artist : @"Choose a downloaded song";
    UIImage *artwork = nil;
    if (track.artworkFileName.length > 0) {
        NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL URLByAppendingPathComponent:track.artworkFileName];
        artwork = [UIImage imageWithContentsOfFile:url.path];
    }
    self.artworkView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    self.artworkView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    NSString *symbol = manager.playing ? @"pause.fill" : @"play.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    self.playPauseButton.enabled = track != nil;
    self.nextButton.enabled = manager.queue.count > 1;
}

- (void)togglePlayback:(id)sender {
    [YTMUOfflinePlaybackManager.sharedManager togglePlayback];
}

- (void)next:(id)sender {
    [YTMUOfflinePlaybackManager.sharedManager next];
}

- (void)openPlayer:(id)sender {
    if (self.presenter == nil || YTMUOfflinePlaybackManager.sharedManager.currentTrack == nil
        || self.presenter.presentedViewController != nil) {
        return;
    }
    YTMUOfflineNowPlayingViewController *controller = [[YTMUOfflineNowPlayingViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.presenter presentViewController:navigation animated:YES completion:nil];
}

@end
