#import "YTMDownloads.h"

#import "../Headers/Localization.h"
#import "../Headers/YTMToastController.h"
#import "../Offline/YTMUOfflineLibrary.h"
#import "../Offline/YTMUOfflineMiniPlayerView.h"
#import "../Offline/YTMUOfflinePlaybackManager.h"
#import "../Offline/YTMUOfflinePlaylistViewController.h"

typedef NS_ENUM(NSInteger, YTMUDownloadsSection) {
    YTMUDownloadsSectionPlaylists = 0,
    YTMUDownloadsSectionTracks = 1,
    YTMUDownloadsSectionFileActions = 2,
};

static NSString *YTMUDownloadsLocalized(NSString *key, NSString *fallback) {
    return [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil];
}

static UIButton *YTMUDownloadsHeaderButton(NSString *title, NSString *symbol) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.12];
    button.layer.cornerRadius = 10;
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    return button;
}

@interface YTMDownloads ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<YTMUOfflineTrack *> *tracks;
@property (nonatomic, strong) NSArray<YTMUOfflinePlaylist *> *playlists;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) YTMUOfflineMiniPlayerView *miniPlayer;
@end

@implementation YTMDownloads

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.tracks = @[];
    self.playlists = @[];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor colorWithRed:3/255.0 green:3/255.0 blue:3/255.0 alpha:1.0];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 72)];
    UIButton *playAll = YTMUDownloadsHeaderButton(YTMUDownloadsLocalized(@"PLAY_ALL", @"Play All"), @"play.fill");
    UIButton *shuffle = YTMUDownloadsHeaderButton(YTMUDownloadsLocalized(@"SHUFFLE_PLAY", @"Shuffle"), @"shuffle");
    UIButton *newPlaylist = YTMUDownloadsHeaderButton(YTMUDownloadsLocalized(@"NEW_PLAYLIST", @"New Playlist"), @"plus");
    [playAll addTarget:self action:@selector(playAll:) forControlEvents:UIControlEventTouchUpInside];
    [shuffle addTarget:self action:@selector(shufflePlay:) forControlEvents:UIControlEventTouchUpInside];
    [newPlaylist addTarget:self action:@selector(createPlaylist:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[playAll, shuffle, newPlaylist]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 8;
    buttons.distribution = UIStackViewDistributionFillEqually;
    [header addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [buttons.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [buttons.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12],
        [buttons.topAnchor constraintEqualToAnchor:header.topAnchor constant:10],
        [buttons.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
    ]];
    self.tableView.tableHeaderView = header;

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = YTMUDownloadsLocalized(@"EMPTY", @"Content you download will show here");
    self.emptyLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;

    self.miniPlayer = [[YTMUOfflineMiniPlayerView alloc] initWithPresenter:self];
    [self.view addSubview:self.tableView];
    [self.view addSubview:self.miniPlayer];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.miniPlayer.topAnchor],
        [self.miniPlayer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [self.miniPlayer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [self.miniPlayer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];

    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(downloadCompleted:) name:@"ReloadDataNotification" object:nil];
    [notifications addObserver:self selector:@selector(libraryChanged:) name:YTMUOfflineLibraryDidChangeNotification object:nil];
    [notifications addObserver:self selector:@selector(operationFailed:) name:YTMUOfflineLibraryErrorNotification object:nil];
    [notifications addObserver:self selector:@selector(operationFailed:) name:YTMUOfflinePlaybackErrorNotification object:nil];

    NSError *error = nil;
    if (![YTMUOfflineLibrary.sharedLibrary reload:&error] && error != nil) {
        [self showError:error];
    } else {
        [self reloadDataFromLibrary];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self reloadDataFromLibrary];
}

- (void)downloadCompleted:(NSNotification *)notification {
    NSError *error = nil;
    if (![YTMUOfflineLibrary.sharedLibrary reload:&error] && error != nil) {
        [self showError:error];
    }
}

- (void)libraryChanged:(NSNotification *)notification {
    [self reloadDataFromLibrary];
}

- (void)operationFailed:(NSNotification *)notification {
    NSString *message = notification.userInfo[@"message"];
    NSError *error = notification.userInfo[@"error"];
    [self showToast:message ?: error.localizedDescription ?: YTMUDownloadsLocalized(@"OOPS", @"Something went wrong")];
}

- (void)reloadDataFromLibrary {
    self.tracks = YTMUOfflineLibrary.sharedLibrary.tracks;
    self.playlists = YTMUOfflineLibrary.sharedLibrary.playlists;
    self.tableView.backgroundView = self.tracks.count == 0 ? self.emptyLabel : nil;
    [self.tableView reloadData];
}

- (void)showToast:(NSString *)message {
    Class toastClass = NSClassFromString(@"YTMToastController");
    id toast = [[toastClass alloc] init];
    if ([toast respondsToSelector:@selector(showMessage:)]) {
        [toast showMessage:message];
    }
}

- (void)showError:(NSError *)error {
    if (self.presentedViewController != nil) {
        [self showToast:error.localizedDescription];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTMUDownloadsLocalized(@"OOPS", @"Oops")
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

- (void)createPlaylist:(id)sender {
    [self promptForPlaylistName:nil completion:nil];
}

- (void)promptForPlaylistName:(nullable YTMUOfflinePlaylist *)playlist
                   completion:(void (^ _Nullable)(YTMUOfflinePlaylist *playlist))completion {
    NSString *title = playlist == nil ? YTMUDownloadsLocalized(@"NEW_PLAYLIST", @"New Playlist")
        : YTMUDownloadsLocalized(@"RENAME_PLAYLIST", @"Rename Playlist");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = YTMUDownloadsLocalized(@"PLAYLIST_NAME", @"Playlist name");
        textField.text = playlist.name;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"CANCEL", @"Cancel")
                                                style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:playlist == nil
                                                   ? YTMUDownloadsLocalized(@"CREATE", @"Create")
                                                   : YTMUDownloadsLocalized(@"RENAME", @"Rename")
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        YTMUOfflinePlaylist *result = playlist;
        if (playlist == nil) {
            result = [YTMUOfflineLibrary.sharedLibrary createPlaylistWithName:alert.textFields.firstObject.text error:&error];
        } else if (![YTMUOfflineLibrary.sharedLibrary renamePlaylistID:playlist.playlistID
                                                                   name:alert.textFields.firstObject.text error:&error]) {
            result = nil;
        }
        if (result == nil) {
            [weakSelf showError:error];
        } else if (completion != nil) {
            completion(result);
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((YTMUDownloadsSection)section) {
        case YTMUDownloadsSectionPlaylists:
            return self.playlists.count + 1;
        case YTMUDownloadsSectionTracks:
            return self.tracks.count;
        case YTMUDownloadsSectionFileActions:
            return self.tracks.count > 0 ? 2 : 0;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((YTMUDownloadsSection)section) {
        case YTMUDownloadsSectionPlaylists:
            return YTMUDownloadsLocalized(@"OFFLINE_PLAYLISTS", @"Offline Playlists");
        case YTMUDownloadsSectionTracks:
            return YTMUDownloadsLocalized(@"DOWNLOADED_SONGS", @"Downloaded Songs");
        case YTMUDownloadsSectionFileActions:
            return nil;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = indexPath.section == YTMUDownloadsSectionTracks ? @"DownloadedTrackCell" : @"DownloadsActionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.55];
    cell.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.06];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;

    if (indexPath.section == YTMUDownloadsSectionPlaylists) {
        BOOL allDownloads = indexPath.row == 0;
        YTMUOfflinePlaylist *playlist = allDownloads ? nil : self.playlists[(NSUInteger)indexPath.row - 1];
        cell.textLabel.text = allDownloads ? YTMUDownloadsLocalized(@"OFFLINE_ALL_DOWNLOADS", @"All Downloads") : playlist.name;
        NSInteger count = allDownloads ? self.tracks.count : [YTMUOfflineLibrary.sharedLibrary tracksForPlaylistID:playlist.playlistID].count;
        cell.detailTextLabel.text = [NSString stringWithFormat:YTMUDownloadsLocalized(@"SONG_COUNT", @"%ld songs"), (long)count];
        cell.imageView.image = [UIImage systemImageNamed:allDownloads ? @"tray.full" : @"music.note.list"];
        cell.imageView.tintColor = UIColor.systemPinkColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == YTMUDownloadsSectionTracks) {
        YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
        cell.textLabel.text = track.title.length > 0 ? track.title : track.fileName.stringByDeletingPathExtension;
        cell.detailTextLabel.text = track.artist;
        UIImage *artwork = nil;
        if (track.artworkFileName.length > 0) {
            NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL URLByAppendingPathComponent:track.artworkFileName];
            artwork = [UIImage imageWithContentsOfFile:url.path];
        }
        cell.imageView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
        cell.imageView.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
    } else {
        BOOL share = indexPath.row == 0;
        cell.textLabel.text = share ? YTMUDownloadsLocalized(@"SHARE_ALL", @"Share all audios")
            : YTMUDownloadsLocalized(@"REMOVE_ALL", @"Remove all audios");
        cell.textLabel.textColor = share ? UIColor.systemBlueColor : UIColor.systemRedColor;
        cell.imageView.image = [UIImage systemImageNamed:share ? @"square.and.arrow.up" : @"trash"];
        cell.imageView.tintColor = cell.textLabel.textColor;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == YTMUDownloadsSectionPlaylists) {
        NSString *playlistID = nil;
        NSString *name = YTMUDownloadsLocalized(@"OFFLINE_ALL_DOWNLOADS", @"All Downloads");
        if (indexPath.row > 0) {
            YTMUOfflinePlaylist *playlist = self.playlists[(NSUInteger)indexPath.row - 1];
            playlistID = playlist.playlistID;
            name = playlist.name;
        }
        YTMUOfflinePlaylistViewController *controller = [[YTMUOfflinePlaylistViewController alloc]
            initWithPlaylistID:playlistID displayName:name];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
        navigation.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:navigation animated:YES completion:nil];
    } else if (indexPath.section == YTMUDownloadsSectionTracks) {
        [YTMUOfflinePlaybackManager.sharedManager playTracks:self.tracks startingAtIndex:indexPath.row shuffle:NO];
    } else if (indexPath.row == 0) {
        [self shareAllFromView:[tableView cellForRowAtIndexPath:indexPath]];
    } else {
        [self confirmRemoveAll];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                      point:(CGPoint)point API_AVAILABLE(ios(13.0)) {
    if (indexPath.section != YTMUDownloadsSectionTracks) return nil;
    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:track.trackID previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *playOnly = [UIAction actionWithTitle:YTMUDownloadsLocalized(@"PLAY_THIS_SONG_ONLY", @"Play This Song Only")
                                                 image:[UIImage systemImageNamed:@"play.circle"] identifier:nil
                                               handler:^(__unused UIAction *action) {
            [YTMUOfflinePlaybackManager.sharedManager playSingleTrack:track];
        }];
        UIAction *add = [UIAction actionWithTitle:YTMUDownloadsLocalized(@"ADD_TO_PLAYLIST", @"Add to Playlist")
                                            image:[UIImage systemImageNamed:@"text.badge.plus"] identifier:nil
                                          handler:^(__unused UIAction *action) {
            [weakSelf addTrackToPlaylist:track sourceView:weakSelf.view];
        }];
        return [UIMenu menuWithTitle:@"" children:@[playOnly, add]];
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == YTMUDownloadsSectionPlaylists && indexPath.row > 0) {
        YTMUOfflinePlaylist *playlist = self.playlists[(NSUInteger)indexPath.row - 1];
        UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@""
                                                                          handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
            [weakSelf promptForPlaylistName:playlist completion:nil];
            completion(YES);
        }];
        rename.image = [UIImage systemImageNamed:@"pencil"];
        rename.backgroundColor = UIColor.systemOrangeColor;
        UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@""
                                                                          handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
            [weakSelf confirmDeletePlaylist:playlist];
            completion(YES);
        }];
        delete.image = [UIImage systemImageNamed:@"trash"];
        return [UISwipeActionsConfiguration configurationWithActions:@[delete, rename]];
    }
    if (indexPath.section != YTMUDownloadsSectionTracks) return nil;

    YTMUOfflineTrack *track = self.tracks[(NSUInteger)indexPath.row];
    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@""
                                                                       handler:^(__unused UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
        [weakSelf shareTrack:track fromView:view];
        completion(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = UIColor.systemBlueColor;
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@""
                                                                        handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
        [weakSelf promptRenameTrack:track];
        completion(YES);
    }];
    rename.image = [UIImage systemImageNamed:@"pencil"];
    rename.backgroundColor = UIColor.systemOrangeColor;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@""
                                                                        handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
        [weakSelf confirmDeleteTrack:track];
        completion(YES);
    }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, rename, share]];
}

- (void)addTrackToPlaylist:(YTMUOfflineTrack *)track sourceView:(UIView *)sourceView {
    if (self.playlists.count == 0) {
        __weak typeof(self) weakSelf = self;
        [self promptForPlaylistName:nil completion:^(YTMUOfflinePlaylist *playlist) {
            NSError *error = nil;
            if (![YTMUOfflineLibrary.sharedLibrary addTrackID:track.trackID toPlaylistID:playlist.playlistID error:&error]) {
                [weakSelf showError:error];
            }
        }];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:YTMUDownloadsLocalized(@"ADD_TO_PLAYLIST", @"Add to Playlist")
                                                                    message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (YTMUOfflinePlaylist *playlist in self.playlists) {
        [sheet addAction:[UIAlertAction actionWithTitle:playlist.name style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            NSError *error = nil;
            if (![YTMUOfflineLibrary.sharedLibrary addTrackID:track.trackID toPlaylistID:playlist.playlistID error:&error]) {
                [weakSelf showError:error];
            } else {
                [weakSelf showToast:YTMUDownloadsLocalized(@"ADDED_TO_PLAYLIST", @"Added to playlist")];
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"CANCEL", @"Cancel")
                                             style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptRenameTrack:(YTMUOfflineTrack *)track {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTMUDownloadsLocalized(@"RENAME", @"Rename")
                                                                   message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = track.fileName.stringByDeletingPathExtension;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"CANCEL", @"Cancel")
                                                style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"RENAME", @"Rename")
                                                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (![YTMUOfflineLibrary.sharedLibrary renameTrackID:track.trackID
                                                 toBaseName:alert.textFields.firstObject.text error:&error]) {
            [weakSelf showError:error];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteTrack:(YTMUOfflineTrack *)track {
    NSString *message = [NSString stringWithFormat:YTMUDownloadsLocalized(@"DELETE_MESSAGE", @"Are you sure you want to delete %@?"), track.title];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTMUDownloadsLocalized(@"DELETE", @"Delete")
                                                                   message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"CANCEL", @"Cancel")
                                                style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"DELETE", @"Delete")
                                                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (![YTMUOfflineLibrary.sharedLibrary deleteTrackID:track.trackID error:&error] && error != nil) {
            [weakSelf showError:error];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeletePlaylist:(YTMUOfflinePlaylist *)playlist {
    NSString *message = YTMUDownloadsLocalized(@"DELETE_PLAYLIST_MESSAGE", @"The downloaded audio files will not be deleted.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:playlist.name message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"CANCEL", @"Cancel")
                                                style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"DELETE", @"Delete")
                                                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (![YTMUOfflineLibrary.sharedLibrary deletePlaylistID:playlist.playlistID error:&error]) {
            [weakSelf showError:error];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmRemoveAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTMUDownloadsLocalized(@"REMOVE_ALL", @"Remove all audios")
                                                                   message:YTMUDownloadsLocalized(@"REMOVE_ALL_MESSAGE", @"Offline playlists will remain, but all downloaded audio files will be removed.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"CANCEL", @"Cancel")
                                                style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:YTMUDownloadsLocalized(@"DELETE", @"Delete")
                                                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (![YTMUOfflineLibrary.sharedLibrary removeAllDownloads:&error]) {
            [weakSelf showError:error];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareTrack:(YTMUOfflineTrack *)track fromView:(UIView *)sourceView {
    NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL URLByAppendingPathComponent:track.fileName];
    [self presentActivityForItems:@[url] sourceView:sourceView];
}

- (void)shareAllFromView:(UIView *)sourceView {
    NSMutableArray *urls = [NSMutableArray arrayWithCapacity:self.tracks.count];
    for (YTMUOfflineTrack *track in self.tracks) {
        NSURL *url = [YTMUOfflineLibrary.sharedLibrary.downloadsDirectoryURL URLByAppendingPathComponent:track.fileName];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) [urls addObject:url];
    }
    [self presentActivityForItems:urls sourceView:sourceView];
}

- (void)presentActivityForItems:(NSArray *)items sourceView:(UIView *)sourceView {
    if (items.count == 0) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    activity.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];
    activity.popoverPresentationController.sourceView = sourceView;
    activity.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}

@end
