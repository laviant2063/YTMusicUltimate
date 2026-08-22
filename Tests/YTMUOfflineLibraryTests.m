#import <Foundation/Foundation.h>
#import "YTMUOfflineLibrary.h"

static NSUInteger failures = 0;

#define ASSERT_TRUE(condition) do { \
    if (!(condition)) { \
        NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

#define ASSERT_EQUAL(expected, actual) do { \
    id expectedValue = (expected); \
    id actualValue = (actual); \
    if ((expectedValue != actualValue) && ![expectedValue isEqual:actualValue]) { \
        NSLog(@"FAIL %s:%d: expected %@, got %@", __FILE__, __LINE__, expectedValue, actualValue); \
        failures++; \
    } \
} while (0)

static NSURL *CreateTemporaryDocumentsURL(void) {
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMUOfflineTests-%@", NSUUID.UUID.UUIDString]
                     isDirectory:YES];
    NSError *error = nil;
    ASSERT_TRUE([[NSFileManager defaultManager] createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:&error]);
    ASSERT_TRUE(error == nil);
    return url;
}

static void WriteEmptyFile(NSURL *url) {
    NSError *error = nil;
    ASSERT_TRUE([[NSFileManager defaultManager] createDirectoryAtURL:[url URLByDeletingLastPathComponent]
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&error]);
    ASSERT_TRUE([[NSData data] writeToURL:url options:NSDataWritingAtomic error:&error]);
    ASSERT_TRUE(error == nil);
}

static NSDictionary<NSString *, NSString *> *TrackIDsByFileName(YTMUOfflineLibrary *library) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (YTMUOfflineTrack *track in library.tracks) {
        result[track.fileName] = track.trackID;
    }
    return result;
}

static void testMigrationAndStableIDs(void) {
    NSURL *documentsURL = CreateTemporaryDocumentsURL();
    NSURL *downloadsURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate" isDirectory:YES];
    WriteEmptyFile([downloadsURL URLByAppendingPathComponent:@"Artist A - Song A.m4a"]);
    WriteEmptyFile([downloadsURL URLByAppendingPathComponent:@"Song B.mp3"]);
    WriteEmptyFile([downloadsURL URLByAppendingPathComponent:@"Artist A - Song A.png"]);

    NSError *error = nil;
    YTMUOfflineLibrary *first = [[YTMUOfflineLibrary alloc] initWithDocumentsURL:documentsURL];
    ASSERT_TRUE([first reload:&error]);
    ASSERT_TRUE(error == nil);
    ASSERT_EQUAL(@2, @(first.tracks.count));
    NSDictionary *firstIDs = TrackIDsByFileName(first);
    ASSERT_TRUE([firstIDs[@"Artist A - Song A.m4a"] length] > 0);
    ASSERT_EQUAL(@"Artist A", [first trackForID:firstIDs[@"Artist A - Song A.m4a"]].artist);
    ASSERT_EQUAL(@"Song A", [first trackForID:firstIDs[@"Artist A - Song A.m4a"]].title);

    YTMUOfflineLibrary *second = [[YTMUOfflineLibrary alloc] initWithDocumentsURL:documentsURL];
    ASSERT_TRUE([second reload:&error]);
    ASSERT_EQUAL(firstIDs, TrackIDsByFileName(second));

    [[NSFileManager defaultManager] removeItemAtURL:documentsURL error:nil];
}

static void testPlaylistPersistenceRenameAndDeletion(void) {
    NSURL *documentsURL = CreateTemporaryDocumentsURL();
    NSURL *downloadsURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate" isDirectory:YES];
    WriteEmptyFile([downloadsURL URLByAppendingPathComponent:@"Artist - First.m4a"]);
    WriteEmptyFile([downloadsURL URLByAppendingPathComponent:@"Artist - Second.m4a"]);
    WriteEmptyFile([downloadsURL URLByAppendingPathComponent:@"Artist - First.png"]);

    NSError *error = nil;
    YTMUOfflineLibrary *library = [[YTMUOfflineLibrary alloc] initWithDocumentsURL:documentsURL];
    ASSERT_TRUE([library reload:&error]);
    NSString *firstID = TrackIDsByFileName(library)[@"Artist - First.m4a"];
    NSString *secondID = TrackIDsByFileName(library)[@"Artist - Second.m4a"];
    YTMUOfflinePlaylist *playlist = [library createPlaylistWithName:@"Road Trip" error:&error];
    ASSERT_TRUE(playlist != nil);
    ASSERT_TRUE(([library setTrackIDs:@[secondID, firstID] forPlaylistID:playlist.playlistID error:&error]));

    YTMUOfflineLibrary *reloaded = [[YTMUOfflineLibrary alloc] initWithDocumentsURL:documentsURL];
    ASSERT_TRUE([reloaded reload:&error]);
    ASSERT_EQUAL((@[secondID, firstID]), [reloaded playlistForID:playlist.playlistID].trackIDs);

    ASSERT_TRUE([reloaded renameTrackID:firstID toBaseName:@"Renamed Artist - Renamed Song" error:&error]);
    YTMUOfflineTrack *renamed = [reloaded trackForID:firstID];
    ASSERT_EQUAL(@"Renamed Artist - Renamed Song.m4a", renamed.fileName);
    ASSERT_EQUAL(@"Renamed Artist - Renamed Song.png", renamed.artworkFileName);
    ASSERT_TRUE([[NSFileManager defaultManager] fileExistsAtPath:[[downloadsURL URLByAppendingPathComponent:renamed.fileName] path]]);
    ASSERT_TRUE([[reloaded playlistForID:playlist.playlistID].trackIDs containsObject:firstID]);

    ASSERT_TRUE([reloaded deleteTrackID:firstID error:&error]);
    ASSERT_TRUE([reloaded trackForID:firstID] == nil);
    ASSERT_TRUE(![[reloaded playlistForID:playlist.playlistID].trackIDs containsObject:firstID]);

    [[NSFileManager defaultManager] removeItemAtURL:documentsURL error:nil];
}

static void testRegistrationAndCorruptMetadataRecovery(void) {
    NSURL *documentsURL = CreateTemporaryDocumentsURL();
    NSURL *downloadsURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate" isDirectory:YES];
    WriteEmptyFile([downloadsURL URLByAppendingPathComponent:@"New Artist - New Song.m4a"]);

    NSError *error = nil;
    YTMUOfflineLibrary *library = [[YTMUOfflineLibrary alloc] initWithDocumentsURL:documentsURL];
    ASSERT_TRUE([library reload:&error]);
    YTMUOfflineTrack *track = [library registerDownloadedFileName:@"New Artist - New Song.m4a"
                                                preferredTrackID:@"youtube:abc123"
                                                            title:@"New Song"
                                                           artist:@"New Artist"
                                                  artworkFileName:nil
                                                            error:&error];
    ASSERT_TRUE(track != nil);
    NSString *stableID = track.trackID;
    ASSERT_TRUE([stableID length] > 0);

    ASSERT_TRUE([@"broken json" writeToURL:library.metadataURL atomically:YES encoding:NSUTF8StringEncoding error:&error]);
    YTMUOfflineLibrary *recovered = [[YTMUOfflineLibrary alloc] initWithDocumentsURL:documentsURL];
    ASSERT_TRUE([recovered reload:&error]);
    ASSERT_TRUE(recovered.lastRecoveryError != nil);
    ASSERT_EQUAL(@1, @(recovered.tracks.count));

    NSArray *documentFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:documentsURL.path error:&error];
    NSPredicate *backupPredicate = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'YTMusicUltimateLibrary.corrupt-'"];
    ASSERT_EQUAL(@1, @([[documentFiles filteredArrayUsingPredicate:backupPredicate] count]));

    [[NSFileManager defaultManager] removeItemAtURL:documentsURL error:nil];
}

int main(void) {
    @autoreleasepool {
        testMigrationAndStableIDs();
        testPlaylistPersistenceRenameAndDeletion();
        testRegistrationAndCorruptMetadataRecovery();

        if (failures != 0) {
            NSLog(@"%lu offline library test(s) failed", (unsigned long)failures);
            return EXIT_FAILURE;
        }

        NSLog(@"Offline library tests passed");
    }
    return EXIT_SUCCESS;
}
