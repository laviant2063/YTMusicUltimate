#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void YTMUOfflineDiagnosticsLog(NSString *stage,
                                                  NSString * _Nullable trackID,
                                                  NSString *detail);
FOUNDATION_EXPORT void YTMUOfflineDiagnosticsLogTrack(NSString *stage,
                                                       NSString * _Nullable trackID,
                                                       BOOL fileExists);
FOUNDATION_EXPORT void YTMUOfflineDiagnosticsLogException(NSString *stage,
                                                           NSString * _Nullable trackID,
                                                           NSException * _Nullable exception);

NS_ASSUME_NONNULL_END
