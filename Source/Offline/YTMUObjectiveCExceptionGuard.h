#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL YTMUPerformObjectiveCBlockSafely(
    void (^ _Nullable block)(void),
    NSException * _Nullable __autoreleasing * _Nullable caughtException);

NS_ASSUME_NONNULL_END
