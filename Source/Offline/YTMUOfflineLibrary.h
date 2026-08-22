#import <Foundation/Foundation.h>
#import "YTMUOfflineModels.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const YTMUOfflineLibraryDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const YTMUOfflineLibraryErrorNotification;

@interface YTMUOfflineLibrary : NSObject

@property (class, nonatomic, readonly) YTMUOfflineLibrary *sharedLibrary;
@property (nonatomic, copy, readonly) NSArray<YTMUOfflineTrack *> *tracks;
@property (nonatomic, copy, readonly) NSArray<YTMUOfflinePlaylist *> *playlists;
@property (nonatomic, strong, readonly) NSURL *downloadsDirectoryURL;
@property (nonatomic, strong, readonly) NSURL *metadataURL;
@property (nonatomic, strong, readonly, nullable) NSError *lastRecoveryError;

- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)reload:(NSError **)error;
- (nullable YTMUOfflineTrack *)trackForID:(NSString *)trackID;
- (nullable YTMUOfflinePlaylist *)playlistForID:(NSString *)playlistID;
- (NSArray<YTMUOfflineTrack *> *)tracksForPlaylistID:(NSString *)playlistID;

- (nullable YTMUOfflineTrack *)registerDownloadedFileName:(NSString *)fileName
                                         preferredTrackID:(nullable NSString *)preferredTrackID
                                                     title:(nullable NSString *)title
                                                    artist:(nullable NSString *)artist
                                           artworkFileName:(nullable NSString *)artworkFileName
                                                     error:(NSError **)error;
- (BOOL)renameTrackID:(NSString *)trackID toBaseName:(NSString *)baseName error:(NSError **)error;
- (BOOL)deleteTrackID:(NSString *)trackID error:(NSError **)error;
- (BOOL)removeAllDownloads:(NSError **)error;

- (nullable YTMUOfflinePlaylist *)createPlaylistWithName:(NSString *)name error:(NSError **)error;
- (BOOL)renamePlaylistID:(NSString *)playlistID name:(NSString *)name error:(NSError **)error;
- (BOOL)deletePlaylistID:(NSString *)playlistID error:(NSError **)error;
- (BOOL)addTrackID:(NSString *)trackID toPlaylistID:(NSString *)playlistID error:(NSError **)error;
- (BOOL)removeTrackID:(NSString *)trackID fromPlaylistID:(NSString *)playlistID error:(NSError **)error;
- (BOOL)setTrackIDs:(NSArray<NSString *> *)trackIDs forPlaylistID:(NSString *)playlistID error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
