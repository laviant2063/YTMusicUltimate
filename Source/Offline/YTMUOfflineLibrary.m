#import "YTMUOfflineLibrary.h"

NSNotificationName const YTMUOfflineLibraryDidChangeNotification = @"YTMUOfflineLibraryDidChangeNotification";
NSNotificationName const YTMUOfflineLibraryErrorNotification = @"YTMUOfflineLibraryErrorNotification";

static NSString * const YTMUOfflineLibraryErrorDomain = @"com.ginsu.ytmusicultimate.offline-library";
static NSInteger const YTMUOfflineLibrarySchemaVersion = 1;

typedef NS_ENUM(NSInteger, YTMUOfflineLibraryErrorCode) {
    YTMUOfflineLibraryErrorInvalidMetadata = 1,
    YTMUOfflineLibraryErrorInvalidName,
    YTMUOfflineLibraryErrorNotFound,
    YTMUOfflineLibraryErrorAlreadyExists,
    YTMUOfflineLibraryErrorInvalidAudioFile,
};

@interface YTMUOfflineLibrary ()
@property (nonatomic, strong) NSURL *documentsURL;
@property (nonatomic, strong, readwrite) NSURL *downloadsDirectoryURL;
@property (nonatomic, strong, readwrite) NSURL *metadataURL;
@property (nonatomic, strong, readwrite, nullable) NSError *lastRecoveryError;
@property (nonatomic, strong) NSMutableArray<YTMUOfflineTrack *> *mutableTracks;
@property (nonatomic, strong) NSMutableArray<YTMUOfflinePlaylist *> *mutablePlaylists;
@end

@implementation YTMUOfflineLibrary

+ (YTMUOfflineLibrary *)sharedLibrary {
    static YTMUOfflineLibrary *library = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                      inDomains:NSUserDomainMask] lastObject];
        library = [[YTMUOfflineLibrary alloc] initWithDocumentsURL:documentsURL];
        [library reload:nil];
    });
    return library;
}

- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    self = [super init];
    if (self) {
        _documentsURL = documentsURL;
        _downloadsDirectoryURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate" isDirectory:YES];
        _metadataURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimateLibrary.json" isDirectory:NO];
        _mutableTracks = [NSMutableArray array];
        _mutablePlaylists = [NSMutableArray array];
    }
    return self;
}

- (NSArray<YTMUOfflineTrack *> *)tracks {
    @synchronized (self) {
        return [self.mutableTracks copy];
    }
}

- (NSArray<YTMUOfflinePlaylist *> *)playlists {
    @synchronized (self) {
        return [self.mutablePlaylists copy];
    }
}

- (NSError *)errorWithCode:(YTMUOfflineLibraryErrorCode)code description:(NSString *)description {
    return [NSError errorWithDomain:YTMUOfflineLibraryErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Offline library error"}];
}

- (void)assignError:(NSError *)value toPointer:(NSError **)error {
    if (error != NULL) {
        *error = value;
    }
}

- (void)postChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflineLibraryDidChangeNotification object:self];
}

- (void)postError:(NSError *)error {
    if (error == nil) {
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUOfflineLibraryErrorNotification
                                                        object:self
                                                      userInfo:@{@"error": error, @"message": error.localizedDescription ?: @"Offline library error"}];
}

- (BOOL)isAudioFileName:(NSString *)fileName {
    NSString *extension = fileName.pathExtension.lowercaseString;
    return [extension isEqualToString:@"m4a"] || [extension isEqualToString:@"mp3"];
}

- (NSArray<NSString *> *)titleAndArtistForFileName:(NSString *)fileName {
    NSString *baseName = fileName.stringByDeletingPathExtension;
    NSRange separator = [baseName rangeOfString:@" - "];
    if (separator.location == NSNotFound) {
        return @[baseName, @""];
    }
    NSString *artist = [[baseName substringToIndex:separator.location]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *title = [[baseName substringFromIndex:NSMaxRange(separator)]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return @[title.length > 0 ? title : baseName, artist];
}

- (nullable YTMUOfflineTrack *)trackForID:(NSString *)trackID {
    @synchronized (self) {
        for (YTMUOfflineTrack *track in self.mutableTracks) {
            if ([track.trackID isEqualToString:trackID]) {
                return track;
            }
        }
    }
    return nil;
}

- (nullable YTMUOfflinePlaylist *)playlistForID:(NSString *)playlistID {
    @synchronized (self) {
        for (YTMUOfflinePlaylist *playlist in self.mutablePlaylists) {
            if ([playlist.playlistID isEqualToString:playlistID]) {
                return playlist;
            }
        }
    }
    return nil;
}

- (NSArray<YTMUOfflineTrack *> *)tracksForPlaylistID:(NSString *)playlistID {
    YTMUOfflinePlaylist *playlist = [self playlistForID:playlistID];
    if (playlist == nil) {
        return @[];
    }
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:playlist.trackIDs.count];
    for (NSString *trackID in playlist.trackIDs) {
        YTMUOfflineTrack *track = [self trackForID:trackID];
        if (track != nil) {
            [tracks addObject:track];
        }
    }
    return tracks;
}

- (BOOL)loadMetadata:(NSError **)error {
    [self.mutableTracks removeAllObjects];
    [self.mutablePlaylists removeAllObjects];
    self.lastRecoveryError = nil;

    if (![[NSFileManager defaultManager] fileExistsAtPath:self.metadataURL.path]) {
        return YES;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:self.metadataURL options:0 error:&readError];
    id root = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&readError] : nil;
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"tracks"] isKindOfClass:NSArray.class]
        || ![root[@"playlists"] isKindOfClass:NSArray.class]) {
        NSError *metadataError = readError ?: [self errorWithCode:YTMUOfflineLibraryErrorInvalidMetadata
                                                       description:@"Offline playlist data was damaged and has been recovered."];
        self.lastRecoveryError = metadataError;

        NSString *backupName = [NSString stringWithFormat:@"YTMusicUltimateLibrary.corrupt-%@.json", NSUUID.UUID.UUIDString];
        NSURL *backupURL = [self.documentsURL URLByAppendingPathComponent:backupName];
        NSError *backupError = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:self.metadataURL toURL:backupURL error:&backupError]) {
            [self assignError:backupError toPointer:error];
            return NO;
        }
        return YES;
    }

    NSMutableSet<NSString *> *trackIDs = [NSMutableSet set];
    for (id value in root[@"tracks"]) {
        if (![value isKindOfClass:NSDictionary.class]) {
            continue;
        }
        YTMUOfflineTrack *track = [[YTMUOfflineTrack alloc] initWithDictionary:value];
        if (track.fileName.length == 0 || ![self isAudioFileName:track.fileName]) {
            continue;
        }
        if (track.trackID.length == 0 || [trackIDs containsObject:track.trackID]) {
            track.trackID = NSUUID.UUID.UUIDString;
        }
        [trackIDs addObject:track.trackID];
        [self.mutableTracks addObject:track];
    }

    NSMutableSet<NSString *> *playlistIDs = [NSMutableSet set];
    for (id value in root[@"playlists"]) {
        if (![value isKindOfClass:NSDictionary.class]) {
            continue;
        }
        YTMUOfflinePlaylist *playlist = [[YTMUOfflinePlaylist alloc] initWithDictionary:value];
        if (playlist.name.length == 0) {
            continue;
        }
        if (playlist.playlistID.length == 0 || [playlistIDs containsObject:playlist.playlistID]) {
            playlist.playlistID = NSUUID.UUID.UUIDString;
        }
        [playlistIDs addObject:playlist.playlistID];
        [self.mutablePlaylists addObject:playlist];
    }
    return YES;
}

- (BOOL)reconcileFiles:(BOOL *)changed error:(NSError **)error {
    NSError *directoryError = nil;
    NSArray<NSString *> *allFileNames = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:self.downloadsDirectoryURL.path error:&directoryError];
    if (allFileNames == nil) {
        [self assignError:directoryError toPointer:error];
        return NO;
    }

    NSMutableArray<NSString *> *audioFileNames = [NSMutableArray array];
    for (NSString *fileName in allFileNames) {
        if ([self isAudioFileName:fileName]) {
            [audioFileNames addObject:fileName];
        }
    }
    [audioFileNames sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSMutableDictionary<NSString *, YTMUOfflineTrack *> *tracksByLowercaseFileName = [NSMutableDictionary dictionary];
    for (YTMUOfflineTrack *track in self.mutableTracks) {
        if (track.fileName.length > 0) {
            tracksByLowercaseFileName[track.fileName.lowercaseString] = track;
        }
    }

    NSMutableArray<YTMUOfflineTrack *> *reconciled = [NSMutableArray arrayWithCapacity:audioFileNames.count];
    NSMutableSet<NSString *> *validTrackIDs = [NSMutableSet set];
    for (NSString *fileName in audioFileNames) {
        YTMUOfflineTrack *track = tracksByLowercaseFileName[fileName.lowercaseString];
        if (track == nil || [validTrackIDs containsObject:track.trackID]) {
            track = [[YTMUOfflineTrack alloc] init];
            track.fileName = fileName;
            NSArray<NSString *> *parts = [self titleAndArtistForFileName:fileName];
            track.title = parts[0];
            track.artist = parts[1];
            *changed = YES;
        } else if (![track.fileName isEqualToString:fileName]) {
            track.fileName = fileName;
            *changed = YES;
        }

        NSArray<NSString *> *parts = [self titleAndArtistForFileName:fileName];
        if (track.title.length == 0) {
            track.title = parts[0];
            *changed = YES;
        }
        if (track.artist.length == 0 && [parts[1] length] > 0) {
            track.artist = parts[1];
            *changed = YES;
        }

        NSString *expectedArtwork = [fileName.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"];
        BOOL artworkExists = [[NSFileManager defaultManager]
            fileExistsAtPath:[self.downloadsDirectoryURL URLByAppendingPathComponent:expectedArtwork].path];
        NSString *newArtwork = artworkExists ? expectedArtwork : nil;
        if ((track.artworkFileName != newArtwork) && ![track.artworkFileName isEqualToString:newArtwork]) {
            track.artworkFileName = newArtwork;
            *changed = YES;
        }

        [validTrackIDs addObject:track.trackID];
        [reconciled addObject:track];
    }

    if (reconciled.count != self.mutableTracks.count) {
        *changed = YES;
    }
    self.mutableTracks = reconciled;

    for (YTMUOfflinePlaylist *playlist in self.mutablePlaylists) {
        NSMutableArray<NSString *> *filtered = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *trackID in playlist.trackIDs) {
            if ([validTrackIDs containsObject:trackID] && ![seen containsObject:trackID]) {
                [seen addObject:trackID];
                [filtered addObject:trackID];
            }
        }
        if (![filtered isEqualToArray:playlist.trackIDs]) {
            playlist.trackIDs = filtered;
            *changed = YES;
        }
    }
    return YES;
}

- (BOOL)save:(NSError **)error {
    NSMutableArray *trackValues = [NSMutableArray arrayWithCapacity:self.mutableTracks.count];
    for (YTMUOfflineTrack *track in self.mutableTracks) {
        [trackValues addObject:track.dictionaryRepresentation];
    }
    NSMutableArray *playlistValues = [NSMutableArray arrayWithCapacity:self.mutablePlaylists.count];
    for (YTMUOfflinePlaylist *playlist in self.mutablePlaylists) {
        [playlistValues addObject:playlist.dictionaryRepresentation];
    }

    NSDictionary *root = @{
        @"schemaVersion": @(YTMUOfflineLibrarySchemaVersion),
        @"tracks": trackValues,
        @"playlists": playlistValues,
    };
    NSError *serializationError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&serializationError];
    if (data == nil || ![data writeToURL:self.metadataURL options:NSDataWritingAtomic error:&serializationError]) {
        [self assignError:serializationError toPointer:error];
        return NO;
    }
    return YES;
}

- (BOOL)reload:(NSError **)error {
    @synchronized (self) {
        NSError *directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:self.downloadsDirectoryURL
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&directoryError]) {
            [self assignError:directoryError toPointer:error];
            [self postError:directoryError];
            return NO;
        }

        BOOL metadataExisted = [[NSFileManager defaultManager] fileExistsAtPath:self.metadataURL.path];
        if (![self loadMetadata:error]) {
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        BOOL changed = !metadataExisted || self.lastRecoveryError != nil;
        if (![self reconcileFiles:&changed error:error]) {
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        if (changed && ![self save:error]) {
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        [self postChange];
        if (self.lastRecoveryError != nil) {
            [self postError:self.lastRecoveryError];
        }
        return YES;
    }
}

- (nullable YTMUOfflineTrack *)registerDownloadedFileName:(NSString *)fileName
                                         preferredTrackID:(nullable NSString *)preferredTrackID
                                                     title:(nullable NSString *)title
                                                    artist:(nullable NSString *)artist
                                           artworkFileName:(nullable NSString *)artworkFileName
                                                     error:(NSError **)error {
    @synchronized (self) {
        NSURL *fileURL = [self.downloadsDirectoryURL URLByAppendingPathComponent:fileName];
        if (![self isAudioFileName:fileName] || ![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorInvalidAudioFile
                                      description:@"The downloaded audio file could not be registered."];
            [self assignError:value toPointer:error];
            [self postError:value];
            return nil;
        }

        YTMUOfflineTrack *track = nil;
        for (YTMUOfflineTrack *candidate in self.mutableTracks) {
            if ([candidate.fileName caseInsensitiveCompare:fileName] == NSOrderedSame) {
                track = candidate;
                break;
            }
        }
        if (track == nil && preferredTrackID.length > 0) {
            track = [self trackForID:preferredTrackID];
        }
        if (track == nil) {
            track = [[YTMUOfflineTrack alloc] init];
            if (preferredTrackID.length > 0 && [self trackForID:preferredTrackID] == nil) {
                track.trackID = preferredTrackID;
            }
            [self.mutableTracks addObject:track];
        }

        NSArray<NSString *> *parts = [self titleAndArtistForFileName:fileName];
        track.fileName = fileName;
        track.title = title.length > 0 ? title : parts[0];
        track.artist = artist.length > 0 ? artist : parts[1];
        if (artworkFileName.length > 0) {
            track.artworkFileName = artworkFileName;
        } else {
            NSString *expectedArtwork = [fileName.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"];
            if ([[NSFileManager defaultManager]
                    fileExistsAtPath:[self.downloadsDirectoryURL URLByAppendingPathComponent:expectedArtwork].path]) {
                track.artworkFileName = expectedArtwork;
            }
        }

        if (![self save:error]) {
            [self postError:error != NULL ? *error : nil];
            return nil;
        }
        [self postChange];
        return track;
    }
}

- (NSString *)validatedBaseName:(NSString *)baseName error:(NSError **)error {
    NSString *trimmed = [baseName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    trimmed = [[trimmed stringByReplacingOccurrencesOfString:@"/" withString:@""]
        stringByReplacingOccurrencesOfString:@":" withString:@""];
    if (trimmed.length == 0) {
        NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorInvalidName description:@"Enter a valid name."];
        [self assignError:value toPointer:error];
        return @"";
    }
    return trimmed;
}

- (BOOL)renameTrackID:(NSString *)trackID toBaseName:(NSString *)baseName error:(NSError **)error {
    @synchronized (self) {
        YTMUOfflineTrack *track = [self trackForID:trackID];
        if (track == nil) {
            NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorNotFound description:@"The downloaded song no longer exists."];
            [self assignError:value toPointer:error];
            return NO;
        }
        NSString *validatedName = [self validatedBaseName:baseName error:error];
        if (validatedName.length == 0) {
            return NO;
        }

        NSString *newFileName = [validatedName stringByAppendingPathExtension:track.fileName.pathExtension];
        NSString *newArtworkFileName = [validatedName stringByAppendingPathExtension:@"png"];
        NSURL *oldAudioURL = [self.downloadsDirectoryURL URLByAppendingPathComponent:track.fileName];
        NSURL *newAudioURL = [self.downloadsDirectoryURL URLByAppendingPathComponent:newFileName];
        NSURL *oldArtworkURL = track.artworkFileName.length > 0
            ? [self.downloadsDirectoryURL URLByAppendingPathComponent:track.artworkFileName] : nil;
        NSURL *newArtworkURL = [self.downloadsDirectoryURL URLByAppendingPathComponent:newArtworkFileName];

        if (![oldAudioURL isEqual:newAudioURL] && [[NSFileManager defaultManager] fileExistsAtPath:newAudioURL.path]) {
            NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorAlreadyExists
                                      description:@"A downloaded song with that name already exists."];
            [self assignError:value toPointer:error];
            return NO;
        }

        NSError *moveError = nil;
        BOOL movedAudio = [oldAudioURL isEqual:newAudioURL]
            || [[NSFileManager defaultManager] moveItemAtURL:oldAudioURL toURL:newAudioURL error:&moveError];
        if (!movedAudio) {
            [self assignError:moveError toPointer:error];
            return NO;
        }

        BOOL hadArtwork = oldArtworkURL != nil && [[NSFileManager defaultManager] fileExistsAtPath:oldArtworkURL.path];
        BOOL movedArtwork = !hadArtwork || [oldArtworkURL isEqual:newArtworkURL]
            || [[NSFileManager defaultManager] moveItemAtURL:oldArtworkURL toURL:newArtworkURL error:&moveError];
        if (!movedArtwork) {
            if (![oldAudioURL isEqual:newAudioURL]) {
                [[NSFileManager defaultManager] moveItemAtURL:newAudioURL toURL:oldAudioURL error:nil];
            }
            [self assignError:moveError toPointer:error];
            return NO;
        }

        NSString *oldFileName = track.fileName;
        NSString *oldArtworkFileName = track.artworkFileName;
        NSString *oldTitle = track.title;
        NSString *oldArtist = track.artist;
        NSArray<NSString *> *parts = [self titleAndArtistForFileName:newFileName];
        track.fileName = newFileName;
        track.artworkFileName = hadArtwork ? newArtworkFileName : nil;
        track.title = parts[0];
        track.artist = parts[1];

        if (![self save:error]) {
            track.fileName = oldFileName;
            track.artworkFileName = oldArtworkFileName;
            track.title = oldTitle;
            track.artist = oldArtist;
            if (![oldAudioURL isEqual:newAudioURL]) {
                [[NSFileManager defaultManager] moveItemAtURL:newAudioURL toURL:oldAudioURL error:nil];
            }
            if (hadArtwork && ![oldArtworkURL isEqual:newArtworkURL]) {
                [[NSFileManager defaultManager] moveItemAtURL:newArtworkURL toURL:oldArtworkURL error:nil];
            }
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        [self postChange];
        return YES;
    }
}

- (BOOL)deleteTrackID:(NSString *)trackID error:(NSError **)error {
    @synchronized (self) {
        YTMUOfflineTrack *track = [self trackForID:trackID];
        if (track == nil) {
            return YES;
        }
        NSError *fileError = nil;
        NSURL *audioURL = [self.downloadsDirectoryURL URLByAppendingPathComponent:track.fileName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:audioURL.path]) {
            [[NSFileManager defaultManager] removeItemAtURL:audioURL error:&fileError];
        }
        if (track.artworkFileName.length > 0) {
            NSURL *artworkURL = [self.downloadsDirectoryURL URLByAppendingPathComponent:track.artworkFileName];
            if ([[NSFileManager defaultManager] fileExistsAtPath:artworkURL.path]) {
                NSError *artworkError = nil;
                if (![[NSFileManager defaultManager] removeItemAtURL:artworkURL error:&artworkError] && fileError == nil) {
                    fileError = artworkError;
                }
            }
        }

        [self.mutableTracks removeObject:track];
        for (YTMUOfflinePlaylist *playlist in self.mutablePlaylists) {
            NSMutableArray *trackIDs = [playlist.trackIDs mutableCopy];
            [trackIDs removeObject:trackID];
            playlist.trackIDs = trackIDs;
        }
        NSError *saveError = nil;
        BOOL saved = [self save:&saveError];
        [self postChange];
        NSError *resultError = fileError ?: saveError;
        if (resultError != nil) {
            [self assignError:resultError toPointer:error];
            [self postError:resultError];
        }
        return saved && fileError == nil;
    }
}

- (BOOL)removeAllDownloads:(NSError **)error {
    @synchronized (self) {
        NSError *removeError = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:self.downloadsDirectoryURL.path]) {
            [[NSFileManager defaultManager] removeItemAtURL:self.downloadsDirectoryURL error:&removeError];
        }
        if (removeError == nil) {
            [[NSFileManager defaultManager] createDirectoryAtURL:self.downloadsDirectoryURL
                                      withIntermediateDirectories:YES attributes:nil error:&removeError];
        }
        if (removeError != nil) {
            [self assignError:removeError toPointer:error];
            [self postError:removeError];
            return NO;
        }

        [self.mutableTracks removeAllObjects];
        for (YTMUOfflinePlaylist *playlist in self.mutablePlaylists) {
            playlist.trackIDs = @[];
        }
        if (![self save:error]) {
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        [self postChange];
        return YES;
    }
}

- (NSString *)validatedPlaylistName:(NSString *)name excludingID:(nullable NSString *)playlistID error:(NSError **)error {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorInvalidName description:@"Enter a playlist name."];
        [self assignError:value toPointer:error];
        return @"";
    }
    for (YTMUOfflinePlaylist *playlist in self.mutablePlaylists) {
        if (![playlist.playlistID isEqualToString:playlistID]
            && [playlist.name caseInsensitiveCompare:trimmed] == NSOrderedSame) {
            NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorAlreadyExists
                                      description:@"A playlist with that name already exists."];
            [self assignError:value toPointer:error];
            return @"";
        }
    }
    return trimmed;
}

- (nullable YTMUOfflinePlaylist *)createPlaylistWithName:(NSString *)name error:(NSError **)error {
    @synchronized (self) {
        NSString *validatedName = [self validatedPlaylistName:name excludingID:nil error:error];
        if (validatedName.length == 0) {
            return nil;
        }
        YTMUOfflinePlaylist *playlist = [[YTMUOfflinePlaylist alloc] init];
        playlist.name = validatedName;
        [self.mutablePlaylists addObject:playlist];
        if (![self save:error]) {
            [self.mutablePlaylists removeObject:playlist];
            [self postError:error != NULL ? *error : nil];
            return nil;
        }
        [self postChange];
        return playlist;
    }
}

- (BOOL)renamePlaylistID:(NSString *)playlistID name:(NSString *)name error:(NSError **)error {
    @synchronized (self) {
        YTMUOfflinePlaylist *playlist = [self playlistForID:playlistID];
        if (playlist == nil) {
            NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorNotFound description:@"The playlist no longer exists."];
            [self assignError:value toPointer:error];
            return NO;
        }
        NSString *validatedName = [self validatedPlaylistName:name excludingID:playlistID error:error];
        if (validatedName.length == 0) {
            return NO;
        }
        NSString *oldName = playlist.name;
        playlist.name = validatedName;
        if (![self save:error]) {
            playlist.name = oldName;
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        [self postChange];
        return YES;
    }
}

- (BOOL)deletePlaylistID:(NSString *)playlistID error:(NSError **)error {
    @synchronized (self) {
        YTMUOfflinePlaylist *playlist = [self playlistForID:playlistID];
        if (playlist == nil) {
            return YES;
        }
        NSUInteger index = [self.mutablePlaylists indexOfObject:playlist];
        [self.mutablePlaylists removeObjectAtIndex:index];
        if (![self save:error]) {
            [self.mutablePlaylists insertObject:playlist atIndex:index];
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        [self postChange];
        return YES;
    }
}

- (BOOL)setTrackIDs:(NSArray<NSString *> *)trackIDs forPlaylistID:(NSString *)playlistID error:(NSError **)error {
    @synchronized (self) {
        YTMUOfflinePlaylist *playlist = [self playlistForID:playlistID];
        if (playlist == nil) {
            NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorNotFound description:@"The playlist no longer exists."];
            [self assignError:value toPointer:error];
            return NO;
        }

        NSMutableArray *validated = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSString *trackID in trackIDs) {
            if (![trackID isKindOfClass:NSString.class] || [seen containsObject:trackID]) {
                continue;
            }
            if ([self trackForID:trackID] == nil) {
                NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorNotFound
                                          description:@"One of the downloaded songs no longer exists."];
                [self assignError:value toPointer:error];
                return NO;
            }
            [seen addObject:trackID];
            [validated addObject:trackID];
        }

        NSArray *oldTrackIDs = playlist.trackIDs;
        playlist.trackIDs = validated;
        if (![self save:error]) {
            playlist.trackIDs = oldTrackIDs;
            [self postError:error != NULL ? *error : nil];
            return NO;
        }
        [self postChange];
        return YES;
    }
}

- (BOOL)addTrackID:(NSString *)trackID toPlaylistID:(NSString *)playlistID error:(NSError **)error {
    YTMUOfflinePlaylist *playlist = [self playlistForID:playlistID];
    if (playlist == nil || [self trackForID:trackID] == nil) {
        NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorNotFound
                                  description:@"The playlist or downloaded song no longer exists."];
        [self assignError:value toPointer:error];
        return NO;
    }
    if ([playlist.trackIDs containsObject:trackID]) {
        return YES;
    }
    return [self setTrackIDs:[playlist.trackIDs arrayByAddingObject:trackID] forPlaylistID:playlistID error:error];
}

- (BOOL)removeTrackID:(NSString *)trackID fromPlaylistID:(NSString *)playlistID error:(NSError **)error {
    YTMUOfflinePlaylist *playlist = [self playlistForID:playlistID];
    if (playlist == nil) {
        NSError *value = [self errorWithCode:YTMUOfflineLibraryErrorNotFound description:@"The playlist no longer exists."];
        [self assignError:value toPointer:error];
        return NO;
    }
    NSMutableArray *trackIDs = [playlist.trackIDs mutableCopy];
    [trackIDs removeObject:trackID];
    return [self setTrackIDs:trackIDs forPlaylistID:playlistID error:error];
}

@end
