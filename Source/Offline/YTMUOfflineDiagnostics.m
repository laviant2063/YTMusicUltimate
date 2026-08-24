#import "YTMUOfflineDiagnostics.h"

static NSString *YTMUOfflineSafeLogValue(NSString *value) {
    if (value.length == 0) return @"-";
    NSMutableArray<NSString *> *safeParts = [NSMutableArray array];
    NSArray<NSString *> *parts = [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *part in parts) {
        if (part.length == 0) continue;
        [safeParts addObject:[part containsString:@"/"] ? @"<redacted-path>" : part];
    }
    NSString *safe = [safeParts componentsJoinedByString:@" "];
    return safe.length > 240 ? [[safe substringToIndex:240] stringByAppendingString:@"…"] : safe;
}

static NSString *YTMUOfflineSafeTrackID(NSString *trackID) {
    if (trackID.length == 0) return @"-";
    return trackID.length > 80 ? [[trackID substringToIndex:80] stringByAppendingString:@"…"] : trackID;
}

void YTMUOfflineDiagnosticsLog(NSString *stage, NSString *trackID, NSString *detail) {
    NSLog(@"[YTMusicUltimate][Offline] stage=%@ trackID=%@ detail=%@",
          YTMUOfflineSafeLogValue(stage),
          YTMUOfflineSafeTrackID(trackID),
          YTMUOfflineSafeLogValue(detail));
}

void YTMUOfflineDiagnosticsLogTrack(NSString *stage, NSString *trackID, BOOL fileExists) {
    YTMUOfflineDiagnosticsLog(stage, trackID, fileExists ? @"file=present" : @"file=missing");
}

void YTMUOfflineDiagnosticsLogException(NSString *stage, NSString *trackID, NSException *exception) {
    NSString *detail = exception == nil
        ? @"exception=unknown"
        : [NSString stringWithFormat:@"exception=%@ reason=%@", exception.name ?: @"unknown",
                                           exception.reason ?: @"unknown"];
    YTMUOfflineDiagnosticsLog(stage, trackID, detail);
}
