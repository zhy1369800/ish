//
//  AudioKeepAliveManager.h
//  iSH
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioKeepAliveManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly) NSUInteger activeTaskCount;
@property (nonatomic, readonly) BOOL isKeepingAlive;

/// Begin a task that requires background keep-alive. Increments reference count.
/// Activates silent audio session on first active task.
- (void)beginKeepAlive;

/// End a task that requires background keep-alive. Decrements reference count.
/// Deactivates silent audio session when task count reaches zero.
- (void)endKeepAlive;

@end

NS_ASSUME_NONNULL_END
