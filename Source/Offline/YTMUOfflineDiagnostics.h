#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void YTMUOfflineDiagnosticsLog(NSString *stage,
                                                  nullable NSString *trackID,
                                                  NSString *detail);
FOUNDATION_EXPORT void YTMUOfflineDiagnosticsLogTrack(NSString *stage,
                                                       nullable NSString *trackID,
                                                       BOOL fileExists);
FOUNDATION_EXPORT void YTMUOfflineDiagnosticsLogException(NSString *stage,
                                                           nullable NSString *trackID,
                                                           nullable NSException *exception);

NS_ASSUME_NONNULL_END
