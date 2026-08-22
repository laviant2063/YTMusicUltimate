#import "YTMUOfflinePlaylistViewController.h"

#import "YTMUOfflineLibrary.h"
#import "YTMUOfflineMiniPlayerView.h"
#import "YTMUOfflinePlaybackManager.h"
#import "../Headers/Localization.h"

static NSString *YTMUOfflinePlaylistLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

static UIButton *YTMUOfflinePlaylistHeaderButton(NSString *title, NSString *symbol) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.12];
    button.layer.cornerRadius = 10;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -5, 0, 5);
    return button;
}

@interface YTMUOfflineTrackPickerViewController : UITableViewController
- (instancetype)initWithPlaylistID:(NSString *)playlistID;
@end

@interface YTMUOfflinePlaylistViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy, nullable) NSString *playlistID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *tracks;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) YTMUOfflineMiniPlayerView *miniPlayer;
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation YTMUOfflinePlaylistViewController

- (instancetype)initWithPlaylistID:(nullable NSString *)playlistID displayName:(NSString *)displayName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _playlistID = [playlistID copy];
        _displayName = [displayName copy];
        _tracks = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.displayName;
    self.view.backgroundColor = UIColor.blackColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close:)];
    if (self.playlistID != nil) {
        UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                            target:self action:@selector(addTracks:)];
        self.navigationItem.rightBarButtonItems = @[self.editButtonItem, add];
    }

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 70)];
    UIButton *playAll = YTMUOfflinePlaylistHeaderButton(YTMUOfflinePlaylistLocalized(@"PLAY_ALL", @"Play All"), @"play.fill");
    UIButton *shuffle = YTMUOfflinePlaylistHeaderButton(YTMUOfflinePlaylistLocalized(@"SHUFFLE_PLAY", @"Shuffle"), @"shuffle");
    [playAll addTarget:self action:@selector(playAll:) forControlEvents:UIControlEventTouchUpInside];
    [shuffle addTarget:self action:@selector(shufflePlay:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[playAll, shuffle]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 12;
    buttons.distribution = UIStackViewDistributionFillEqually;
    [header addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [buttons.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [buttons.topAnchor constraintEqualToAnchor:header.topAnchor constant:10],
        [buttons.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
    ]];
    self.tableView.tableHeaderView = header;

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = YTMUOfflinePlaylistLocalized(@"EMPTY_PLAYLIST", @"This playlist has no downloaded songs.");
    self.emptyLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.62];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.font = [UIFont systemFontOfSize:15];

    self.miniPlayer = [[YTMUOfflineMiniPlayerView alloc] initWithPresenter:self];
    [self.view addSubview:self.tableView];
    [self.view addSubview:self.miniPlayer];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.miniPlayer.topAnchor],
        [self.miniPlayer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.miniPlayer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.miniPlayer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.miniPlayer.heightAnchor constraintEqualToConstant:68],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(libraryChanged:)
                                                 name:YTMUOfflineLibraryDidChangeNotification object:nil];
    [self reloadTracks];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

- (void)close:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)libraryChanged:(NSNotification *)notification {
    [self reloadTracks];
}

- (void)reloadTracks {
    if (self.playlistID == nil) {
        self.tracks = YTMUOfflineLibrary.sharedLibrary.tracks;
    } else {
        YTMUOfflinePlaylist *playlist = [YTMUOfflineLibrary.sharedLibrary playlistForID:self.playlistID];
        if (playlist == nil) {
            [self dismissViewControllerAnimated:YES completion:nil];
            return;
        }
        self.title = playlist.name;
        self.tracks = [YTMUOfflineLibrary.sharedLibrary tracksForPlaylistID:self.playlistID];
    }
    self.tableView.backgroundView = self.tracks.count == 0 ? self.emptyLabel : nil;
    [self.tableView reloadData];
}

- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTMUOfflinePlaylistLocalized(@"OOPS", @"Oops")
                                                                   message:error.localizedDescription
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)playAll:(id)sender {
    if (self.tracks.count == 0) return;
    [YTMUOfflinePlaybackManager.sharedManager playTracks:self.tracks startingAtIndex:0 shuffle:NO];
}

- (void)shufflePlay:(id)sender {
    if (self.tracks.count == 0) return;
    NSInteger startingIndex = arc4random_uniform((uint32_t)self.tracks.count);
    [YTMUOfflinePlaybackManager.sharedManager playTracks:self.tracks startingAtIndex:startingIndex shuffle:YES];
}

- (void)addTracks:(id)sender {
    if (self.playlistID == nil) return;
    YTMUOfflineTrackPickerViewController *picker = [[YTMUOfflineTrackPickerViewController alloc]
        initWithPlaylistID:self.playlistID];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
    [self presentViewController:navigation animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"OfflinePlaylistTrackCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
    cell.textLabel.text = track.title.length > 0 ? track.title : track.fileName.stringByDeletingPathExtension;
    cell.detailTextLabel.text = track.artist;
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.55];
    cell.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.06];
    UIImage *artwork = nil;
    if (track.artworkFileName.length > 0) {
        NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL URLByAppendingPathComponent:track.artworkFileName];
        artwork = [UIImage imageWithContentsOfFile:url.path];
    }
    cell.imageView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    cell.imageView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [YTMUOfflinePlaybackManager.sharedManager playTracks:self.tracks startingAtIndex:indexPath.row shuffle:NO];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                      point:(CGPoint)point API_AVAILABLE(ios(13.0)) {
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:track.trackID previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *playOnly = [UIAction actionWithTitle:YTMUOfflinePlaylistLocalized(@"PLAY_THIS_SONG_ONLY", @"Play This Song Only")
                                                 image:[UIImage systemImageNamed:@"play.circle"]
                                            identifier:nil
                                               handler:^(__unused UIAction *action) {
            [YTMUOfflinePlaybackManager.sharedManager playSingleTrack:track];
        }];
        if (weakSelf.playlistID == nil) {
            return [UIMenu menuWithTitle:@"" children:@[playOnly]];
        }
        UIAction *remove = [UIAction actionWithTitle:YTMUOfflinePlaylistLocalized(@"REMOVE_FROM_PLAYLIST", @"Remove from Playlist")
                                               image:[UIImage systemImageNamed:@"minus.circle"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
            NSError *error = nil;
            if (![YTMUOfflineLibrary.sharedLibrary removeTrackID:track.trackID fromPlaylistID:weakSelf.playlistID error:&error]) {
                [weakSelf showError:error];
            }
        }];
        return [UIMenu menuWithTitle:@"" children:@[playOnly, remove]];
    }];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.playlistID != nil;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (self.playlistID == nil) return;
    NSMutableArray *trackIDs = [[self.tracks valueForKey:@"trackID"] mutableCopy];
    NSString *movedID = trackIDs[(NSUInteger)sourceIndexPath.row];
    [trackIDs removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [trackIDs insertObject:movedID atIndex:(NSUInteger)destinationIndexPath.row];
    NSError *error = nil;
    if (![YTMUOfflineLibrary.sharedLibrary setTrackIDs:trackIDs forPlaylistID:self.playlistID error:&error]) {
        [self showError:error];
        [self reloadTracks];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.playlistID == nil) return nil;
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                          title:YTMUOfflinePlaylistLocalized(@"REMOVE", @"Remove")
                                                                        handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
        NSError *error = nil;
        BOOL success = [YTMUOfflineLibrary.sharedLibrary removeTrackID:track.trackID
                                                        fromPlaylistID:weakSelf.playlistID error:&error];
        if (!success) [weakSelf showError:error];
        completion(success);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

@end

@interface YTMUOfflineTrackPickerViewController ()
@property (nonatomic, copy) NSString *playlistID;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *tracks;
@end

@implementation YTMUOfflineTrackPickerViewController

- (instancetype)initWithPlaylistID:(NSString *)playlistID {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _playlistID = [playlistID copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTMUOfflinePlaylistLocalized(@"ADD_SONGS", @"Add Songs");
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tracks = YTMUOfflineLibrary.sharedLibrary.tracks;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done:)];
}

- (void)done:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"OfflineTrackPickerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
    YTMUOfflinePlaylist *playlist = [YTMUOfflineLibrary.sharedLibrary playlistForID:self.playlistID];
    cell.textLabel.text = track.title.length > 0 ? track.title : track.fileName.stringByDeletingPathExtension;
    cell.detailTextLabel.text = track.artist;
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.55];
    cell.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.06];
    cell.accessoryType = [playlist.trackIDs containsObject:track.trackID]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
    YTMUOfflinePlaylist *playlist = [YTMUOfflineLibrary.sharedLibrary playlistForID:self.playlistID];
    NSError *error = nil;
    BOOL success = [playlist.trackIDs containsObject:track.trackID]
        ? [YTMUOfflineLibrary.sharedLibrary removeTrackID:track.trackID fromPlaylistID:self.playlistID error:&error]
        : [YTMUOfflineLibrary.sharedLibrary addTrackID:track.trackID toPlaylistID:self.playlistID error:&error];
    if (!success) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTMUOfflinePlaylistLocalized(@"OOPS", @"Oops")
                                                                       message:error.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
