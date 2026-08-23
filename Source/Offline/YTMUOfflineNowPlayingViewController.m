#import "YTMUOfflineNowPlayingViewController.h"

#import <AVKit/AVKit.h>

#import "YTMUOfflinePlaybackManager.h"
#import "YTMUOfflinePlayerMenu.h"
#import "../Headers/Localization.h"

#include <math.h>

static NSString *YTMUOfflineLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

static NSString *YTMUOfflineTimeString(NSTimeInterval time) {
    if (!isfinite(time) || time < 0) time = 0;
    NSInteger seconds = (NSInteger)llround(time);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static UIButton *YTMUOfflineControlButton(NSString *symbolName, CGFloat pointSize) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbolName withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    return button;
}

static UIColor *YTMUOfflineArtworkColor(UIImage *image) {
    if (image.CGImage == nil) {
        return [UIColor colorWithRed:0.035 green:0.09 blue:0.20 alpha:1.0];
    }
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return [UIColor colorWithRed:0.035 green:0.09 blue:0.20 alpha:1.0];
    }
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);
    CGFloat red = pixel[0] / 255.0;
    CGFloat green = pixel[1] / 255.0;
    CGFloat blue = pixel[2] / 255.0;
    CGFloat maximum = MAX(red, MAX(green, blue));
    if (maximum < 0.12) {
        red += 0.08;
        green += 0.08;
        blue += 0.11;
    }
    return [UIColor colorWithRed:MIN(0.32, red * 0.45)
                           green:MIN(0.32, green * 0.45)
                            blue:MIN(0.36, blue * 0.5)
                           alpha:1.0];
}

@interface YTMUOfflineNowPlayingViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *queueLabel;
@property (nonatomic, assign) BOOL dismissingAfterSessionEnd;
@end


@implementation YTMUOfflineNowPlayingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.gradientLayer = [CAGradientLayer layer];
    self.gradientLayer.colors = @[
        (id)[UIColor colorWithRed:0.035 green:0.09 blue:0.20 alpha:1.0].CGColor,
        (id)[UIColor colorWithWhite:0.025 alpha:1.0].CGColor,
        (id)UIColor.blackColor.CGColor,
    ];
    self.gradientLayer.locations = @[@0, @0.58, @1];
    [self.view.layer insertSublayer:self.gradientLayer atIndex:0];

    UIButton *minimizeButton = YTMUOfflineControlButton(@"chevron.down", 20);
    [minimizeButton addTarget:self action:@selector(minimizePlayer:) forControlEvents:UIControlEventTouchUpInside];
    minimizeButton.accessibilityLabel = @"플레이어 축소";

    UIImageView *badgeIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.to.line"];
    badgeIcon.translatesAutoresizingMaskIntoConstraints = NO;
    badgeIcon.tintColor = UIColor.whiteColor;
    [badgeIcon.widthAnchor constraintEqualToConstant:15].active = YES;
    [badgeIcon.heightAnchor constraintEqualToConstant:15].active = YES;
    UILabel *badgeLabel = [[UILabel alloc] init];
    badgeLabel.text = YTMUOfflineLocalized(@"OFFLINE_PLAYBACK_BADGE", @"Offline Playback");
    badgeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    badgeLabel.textColor = UIColor.whiteColor;
    UIStackView *badgeStack = [[UIStackView alloc] initWithArrangedSubviews:@[badgeIcon, badgeLabel]];
    badgeStack.translatesAutoresizingMaskIntoConstraints = NO;
    badgeStack.axis = UILayoutConstraintAxisHorizontal;
    badgeStack.spacing = 6;
    badgeStack.alignment = UIStackViewAlignmentCenter;
    badgeStack.layoutMargins = UIEdgeInsetsMake(7, 12, 7, 12);
    badgeStack.layoutMarginsRelativeArrangement = YES;
    badgeStack.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.24];
    badgeStack.layer.cornerRadius = 16;
    badgeStack.layer.borderWidth = 0.5;
    badgeStack.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.2].CGColor;

    AVRoutePickerView *routePicker = [[AVRoutePickerView alloc] init];
    routePicker.translatesAutoresizingMaskIntoConstraints = NO;
    routePicker.tintColor = UIColor.whiteColor;
    routePicker.activeTintColor = UIColor.systemPinkColor;
    routePicker.prioritizesVideoDevices = NO;

    self.moreButton = YTMUOfflineControlButton(@"ellipsis", 21);
    [self.moreButton addTarget:self action:@selector(showMore:) forControlEvents:UIControlEventTouchUpInside];

    self.artworkView = [[UIImageView alloc] init];
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 13;
    self.artworkView.layer.cornerCurve = kCACornerCurveContinuous;
    self.artworkView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.numberOfLines = 2;

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.artistLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];

    self.progressSlider = [[UISlider alloc] init];
    self.progressSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressSlider.minimumTrackTintColor = UIColor.whiteColor;
    self.progressSlider.maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.25];
    [self.progressSlider addTarget:self action:@selector(seekFinished:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    self.elapsedLabel = [[UILabel alloc] init];
    self.elapsedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.elapsedLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.64];
    self.durationLabel = [[UILabel alloc] init];
    self.durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.durationLabel.font = self.elapsedLabel.font;
    self.durationLabel.textColor = self.elapsedLabel.textColor;
    self.durationLabel.textAlignment = NSTextAlignmentRight;

    self.shuffleButton = YTMUOfflineControlButton(@"shuffle", 21);
    self.previousButton = YTMUOfflineControlButton(@"backward.end.fill", 27);
    self.playPauseButton = YTMUOfflineControlButton(@"play.circle.fill", 58);
    self.nextButton = YTMUOfflineControlButton(@"forward.end.fill", 27);
    self.repeatButton = YTMUOfflineControlButton(@"repeat", 21);
    [self.shuffleButton addTarget:self action:@selector(toggleShuffle:) forControlEvents:UIControlEventTouchUpInside];
    [self.previousButton addTarget:self action:@selector(previous:) forControlEvents:UIControlEventTouchUpInside];
    [self.playPauseButton addTarget:self action:@selector(togglePlayback:) forControlEvents:UIControlEventTouchUpInside];
    [self.nextButton addTarget:self action:@selector(next:) forControlEvents:UIControlEventTouchUpInside];
    [self.repeatButton addTarget:self action:@selector(cycleRepeat:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.shuffleButton, self.previousButton, self.playPauseButton, self.nextButton, self.repeatButton
    ]];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.distribution = UIStackViewDistributionEqualSpacing;

    self.queueLabel = [[UILabel alloc] init];
    self.queueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.queueLabel.text = YTMUOfflineLocalized(@"UP_NEXT", @"Up Next");
    self.queueLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.queueLabel.textColor = UIColor.whiteColor;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.18];
    self.tableView.separatorColor = [UIColor.whiteColor colorWithAlphaComponent:0.11];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 58;
    self.tableView.layer.cornerRadius = 16;
    self.tableView.layer.cornerCurve = kCACornerCurveContinuous;
    self.tableView.allowsSelectionDuringEditing = YES;
    [self.tableView setEditing:YES animated:NO];

    [self.view addSubview:minimizeButton];
    [self.view addSubview:badgeStack];
    [self.view addSubview:routePicker];
    [self.view addSubview:self.moreButton];
    [self.view addSubview:self.artworkView];
    [self.view addSubview:self.titleLabel];
    [self.view addSubview:self.artistLabel];
    [self.view addSubview:self.progressSlider];
    [self.view addSubview:self.elapsedLabel];
    [self.view addSubview:self.durationLabel];
    [self.view addSubview:controls];
    [self.view addSubview:self.queueLabel];
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *artworkWidth = [self.artworkView.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-48];
    artworkWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [minimizeButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:7],
        [minimizeButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:1],
        [minimizeButton.widthAnchor constraintEqualToConstant:44],
        [minimizeButton.heightAnchor constraintEqualToConstant:44],
        [badgeStack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [badgeStack.centerYAnchor constraintEqualToAnchor:minimizeButton.centerYAnchor],
        [routePicker.trailingAnchor constraintEqualToAnchor:self.moreButton.leadingAnchor constant:-2],
        [routePicker.centerYAnchor constraintEqualToAnchor:minimizeButton.centerYAnchor],
        [routePicker.widthAnchor constraintEqualToConstant:42],
        [routePicker.heightAnchor constraintEqualToConstant:42],
        [self.moreButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-5],
        [self.moreButton.centerYAnchor constraintEqualToAnchor:minimizeButton.centerYAnchor],
        [self.moreButton.widthAnchor constraintEqualToConstant:42],
        [self.moreButton.heightAnchor constraintEqualToConstant:42],

        [self.artworkView.topAnchor constraintEqualToAnchor:minimizeButton.bottomAnchor constant:13],
        [self.artworkView.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        artworkWidth,
        [self.artworkView.widthAnchor constraintLessThanOrEqualToConstant:350],
        [self.artworkView.widthAnchor constraintGreaterThanOrEqualToConstant:220],
        [self.artworkView.heightAnchor constraintEqualToAnchor:self.artworkView.widthAnchor],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkView.bottomAnchor constant:15],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-22],
        [self.artistLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:3],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        [self.progressSlider.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:11],
        [self.progressSlider.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22],
        [self.progressSlider.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-22],
        [self.elapsedLabel.topAnchor constraintEqualToAnchor:self.progressSlider.bottomAnchor constant:1],
        [self.elapsedLabel.leadingAnchor constraintEqualToAnchor:self.progressSlider.leadingAnchor],
        [self.durationLabel.topAnchor constraintEqualToAnchor:self.elapsedLabel.topAnchor],
        [self.durationLabel.trailingAnchor constraintEqualToAnchor:self.progressSlider.trailingAnchor],

        [controls.topAnchor constraintEqualToAnchor:self.elapsedLabel.bottomAnchor constant:5],
        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [controls.heightAnchor constraintEqualToConstant:64],

        [self.queueLabel.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:9],
        [self.queueLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [self.queueLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [self.tableView.topAnchor constraintEqualToAnchor:self.queueLabel.bottomAnchor constant:6],
        [self.tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [self.tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackChanged:)
                                                 name:YTMUOfflinePlaybackDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(progressChanged:)
                                                 name:YTMUOfflinePlaybackProgressNotification object:nil];
    [self updatePlaybackUIReloadingQueue:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.gradientLayer.frame = self.view.bounds;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)minimizePlayer:(__unused id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showMore:(UIView *)sender {
    __weak typeof(self) weakSelf = self;
    YTMUPresentOfflinePlayerMenu(self, sender, ^{
        if (weakSelf.tableView.numberOfSections > 0
            && [weakSelf.tableView numberOfRowsInSection:0] > 0) {
            NSInteger row = MAX(0, MIN(YTMUOfflinePlaybackManager.sharedManager.currentIndex,
                                       [weakSelf.tableView numberOfRowsInSection:0] - 1));
            [weakSelf.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                                      atScrollPosition:UITableViewScrollPositionTop
                                              animated:YES];
        }
    });
}

- (void)toggleShuffle:(__unused id)sender {
    [YTMUOfflinePlaybackManager.sharedManager toggleShuffle];
}

- (void)previous:(__unused id)sender {
    [YTMUOfflinePlaybackManager.sharedManager previous];
}

- (void)togglePlayback:(__unused id)sender {
    [YTMUOfflinePlaybackManager.sharedManager togglePlayback];
}

- (void)next:(__unused id)sender {
    [YTMUOfflinePlaybackManager.sharedManager next];
}

- (void)cycleRepeat:(__unused id)sender {
    [YTMUOfflinePlaybackManager.sharedManager cycleRepeatMode];
}

- (void)seekFinished:(UISlider *)slider {
    [YTMUOfflinePlaybackManager.sharedManager seekToTime:slider.value];
}

- (void)playbackChanged:(__unused NSNotification *)notification {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    if (!manager.offlineSessionActive && !self.dismissingAfterSessionEnd) {
        self.dismissingAfterSessionEnd = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.navigationController dismissViewControllerAnimated:YES completion:nil];
        });
        return;
    }
    [self updatePlaybackUIReloadingQueue:YES];
}

- (void)progressChanged:(__unused NSNotification *)notification {
    [self updatePlaybackUIReloadingQueue:NO];
}

- (void)updatePlaybackUIReloadingQueue:(BOOL)reloadQueue {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUOfflineTrack *track = manager.currentTrack;
    self.titleLabel.text = track.title.length > 0 ? track.title : YTMUOfflineLocalized(@"NOTHING_PLAYING", @"Nothing Playing");
    self.artistLabel.text = track.artist ?: @"";
    UIImage *artwork = nil;
    if (track.artworkFileName.length > 0) {
        NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL
            URLByAppendingPathComponent:track.artworkFileName];
        artwork = [UIImage imageWithContentsOfFile:url.path];
    }
    self.artworkView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    self.artworkView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    UIColor *artworkColor = YTMUOfflineArtworkColor(artwork);
    self.gradientLayer.colors = @[
        (id)artworkColor.CGColor,
        (id)[artworkColor colorWithAlphaComponent:0.45].CGColor,
        (id)UIColor.blackColor.CGColor,
    ];

    UIImageSymbolConfiguration *playConfiguration = [UIImageSymbolConfiguration
        configurationWithPointSize:58 weight:UIImageSymbolWeightRegular];
    NSString *playSymbol = manager.playing ? @"pause.circle.fill" : @"play.circle.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:playSymbol withConfiguration:playConfiguration]
                          forState:UIControlStateNormal];
    self.shuffleButton.tintColor = manager.shuffled ? UIColor.systemPinkColor : UIColor.whiteColor;
    NSString *repeatSymbol = manager.repeatMode == YTMUOfflineRepeatModeOne ? @"repeat.1" : @"repeat";
    UIImageSymbolConfiguration *repeatConfiguration = [UIImageSymbolConfiguration
        configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    [self.repeatButton setImage:[UIImage systemImageNamed:repeatSymbol withConfiguration:repeatConfiguration]
                       forState:UIControlStateNormal];
    self.repeatButton.tintColor = manager.repeatMode == YTMUOfflineRepeatModeOff
        ? UIColor.whiteColor : UIColor.systemPinkColor;

    if (!self.progressSlider.tracking) {
        self.progressSlider.maximumValue = (float)MAX(1.0, manager.duration);
        self.progressSlider.value = (float)MIN(self.progressSlider.maximumValue, manager.currentTime);
    }
    self.elapsedLabel.text = YTMUOfflineTimeString(manager.currentTime);
    self.durationLabel.text = YTMUOfflineTimeString(manager.duration);
    if (reloadQueue) [self.tableView reloadData];
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return YTMUOfflinePlaybackManager.sharedManager.queue.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"OfflineQueueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUOfflineTrack *track = manager.queue[(NSUInteger)indexPath.row];
    cell.textLabel.text = track.title.length > 0 ? track.title : track.fileName.stringByDeletingPathExtension;
    cell.detailTextLabel.text = track.artist;
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.textLabel.textColor = indexPath.row == manager.currentIndex ? UIColor.systemPinkColor : UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.55];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.showsReorderControl = YES;
    UIImage *artwork = nil;
    if (track.artworkFileName.length > 0) {
        NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL
            URLByAppendingPathComponent:track.artworkFileName];
        artwork = [UIImage imageWithContentsOfFile:url.path];
    }
    cell.imageView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    cell.imageView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [YTMUOfflinePlaybackManager.sharedManager playQueueIndex:indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (BOOL)tableView:(__unused UITableView *)tableView canMoveRowAtIndexPath:(__unused NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(__unused UITableView *)tableView
            editingStyleForRowAtIndexPath:(__unused NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(__unused UITableView *)tableView
        shouldIndentWhileEditingRowAtIndexPath:(__unused NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(__unused UITableView *)tableView
        moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
               toIndexPath:(NSIndexPath *)destinationIndexPath {
    [YTMUOfflinePlaybackManager.sharedManager moveQueueItemFromIndex:sourceIndexPath.row
                                                             toIndex:destinationIndexPath.row];
}

@end
