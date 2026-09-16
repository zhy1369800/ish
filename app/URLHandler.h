//
//  URLHandler.h
//  iSH
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface URLHandler : NSObject

+ (instancetype)sharedHandler;

/// Handles incoming URL schemes (e.g. ish://run, ish://x-callback-url/run)
- (BOOL)handleURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
