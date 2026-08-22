#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTMUOfflineTrack : NSObject <NSCopying>

@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy, nullable) NSString *artworkFileName;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;

@end

@interface YTMUOfflinePlaylist : NSObject <NSCopying>

@property (nonatomic, copy) NSString *playlistID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray<NSString *> *trackIDs;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;

@end

NS_ASSUME_NONNULL_END
