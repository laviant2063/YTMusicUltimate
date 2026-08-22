#import "YTMUOfflineNowPlayingViewController.h"

#import "YTMUOfflinePlaybackManager.h"
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
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                                   weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbolName withConfiguration:configuration] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    return button;
}

@interface YTMUOfflineNowPlayingViewController () <UITableViewDataSource, UITableViewDelegate>
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
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation YTMUOfflineNowPlayingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTMUOfflineLocalized(@"OFFLINE_PLAYER", @"Offline Player");
    self.view.backgroundColor = UIColor.blackColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close:)];

    self.artworkView = [[UIImageView alloc] init];
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 12;
    self.artworkView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 2;

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.artistLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    self.artistLabel.textAlignment = NSTextAlignmentCenter;

    self.progressSlider = [[UISlider alloc] init];
    self.progressSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressSlider.minimumTrackTintColor = UIColor.whiteColor;
    self.progressSlider.maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.25];
    [self.progressSlider addTarget:self action:@selector(seekFinished:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    self.elapsedLabel = [[UILabel alloc] init];
    self.elapsedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.elapsedLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    self.durationLabel = [[UILabel alloc] init];
    self.durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.durationLabel.font = self.elapsedLabel.font;
    self.durationLabel.textColor = self.elapsedLabel.textColor;
    self.durationLabel.textAlignment = NSTextAlignmentRight;

    self.shuffleButton = YTMUOfflineControlButton(@"shuffle", 22);
    self.previousButton = YTMUOfflineControlButton(@"backward.end.fill", 28);
    self.playPauseButton = YTMUOfflineControlButton(@"play.circle.fill", 54);
    self.nextButton = YTMUOfflineControlButton(@"forward.end.fill", 28);
    self.repeatButton = YTMUOfflineControlButton(@"repeat", 22);
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

    UILabel *queueLabel = [[UILabel alloc] init];
    queueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    queueLabel.text = YTMUOfflineLocalized(@"CURRENT_QUEUE", @"Current Queue");
    queueLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    queueLabel.textColor = UIColor.whiteColor;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorColor = [UIColor.whiteColor colorWithAlphaComponent:0.12];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.allowsSelectionDuringEditing = YES;
    [self.tableView setEditing:YES animated:NO];

    [self.view addSubview:self.artworkView];
    [self.view addSubview:self.titleLabel];
    [self.view addSubview:self.artistLabel];
    [self.view addSubview:self.progressSlider];
    [self.view addSubview:self.elapsedLabel];
    [self.view addSubview:self.durationLabel];
    [self.view addSubview:controls];
    [self.view addSubview:queueLabel];
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.artworkView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        [self.artworkView.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.artworkView.widthAnchor constraintEqualToConstant:168],
        [self.artworkView.heightAnchor constraintEqualToAnchor:self.artworkView.widthAnchor],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkView.bottomAnchor constant:12],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.artistLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:3],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        [self.progressSlider.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:12],
        [self.progressSlider.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.progressSlider.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.elapsedLabel.topAnchor constraintEqualToAnchor:self.progressSlider.bottomAnchor constant:1],
        [self.elapsedLabel.leadingAnchor constraintEqualToAnchor:self.progressSlider.leadingAnchor],
        [self.durationLabel.topAnchor constraintEqualToAnchor:self.elapsedLabel.topAnchor],
        [self.durationLabel.trailingAnchor constraintEqualToAnchor:self.progressSlider.trailingAnchor],

        [controls.topAnchor constraintEqualToAnchor:self.elapsedLabel.bottomAnchor constant:8],
        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28],
        [controls.heightAnchor constraintEqualToConstant:64],

        [queueLabel.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:10],
        [queueLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [queueLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [self.tableView.topAnchor constraintEqualToAnchor:queueLabel.bottomAnchor constant:6],
        [self.tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackChanged:)
                                                 name:YTMUOfflinePlaybackDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(progressChanged:)
                                                 name:YTMUOfflinePlaybackProgressNotification object:nil];
    [self updatePlaybackUIReloadingQueue:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleShuffle:(id)sender {
    [YTMUOfflinePlaybackManager.sharedManager toggleShuffle];
}

- (void)previous:(id)sender {
    [YTMUOfflinePlaybackManager.sharedManager previous];
}

- (void)togglePlayback:(id)sender {
    [YTMUOfflinePlaybackManager.sharedManager togglePlayback];
}

- (void)next:(id)sender {
    [YTMUOfflinePlaybackManager.sharedManager next];
}

- (void)cycleRepeat:(id)sender {
    [YTMUOfflinePlaybackManager.sharedManager cycleRepeatMode];
}

- (void)seekFinished:(UISlider *)slider {
    [YTMUOfflinePlaybackManager.sharedManager seekToTime:slider.value];
}

- (void)playbackChanged:(NSNotification *)notification {
    [self updatePlaybackUIReloadingQueue:YES];
}

- (void)progressChanged:(NSNotification *)notification {
    [self updatePlaybackUIReloadingQueue:NO];
}

- (void)updatePlaybackUIReloadingQueue:(BOOL)reloadQueue {
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUOfflineTrack *track = manager.currentTrack;
    self.titleLabel.text = track.title.length > 0 ? track.title : YTMUOfflineLocalized(@"NOTHING_PLAYING", @"Nothing Playing");
    self.artistLabel.text = track.artist ?: @"";
    UIImage *artwork = nil;
    if (track.artworkFileName.length > 0) {
        NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL URLByAppendingPathComponent:track.artworkFileName];
        artwork = [UIImage imageWithContentsOfFile:url.path];
    }
    self.artworkView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    self.artworkView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];

    UIImageSymbolConfiguration *playConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:54 weight:UIImageSymbolWeightRegular];
    NSString *playSymbol = manager.playing ? @"pause.circle.fill" : @"play.circle.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:playSymbol withConfiguration:playConfiguration] forState:UIControlStateNormal];
    self.shuffleButton.tintColor = manager.shuffled ? UIColor.systemPinkColor : UIColor.whiteColor;
    NSString *repeatSymbol = manager.repeatMode == YTMUOfflineRepeatModeOne ? @"repeat.1" : @"repeat";
    UIImageSymbolConfiguration *repeatConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    [self.repeatButton setImage:[UIImage systemImageNamed:repeatSymbol withConfiguration:repeatConfiguration] forState:UIControlStateNormal];
    self.repeatButton.tintColor = manager.repeatMode == YTMUOfflineRepeatModeOff ? UIColor.whiteColor : UIColor.systemPinkColor;

    if (!self.progressSlider.tracking) {
        self.progressSlider.maximumValue = (float)MAX(1.0, manager.duration);
        self.progressSlider.value = (float)MIN(self.progressSlider.maximumValue, manager.currentTime);
    }
    self.elapsedLabel.text = YTMUOfflineTimeString(manager.currentTime);
    self.durationLabel.text = YTMUOfflineTimeString(manager.duration);
    if (reloadQueue) {
        [self.tableView reloadData];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
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
    cell.textLabel.textColor = indexPath.row == manager.currentIndex ? UIColor.systemPinkColor : UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.55];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [YTMUOfflinePlaybackManager.sharedManager playQueueIndex:indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    [YTMUOfflinePlaybackManager.sharedManager moveQueueItemFromIndex:sourceIndexPath.row toIndex:destinationIndexPath.row];
}

@end
