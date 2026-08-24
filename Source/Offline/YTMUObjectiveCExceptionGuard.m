#import "YTMUObjectiveCExceptionGuard.h"

BOOL YTMUPerformObjectiveCBlockSafely(
    void (^ _Nullable block)(void),
    NSException * _Nullable __autoreleasing * _Nullable caughtException) {
    if (caughtException != NULL) {
        *caughtException = nil;
    }
    if (block == nil) {
        return NO;
    }

    @try {
        block();
        return YES;
    } @catch (NSException *caughtExceptionValue) {
        if (caughtException != NULL) {
            *caughtException = caughtExceptionValue;
        }
        return NO;
    }
}
