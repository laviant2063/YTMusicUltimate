#import "YTMUOfflineNowPlayingViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>

#import "YTMUOfflinePlaybackManager.h"
#import "YTMUOfflinePlayerVisualPolicy.h"
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

static void YTMUOfflineSampleImageColor(CGImageRef image, uint8_t pixel[4]) {
    if (image == NULL) return;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) return;
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image);
    CGContextRelease(context);
}

@interface YTMUOfflineArtworkPaletteResult : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UIColor *backgroundColor;
@end

@implementation YTMUOfflineArtworkPaletteResult
@end

typedef void (^YTMUOfflineArtworkPaletteCompletion)(YTMUOfflineArtworkPaletteResult *result);

@interface YTMUOfflineArtworkPaletteProvider : NSObject
@property (nonatomic, strong) NSCache<NSString *, YTMUOfflineArtworkPaletteResult *> *cache;
+ (instancetype)sharedProvider;
- (void)loadArtworkAtURL:(NSURL *)url
                cacheKey:(NSString *)cacheKey
              completion:(YTMUOfflineArtworkPaletteCompletion)completion;
@end

@implementation YTMUOfflineArtworkPaletteProvider

+ (instancetype)sharedProvider {
    static YTMUOfflineArtworkPaletteProvider *provider = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        provider = [[YTMUOfflineArtworkPaletteProvider alloc] init];
        provider.cache = [[NSCache alloc] init];
        provider.cache.countLimit = 40;
    });
    return provider;
}

- (void)loadArtworkAtURL:(NSURL *)url
                cacheKey:(NSString *)cacheKey
              completion:(YTMUOfflineArtworkPaletteCompletion)completion {
    if (completion == nil || cacheKey.length == 0) return;
    YTMUOfflineArtworkPaletteResult *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGImageRef image = NULL;
        if (url != nil) {
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
            if (source != NULL) {
                image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
                CFRelease(source);
            }
        }
        uint8_t pixel[4] = {0, 0, 0, 0};
        YTMUOfflineSampleImageColor(image, pixel);
        YTMUOfflinePaletteColor palette = YTMUOfflineDarkPaletteColor(pixel[0], pixel[1], pixel[2]);

        dispatch_async(dispatch_get_main_queue(), ^{
            YTMUOfflineArtworkPaletteResult *result = [[YTMUOfflineArtworkPaletteResult alloc] init];
            if (image != NULL) {
                result.image = [UIImage imageWithCGImage:image];
                CGImageRelease(image);
            }
            result.backgroundColor = [UIColor colorWithRed:palette.red
                                                     green:palette.green
                                                      blue:palette.blue
                                                     alpha:1.0];
            [self.cache setObject:result forKey:cacheKey];
            completion(result);
        });
    });
}

@end

typedef void (^YTMUOfflineDurationCompletion)(NSTimeInterval duration);

@interface YTMUOfflineTrackDurationProvider : NSObject
@property (nonatomic, strong) NSCache<NSString *, NSNumber *> *cache;
+ (instancetype)sharedProvider;
- (void)loadDurationAtURL:(NSURL *)url
                 cacheKey:(NSString *)cacheKey
               completion:(YTMUOfflineDurationCompletion)completion;
@end

@implementation YTMUOfflineTrackDurationProvider

+ (instancetype)sharedProvider {
    static YTMUOfflineTrackDurationProvider *provider = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        provider = [[YTMUOfflineTrackDurationProvider alloc] init];
        provider.cache = [[NSCache alloc] init];
        provider.cache.countLimit = 200;
    });
    return provider;
}

- (void)loadDurationAtURL:(NSURL *)url
                 cacheKey:(NSString *)cacheKey
               completion:(YTMUOfflineDurationCompletion)completion {
    if (completion == nil || cacheKey.length == 0) return;
    NSNumber *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached.doubleValue); });
        return;
    }
    if (url == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(0); });
        return;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
        options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
        NSError *error = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:@"duration" error:&error];
        NSTimeInterval duration = status == AVKeyValueStatusLoaded ? CMTimeGetSeconds(asset.duration) : 0;
        if (!isfinite(duration) || duration < 0) duration = 0;
        NSNumber *value = @(duration);
        [self.cache setObject:value forKey:cacheKey];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(value.doubleValue); });
    }];
}

@end

@interface YTMUOfflineQueueCell : UITableViewCell
@property (nonatomic, strong) UIImageView *queueArtworkView;
@property (nonatomic, strong) UILabel *queueTitleLabel;
@property (nonatomic, strong) UILabel *queueArtistLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, copy) NSString *representedTrackID;
@end

@implementation YTMUOfflineQueueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.showsReorderControl = YES;

        _queueArtworkView = [[UIImageView alloc] init];
        _queueArtworkView.translatesAutoresizingMaskIntoConstraints = NO;
        _queueArtworkView.contentMode = UIViewContentModeScaleAspectFill;
        _queueArtworkView.clipsToBounds = YES;
        _queueArtworkView.layer.cornerRadius = 6;
        _queueArtworkView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];

        _queueTitleLabel = [[UILabel alloc] init];
        _queueTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _queueTitleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
            scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]
            maximumPointSize:18];
        _queueTitleLabel.adjustsFontForContentSizeCategory = YES;
        _queueTitleLabel.textColor = UIColor.whiteColor;
        _queueTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _queueArtistLabel = [[UILabel alloc] init];
        _queueArtistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _queueArtistLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
            scaledFontForFont:[UIFont systemFontOfSize:12]
            maximumPointSize:15];
        _queueArtistLabel.adjustsFontForContentSizeCategory = YES;
        _queueArtistLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.58];
        _queueArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _durationLabel = [[UILabel alloc] init];
        _durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _durationLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
        _durationLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.68];
        _durationLabel.textAlignment = NSTextAlignmentRight;
        [_durationLabel setContentHuggingPriority:UILayoutPriorityRequired
                                         forAxis:UILayoutConstraintAxisHorizontal];

        [self.contentView addSubview:_queueArtworkView];
        [self.contentView addSubview:_queueTitleLabel];
        [self.contentView addSubview:_queueArtistLabel];
        [self.contentView addSubview:_durationLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_queueArtworkView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [_queueArtworkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_queueArtworkView.widthAnchor constraintEqualToConstant:44],
            [_queueArtworkView.heightAnchor constraintEqualToConstant:44],
            [_queueTitleLabel.leadingAnchor constraintEqualToAnchor:_queueArtworkView.trailingAnchor constant:10],
            [_queueTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_durationLabel.leadingAnchor constant:-8],
            [_queueTitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:-2],
            [_queueArtistLabel.leadingAnchor constraintEqualToAnchor:_queueTitleLabel.leadingAnchor],
            [_queueArtistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_durationLabel.leadingAnchor constant:-8],
            [_queueArtistLabel.topAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:2],
            [_durationLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            [_durationLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedTrackID = nil;
    self.queueArtworkView.image = [UIImage systemImageNamed:@"music.note"];
    self.durationLabel.text = @"--:--";
}

@end

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
@property (nonatomic, copy) NSString *artworkRequestIdentifier;
@end


@implementation YTMUOfflineNowPlayingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.gradientLayer = [CAGradientLayer layer];
    self.gradientLayer.colors = @[
        (id)[UIColor colorWithRed:0.055 green:0.065 blue:0.10 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.025 green:0.03 blue:0.05 alpha:1.0].CGColor,
        (id)UIColor.blackColor.CGColor,
    ];
    self.gradientLayer.locations = @[@0, @0.58, @1];
    [self.view.layer insertSublayer:self.gradientLayer atIndex:0];

    UIButton *minimizeButton = YTMUOfflineControlButton(@"chevron.down", 20);
    [minimizeButton addTarget:self action:@selector(minimizePlayer:) forControlEvents:UIControlEventTouchUpInside];
    minimizeButton.accessibilityLabel = @"플레이어 축소";

    UIImageView *badgeIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.to.line"]];
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
    badgeStack.isAccessibilityElement = YES;
    badgeStack.accessibilityLabel = badgeLabel.text;

    AVRoutePickerView *routePicker = [[AVRoutePickerView alloc] init];
    routePicker.translatesAutoresizingMaskIntoConstraints = NO;
    routePicker.tintColor = UIColor.whiteColor;
    routePicker.activeTintColor = UIColor.systemPinkColor;
    routePicker.prioritizesVideoDevices = NO;

    self.moreButton = YTMUOfflineControlButton(@"ellipsis", 21);
    self.moreButton.accessibilityLabel = YTMUOfflineLocalized(@"MORE", @"More");
    [self.moreButton addTarget:self action:@selector(showMore:) forControlEvents:UIControlEventTouchUpInside];

    self.artworkView = [[UIImageView alloc] init];
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 13;
    self.artworkView.layer.cornerCurve = kCACornerCurveContinuous;
    self.artworkView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];
    self.artworkView.image = [UIImage systemImageNamed:@"music.note"];
    self.artworkView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
        scaledFontForFont:[UIFont systemFontOfSize:23 weight:UIFontWeightBold]
        maximumPointSize:29];
    self.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]
        maximumPointSize:20];
    self.artistLabel.adjustsFontForContentSizeCategory = YES;
    self.artistLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    self.artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    self.progressSlider = [[UISlider alloc] init];
    self.progressSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressSlider.minimumTrackTintColor = UIColor.whiteColor;
    self.progressSlider.maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.25];
    self.progressSlider.accessibilityLabel = YTMUOfflineLocalized(@"PLAYBACK_POSITION", @"Playback position");
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
    self.playPauseButton = YTMUOfflineControlButton(@"play.fill", 27);
    self.nextButton = YTMUOfflineControlButton(@"forward.end.fill", 27);
    self.repeatButton = YTMUOfflineControlButton(@"repeat", 21);
    self.shuffleButton.accessibilityLabel = YTMUOfflineLocalized(@"SHUFFLE", @"Shuffle");
    self.previousButton.accessibilityLabel = YTMUOfflineLocalized(@"PREVIOUS", @"Previous");
    self.playPauseButton.accessibilityLabel = YTMUOfflineLocalized(@"PLAY_PAUSE", @"Play or pause");
    self.nextButton.accessibilityLabel = YTMUOfflineLocalized(@"NEXT", @"Next");
    self.repeatButton.accessibilityLabel = YTMUOfflineLocalized(@"REPEAT", @"Repeat");
    self.playPauseButton.backgroundColor = UIColor.whiteColor;
    self.playPauseButton.tintColor = UIColor.blackColor;
    self.playPauseButton.layer.cornerRadius = 32;
    self.playPauseButton.layer.cornerCurve = kCACornerCurveContinuous;
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
    self.queueLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
        scaledFontForFont:[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]
        maximumPointSize:23];
    self.queueLabel.adjustsFontForContentSizeCategory = YES;
    self.queueLabel.textColor = UIColor.whiteColor;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.26];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 64;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.layer.cornerRadius = 18;
    self.tableView.layer.cornerCurve = kCACornerCurveContinuous;
    self.tableView.layer.borderWidth = 0.5;
    self.tableView.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.10].CGColor;
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
        [routePicker.widthAnchor constraintEqualToConstant:44],
        [routePicker.heightAnchor constraintEqualToConstant:44],
        [self.moreButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-5],
        [self.moreButton.centerYAnchor constraintEqualToAnchor:minimizeButton.centerYAnchor],
        [self.moreButton.widthAnchor constraintEqualToConstant:44],
        [self.moreButton.heightAnchor constraintEqualToConstant:44],

        [self.artworkView.topAnchor constraintEqualToAnchor:minimizeButton.bottomAnchor constant:13],
        [self.artworkView.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        artworkWidth,
        [self.artworkView.widthAnchor constraintLessThanOrEqualToConstant:350],
        [self.artworkView.widthAnchor constraintGreaterThanOrEqualToConstant:200],
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
        [self.shuffleButton.widthAnchor constraintEqualToConstant:44],
        [self.shuffleButton.heightAnchor constraintEqualToConstant:44],
        [self.previousButton.widthAnchor constraintEqualToConstant:44],
        [self.previousButton.heightAnchor constraintEqualToConstant:44],
        [self.playPauseButton.widthAnchor constraintEqualToConstant:64],
        [self.playPauseButton.heightAnchor constraintEqualToConstant:64],
        [self.nextButton.widthAnchor constraintEqualToConstant:44],
        [self.nextButton.heightAnchor constraintEqualToConstant:44],
        [self.repeatButton.widthAnchor constraintEqualToConstant:44],
        [self.repeatButton.heightAnchor constraintEqualToConstant:44],

        [self.queueLabel.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:9],
        [self.queueLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [self.queueLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [self.tableView.topAnchor constraintEqualToAnchor:self.queueLabel.bottomAnchor constant:6],
        [self.tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [self.tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-6],
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
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self playbackChanged:nil]; });
        return;
    }
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
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePlaybackUIReloadingQueue:reloadQueue];
        });
        return;
    }
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    YTMUOfflineTrack *track = manager.currentTrack;
    self.titleLabel.text = track.title.length > 0 ? track.title : YTMUOfflineLocalized(@"NOTHING_PLAYING", @"Nothing Playing");
    self.artistLabel.text = track.artist ?: @"";
    self.artworkView.accessibilityLabel = self.titleLabel.text;
    NSString *artworkRequestIdentifier = track == nil ? nil : [NSString stringWithFormat:@"%@|%@",
        track.trackID ?: @"", track.artworkFileName ?: @""];
    if (![self.artworkRequestIdentifier isEqualToString:artworkRequestIdentifier]) {
        self.artworkRequestIdentifier = artworkRequestIdentifier;
        self.artworkView.image = [UIImage systemImageNamed:@"music.note"];
        self.artworkView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
        YTMUOfflinePaletteColor fallback = YTMUOfflineDarkPaletteColor(0, 0, 0);
        UIColor *fallbackColor = [UIColor colorWithRed:fallback.red green:fallback.green
                                                  blue:fallback.blue alpha:1.0];
        self.gradientLayer.colors = @[
            (id)fallbackColor.CGColor,
            (id)[fallbackColor colorWithAlphaComponent:0.46].CGColor,
            (id)UIColor.blackColor.CGColor,
        ];

        if (artworkRequestIdentifier.length > 0) {
            NSURL *artworkURL = track.artworkFileName.length == 0 ? nil
                : [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL
                    URLByAppendingPathComponent:track.artworkFileName];
            NSString *requestedTrackID = [track.trackID copy];
            __weak typeof(self) weakSelf = self;
            [[YTMUOfflineArtworkPaletteProvider sharedProvider]
                loadArtworkAtURL:artworkURL cacheKey:artworkRequestIdentifier
                completion:^(YTMUOfflineArtworkPaletteResult *result) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf == nil
                        || ![strongSelf.artworkRequestIdentifier isEqualToString:artworkRequestIdentifier]
                        || ![YTMUOfflinePlaybackManager.sharedManager.currentTrack.trackID
                            isEqualToString:requestedTrackID]) {
                        return;
                    }
                    strongSelf.artworkView.image = result.image ?: [UIImage systemImageNamed:@"music.note"];
                    strongSelf.gradientLayer.colors = @[
                        (id)result.backgroundColor.CGColor,
                        (id)[result.backgroundColor colorWithAlphaComponent:0.46].CGColor,
                        (id)UIColor.blackColor.CGColor,
                    ];
                }];
        }
    }

    UIImageSymbolConfiguration *playConfiguration = [UIImageSymbolConfiguration
        configurationWithPointSize:27 weight:UIImageSymbolWeightBold];
    NSString *playSymbol = manager.playing ? @"pause.fill" : @"play.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:playSymbol withConfiguration:playConfiguration]
                          forState:UIControlStateNormal];
    self.shuffleButton.tintColor = manager.shuffled ? UIColor.systemPinkColor : UIColor.whiteColor;
    self.shuffleButton.accessibilityValue = manager.shuffled
        ? YTMUOfflineLocalized(@"ON", @"On") : YTMUOfflineLocalized(@"OFF", @"Off");
    NSString *repeatSymbol = manager.repeatMode == YTMUOfflineRepeatModeOne ? @"repeat.1" : @"repeat";
    UIImageSymbolConfiguration *repeatConfiguration = [UIImageSymbolConfiguration
        configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    [self.repeatButton setImage:[UIImage systemImageNamed:repeatSymbol withConfiguration:repeatConfiguration]
                       forState:UIControlStateNormal];
    self.repeatButton.tintColor = manager.repeatMode == YTMUOfflineRepeatModeOff
        ? UIColor.whiteColor : UIColor.systemPinkColor;
    switch (manager.repeatMode) {
        case YTMUOfflineRepeatModeOff:
            self.repeatButton.accessibilityValue = YTMUOfflineLocalized(@"REPEAT_OFF", @"Off");
            break;
        case YTMUOfflineRepeatModeAll:
            self.repeatButton.accessibilityValue = YTMUOfflineLocalized(@"REPEAT_ALL", @"All");
            break;
        case YTMUOfflineRepeatModeOne:
            self.repeatButton.accessibilityValue = YTMUOfflineLocalized(@"REPEAT_ONE", @"One song");
            break;
    }
    self.playPauseButton.accessibilityValue = manager.playing
        ? YTMUOfflineLocalized(@"PLAYING", @"Playing") : YTMUOfflineLocalized(@"PAUSED", @"Paused");

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
    YTMUOfflineQueueCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[YTMUOfflineQueueCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:identifier];
    }
    YTMUOfflinePlaybackManager *manager = YTMUOfflinePlaybackManager.sharedManager;
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= manager.queue.count) return cell;
    YTMUOfflineTrack *track = manager.queue[(NSUInteger)indexPath.row];
    cell.representedTrackID = track.trackID;
    cell.queueTitleLabel.text = track.title.length > 0
        ? track.title : track.fileName.stringByDeletingPathExtension;
    cell.queueArtistLabel.text = track.artist ?: @"";
    cell.queueTitleLabel.textColor = indexPath.row == manager.currentIndex
        ? UIColor.systemPinkColor : UIColor.whiteColor;
    cell.queueArtworkView.image = [UIImage systemImageNamed:@"music.note"];
    cell.queueArtworkView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    cell.durationLabel.text = indexPath.row == manager.currentIndex && manager.duration > 0
        ? YTMUOfflineTimeString(manager.duration) : @"--:--";
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@",
        cell.queueTitleLabel.text ?: @"", cell.queueArtistLabel.text ?: @"", cell.durationLabel.text ?: @""];

    NSString *representedTrackID = [track.trackID copy];
    NSString *artworkCacheKey = [NSString stringWithFormat:@"queue|%@|%@",
        track.trackID ?: @"", track.artworkFileName ?: @""];
    NSURL *artworkURL = track.artworkFileName.length == 0 ? nil
        : [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL
            URLByAppendingPathComponent:track.artworkFileName];
    [[YTMUOfflineArtworkPaletteProvider sharedProvider]
        loadArtworkAtURL:artworkURL cacheKey:artworkCacheKey
        completion:^(YTMUOfflineArtworkPaletteResult *result) {
            if ([cell.representedTrackID isEqualToString:representedTrackID]) {
                cell.queueArtworkView.image = result.image ?: [UIImage systemImageNamed:@"music.note"];
            }
        }];

    NSString *durationCacheKey = [NSString stringWithFormat:@"%@|%@",
        track.trackID ?: @"", track.fileName ?: @""];
    NSURL *audioURL = track.fileName.length == 0 ? nil
        : [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL
            URLByAppendingPathComponent:track.fileName];
    [[YTMUOfflineTrackDurationProvider sharedProvider]
        loadDurationAtURL:audioURL cacheKey:durationCacheKey completion:^(NSTimeInterval duration) {
            if (![cell.representedTrackID isEqualToString:representedTrackID]) return;
            cell.durationLabel.text = duration > 0 ? YTMUOfflineTimeString(duration) : @"--:--";
            cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@",
                cell.queueTitleLabel.text ?: @"", cell.queueArtistLabel.text ?: @"",
                cell.durationLabel.text ?: @""];
        }];
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
