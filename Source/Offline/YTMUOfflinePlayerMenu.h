#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTMUOfflineShowQueueHandler)(void);

FOUNDATION_EXPORT void YTMUPresentOfflinePlayerMenu(UIViewController *presenter,
                                                    UIView *sourceView,
                                                    nullable YTMUOfflineShowQueueHandler showQueueHandler);

NS_ASSUME_NONNULL_END
