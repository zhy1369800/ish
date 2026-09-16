//
//  URLHandler.m
//  iSH
//

#import "URLHandler.h"
#import "CommandRunner.h"
#import <UIKit/UIKit.h>

@implementation URLHandler

+ (instancetype)sharedHandler {
    static URLHandler *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (BOOL)handleURL:(NSURL *)url {
    if (![url.scheme.lowercaseString isEqualToString:@"ish"]) {
        return NO;
    }
    
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path.lowercaseString;
    
    // Parse query items
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableDictionary<NSString *, NSString *> *queryDict = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        if (item.name && item.value) {
            queryDict[item.name.lowercaseString] = item.value;
        }
    }
    
    BOOL isRunCommand = NO;
    if ([host isEqualToString:@"run"]) {
        isRunCommand = YES;
    } else if ([host isEqualToString:@"x-callback-url"] && ([path isEqualToString:@"/run"] || [path isEqualToString:@"run"])) {
        isRunCommand = YES;
    }
    
    if (!isRunCommand) {
        return NO;
    }
    
    NSString *command = queryDict[@"cmd"] ?: queryDict[@"command"];
    if (!command || command.length == 0) {
        NSLog(@"[URLHandler] Missing 'cmd' parameter in URL: %@", url);
        return NO;
    }
    
    NSString *cwd = queryDict[@"cwd"] ?: queryDict[@"dir"];
    NSTimeInterval timeout = 300.0;
    if (queryDict[@"timeout"]) {
        timeout = [queryDict[@"timeout"] doubleValue];
    }
    
    NSString *xSuccess = queryDict[@"x-success"];
    NSString *xError = queryDict[@"x-error"];
    
    [[CommandRunner sharedRunner] runCommand:command
                                         cwd:cwd
                                     timeout:timeout
                                  completion:^(int exitCode, NSString * _Nullable output, NSError * _Nullable error) {
        if (error != nil && xError.length > 0) {
            NSURLComponents *errComponents = [NSURLComponents componentsWithString:xError];
            NSMutableArray<NSURLQueryItem *> *items = [errComponents.queryItems mutableCopy] ?: [NSMutableArray array];
            [items addObject:[NSURLQueryItem queryItemWithName:@"errorMessage" value:error.localizedDescription]];
            [items addObject:[NSURLQueryItem queryItemWithName:@"errorCode" value:@(error.code).stringValue]];
            errComponents.queryItems = items;
            if (errComponents.URL) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] openURL:errComponents.URL options:@{} completionHandler:nil];
                });
            }
        } else if (xSuccess.length > 0) {
            NSURLComponents *succComponents = [NSURLComponents componentsWithString:xSuccess];
            NSMutableArray<NSURLQueryItem *> *items = [succComponents.queryItems mutableCopy] ?: [NSMutableArray array];
            [items addObject:[NSURLQueryItem queryItemWithName:@"output" value:output ?: @""]];
            [items addObject:[NSURLQueryItem queryItemWithName:@"exitCode" value:@(exitCode).stringValue]];
            succComponents.queryItems = items;
            if (succComponents.URL) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] openURL:succComponents.URL options:@{} completionHandler:nil];
                });
            }
        }
    }];
    
    return YES;
}

@end
