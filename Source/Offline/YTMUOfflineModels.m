#import "YTMUOfflineModels.h"

static NSString *YTMUOfflineStringValue(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] ? value : fallback;
}

@implementation YTMUOfflineTrack

- (instancetype)init {
    self = [super init];
    if (self) {
        _trackID = NSUUID.UUID.UUIDString;
        _fileName = @"";
        _title = @"";
        _artist = @"";
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [self init];
    if (self) {
        _trackID = [YTMUOfflineStringValue(dictionary[@"id"], _trackID) copy];
        _fileName = [YTMUOfflineStringValue(dictionary[@"fileName"], @"") copy];
        _title = [YTMUOfflineStringValue(dictionary[@"title"], @"") copy];
        _artist = [YTMUOfflineStringValue(dictionary[@"artist"], @"") copy];
        NSString *artwork = YTMUOfflineStringValue(dictionary[@"artworkFileName"], @"");
        _artworkFileName = artwork.length > 0 ? [artwork copy] : nil;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [@{
        @"id": self.trackID ?: @"",
        @"fileName": self.fileName ?: @"",
        @"title": self.title ?: @"",
        @"artist": self.artist ?: @"",
    } mutableCopy];
    if (self.artworkFileName.length > 0) {
        dictionary[@"artworkFileName"] = self.artworkFileName;
    }
    return dictionary;
}

- (id)copyWithZone:(NSZone *)zone {
    YTMUOfflineTrack *copy = [[[self class] allocWithZone:zone] init];
    copy.trackID = self.trackID;
    copy.fileName = self.fileName;
    copy.title = self.title;
    copy.artist = self.artist;
    copy.artworkFileName = self.artworkFileName;
    return copy;
}

@end

@implementation YTMUOfflinePlaylist

- (instancetype)init {
    self = [super init];
    if (self) {
        _playlistID = NSUUID.UUID.UUIDString;
        _name = @"";
        _trackIDs = @[];
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [self init];
    if (self) {
        _playlistID = [YTMUOfflineStringValue(dictionary[@"id"], _playlistID) copy];
        _name = [YTMUOfflineStringValue(dictionary[@"name"], @"") copy];
        NSArray *values = [dictionary[@"trackIDs"] isKindOfClass:NSArray.class] ? dictionary[@"trackIDs"] : @[];
        NSMutableArray *trackIDs = [NSMutableArray array];
        for (id value in values) {
            if ([value isKindOfClass:NSString.class] && [value length] > 0) {
                [trackIDs addObject:value];
            }
        }
        _trackIDs = [trackIDs copy];
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"id": self.playlistID ?: @"",
        @"name": self.name ?: @"",
        @"trackIDs": self.trackIDs ?: @[],
    };
}

- (id)copyWithZone:(NSZone *)zone {
    YTMUOfflinePlaylist *copy = [[[self class] allocWithZone:zone] init];
    copy.playlistID = self.playlistID;
    copy.name = self.name;
    copy.trackIDs = self.trackIDs;
    return copy;
}

@end
