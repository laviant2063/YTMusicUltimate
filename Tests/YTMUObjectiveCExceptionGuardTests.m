#import <Foundation/Foundation.h>

#import "YTMUObjectiveCExceptionGuard.h"

static NSUInteger failures = 0;

#define ASSERT_TRUE(condition) do { \
    if (!(condition)) { \
        NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void testSuccessfulBlock(void) {
    __block BOOL executed = NO;
    NSException *exception = nil;
    BOOL succeeded = YTMUPerformObjectiveCBlockSafely(^{
        executed = YES;
    }, &exception);

    ASSERT_TRUE(succeeded);
    ASSERT_TRUE(executed);
    ASSERT_TRUE(exception == nil);
}

static void testExceptionIsContained(void) {
    NSException *exception = nil;
    BOOL succeeded = YTMUPerformObjectiveCBlockSafely(^{
        [NSException raise:@"YTMUTestException" format:@"simulated MediaPlayer failure"];
    }, &exception);

    ASSERT_TRUE(!succeeded);
    ASSERT_TRUE([exception.name isEqualToString:@"YTMUTestException"]);
}

static void testNilBlockFailsWithoutThrowing(void) {
    NSException *exception = [NSException exceptionWithName:@"stale" reason:nil userInfo:nil];
    BOOL succeeded = YTMUPerformObjectiveCBlockSafely(nil, &exception);

    ASSERT_TRUE(!succeeded);
    ASSERT_TRUE(exception == nil);
}

int main(void) {
    @autoreleasepool {
        testSuccessfulBlock();
        testExceptionIsContained();
        testNilBlockFailsWithoutThrowing();
        if (failures == 0) {
            NSLog(@"Objective-C exception guard tests passed");
        }
    }
    return failures == 0 ? 0 : 1;
}
