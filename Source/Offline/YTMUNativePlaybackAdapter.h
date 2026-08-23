#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "YTMUPlaybackCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMUNativePlaybackAdapter : NSObject <YTMUNativePlaybackControlling>

@property (class, nonatomic, readonly) YTMUNativePlaybackAdapter *sharedAdapter;
@property (nonatomic, assign, readonly, getter=isNativePlaybackAudible) BOOL nativePlaybackAudible;

- (void)registerPlayerViewController:(UIViewController *)controller;
- (void)registerWatchViewController:(UIViewController *)controller;
- (void)registerMiniPlayerViewController:(UIViewController *)controller;
- (void)nativePlaybackDidStart;
- (void)nativePlaybackDidPause;
- (void)nativePlaybackSessionDidEnd;
- (void)refreshNativePlaybackState;

@end

NS_ASSUME_NONNULL_END
