//
//  CommandRunner.h
//  iSH
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CommandCompletionBlock)(int exitCode, NSString * _Nullable output, NSError * _Nullable error);

@interface CommandRunner : NSObject

+ (instancetype)sharedRunner NS_SWIFT_NAME(shared());

/// Executes a shell command asynchronously in the iSH Linux environment.
/// Automatically manages AudioKeepAliveManager for the duration of execution.
- (void)runCommand:(NSString *)command
               cwd:(nullable NSString *)cwd
           timeout:(NSTimeInterval)timeout
        completion:(CommandCompletionBlock)completion;

@end

NS_ASSUME_NONNULL_END
