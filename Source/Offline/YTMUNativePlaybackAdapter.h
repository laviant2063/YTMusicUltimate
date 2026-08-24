#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "YTMUPlaybackCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface YTMUNativePlaybackAdapter : NSObject <YTMUNativePlaybackControlling>

@property (class, nonatomic, readonly) YTMUNativePlaybackAdapter *sharedAdapter;
@property (nonatomic, assign, readonly, getter=isNativePlaybackAudible) BOOL nativePlaybackAudible;
@property (nonatomic, assign, readonly, getter=isNativeMiniPlayerSuppressed) BOOL nativeMiniPlayerSuppressed;
@property (nonatomic, assign, readonly, getter=isNativeEmptyMiniPlayerCollapsed) BOOL nativeEmptyMiniPlayerCollapsed;

- (void)registerPlayerViewController:(UIViewController *)controller;
- (void)registerWatchViewController:(UIViewController *)controller;
- (void)registerMiniPlayerViewController:(UIViewController *)controller;
- (void)prepareNativeMiniPlayerForPlaybackStart;
- (void)nativePlaybackDidStart;
- (void)nativePlaybackDidPause;
- (void)nativePlaybackSessionDidEnd;
- (void)refreshNativePlaybackState;
- (BOOL)requestNativeSessionEndFromMiniPlayerController:(UIViewController *)controller
                                                  error:(NSError * _Nullable __autoreleasing * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
