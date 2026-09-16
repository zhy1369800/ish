//
//  CommandRunner.m
//  iSH
//

#import "CommandRunner.h"
#import "AudioKeepAliveManager.h"
#import "AppDelegate.h"

#include <sys/stat.h>
#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/signal.h"
#include "fs/tty.h"
#include "fs/devices.h"
#include "kernel/errno.h"

@interface CommandContext : NSObject

@property (nonatomic, assign) int pid;
@property (nonatomic, assign) struct tty *tty;
@property (nonatomic, strong) NSMutableData *outputData;
@property (nonatomic, copy) CommandCompletionBlock completion;
@property (nonatomic, strong, nullable) dispatch_source_t timeoutTimer;
@property (nonatomic, assign) BOOL completed;

- (void)appendOutput:(const void *)buf length:(size_t)len;

@end

@implementation CommandContext

- (instancetype)init {
    if (self = [super init]) {
        _outputData = [NSMutableData data];
        _completed = NO;
    }
    return self;
}

- (void)appendOutput:(const void *)buf length:(size_t)len {
    @synchronized(self) {
        if (!self.completed && buf && len > 0) {
            [self.outputData appendBytes:buf length:len];
        }
    }
}

@end

static int runner_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    CommandContext *ctx = (__bridge CommandContext *) tty->data;
    if (ctx) {
        [ctx appendOutput:buf length:len];
    }
    return (int)len;
}

static struct tty_driver_ops runner_tty_ops = {
    .write = runner_tty_write,
};

static struct tty_driver runner_pty_driver = {
    .ops = &runner_tty_ops,
};

@interface CommandRunner ()

@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CommandContext *> *activeContexts;
@property (nonatomic, strong) NSRecursiveLock *contextsLock;

@end

@implementation CommandRunner

+ (instancetype)sharedRunner {
    static CommandRunner *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _activeContexts = [NSMutableDictionary dictionary];
        _contextsLock = [[NSRecursiveLock alloc] init];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processExitedNotification:)
                                                     name:ProcessExitedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)processExitedNotification:(NSNotification *)notif {
    NSNumber *pidNum = notif.userInfo[@"pid"];
    NSNumber *codeNum = notif.userInfo[@"code"];
    if (!pidNum) return;
    
    int pid = [pidNum intValue];
    int code = codeNum ? [codeNum intValue] : 0;
    
    CommandContext *ctx = nil;
    [self.contextsLock lock];
    ctx = self.activeContexts[@(pid)];
    [self.contextsLock unlock];
    
    if (ctx) {
        [self finishContext:ctx exitCode:code error:nil];
    }
}

- (void)finishContext:(CommandContext *)ctx exitCode:(int)exitCode error:(nullable NSError *)error {
    [self.contextsLock lock];
    if (ctx.completed) {
        [self.contextsLock unlock];
        return;
    }
    ctx.completed = YES;
    [self.activeContexts removeObjectForKey:@(ctx.pid)];
    [self.contextsLock unlock];
    
    if (ctx.timeoutTimer) {
        dispatch_source_cancel(ctx.timeoutTimer);
        ctx.timeoutTimer = nil;
    }
    
    NSString *output = nil;
    @synchronized(ctx) {
        output = [[NSString alloc] initWithData:ctx.outputData encoding:NSUTF8StringEncoding];
        if (!output) {
            output = [[NSString alloc] initWithData:ctx.outputData encoding:NSISOLatin1StringEncoding];
        }
        if (!output) {
            output = @"";
        }
    }
    
    if (ctx.tty) {
        struct tty *tty = ctx.tty;
        ctx.tty = NULL;
        CFBridgingRelease(tty->data);
        tty->data = NULL;
        tty_release(tty);
    }
    
    // Decrement keep-alive count
    [[AudioKeepAliveManager sharedManager] endKeepAlive];
    
    if (ctx.completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ctx.completion(exitCode, output, error);
        });
    }
}

- (void)runCommand:(NSString *)command
               cwd:(nullable NSString *)cwd
           timeout:(NSTimeInterval)timeout
        completion:(CommandCompletionBlock)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Increment keep-alive count for this task
        [[AudioKeepAliveManager sharedManager] beginKeepAlive];
        
        // Wait up to 5 seconds for PID 1 during cold boot if necessary
        struct task *initTask = NULL;
        for (int retry = 0; retry < 50; retry++) {
            lock(&pids_lock);
            initTask = pid_get_task(1);
            unlock(&pids_lock);
            if (initTask != NULL) {
                break;
            }
            [NSThread sleepForTimeInterval:0.1];
        }
        
        if (initTask == NULL) {
            [[AudioKeepAliveManager sharedManager] endKeepAlive];
            NSError *err = [NSError errorWithDomain:@"iSHCommandRunner"
                                               code:-1
                                           userInfo:@{NSLocalizedDescriptionKey: @"iSH kernel is not yet running"}];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(-1, nil, err);
                });
            }
            return;
        }
        
        current = initTask;
        
        struct tty *tty = pty_open_fake(&runner_pty_driver);
        current = NULL;
        
        if (IS_ERR(tty)) {
            [[AudioKeepAliveManager sharedManager] endKeepAlive];
            NSError *err = [NSError errorWithDomain:@"iSHCommandRunner"
                                               code:PTR_ERR(tty)
                                           userInfo:@{NSLocalizedDescriptionKey: @"Failed to allocate pseudo-terminal"}];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(-1, nil, err);
                });
            }
            return;
        }
        
        CommandContext *ctx = [[CommandContext alloc] init];
        ctx.tty = tty;
        ctx.completion = completion;
        tty->data = (void *)CFBridgingRetain(ctx);
        
        int err = become_new_init_child();
        if (err < 0) {
            CFBridgingRelease(tty->data);
            tty->data = NULL;
            tty_release(tty);
            [[AudioKeepAliveManager sharedManager] endKeepAlive];
            NSError *error = [NSError errorWithDomain:@"iSHCommandRunner"
                                                 code:err
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to construct init child process"}];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(-1, nil, error);
                });
            }
            return;
        }
        
        NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
        err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
        if (err < 0) {
            CFBridgingRelease(tty->data);
            tty->data = NULL;
            tty_release(tty);
            [[AudioKeepAliveManager sharedManager] endKeepAlive];
            NSError *error = [NSError errorWithDomain:@"iSHCommandRunner"
                                                 code:err
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to attach stdio"}];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(-1, nil, error);
                });
            }
            return;
        }
        
        if (cwd && cwd.length > 0) {
            struct fd *dir_fd = generic_open(cwd.fileSystemRepresentation, O_RDONLY_, 0);
            if (!IS_ERR(dir_fd)) {
                fs_chdir(current->fs, dir_fd);
            }
        }
        
        // Prepare argv for /bin/sh -c "<command>"
        char argv[8192];
        const char *arg0 = "/bin/sh";
        const char *arg1 = "-c";
        const char *arg2 = command.UTF8String;
        size_t len0 = strlen(arg0) + 1;
        size_t len1 = strlen(arg1) + 1;
        size_t len2 = strlen(arg2) + 1;
        
        if (len0 + len1 + len2 + 1 > sizeof(argv)) {
            CFBridgingRelease(tty->data);
            tty->data = NULL;
            tty_release(tty);
            [[AudioKeepAliveManager sharedManager] endKeepAlive];
            NSError *error = [NSError errorWithDomain:@"iSHCommandRunner"
                                                 code:_E2BIG
                                             userInfo:@{NSLocalizedDescriptionKey: @"Command length exceeds buffer limit"}];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(-1, nil, error);
                });
            }
            return;
        }
        
        char *p = argv;
        memcpy(p, arg0, len0); p += len0;
        memcpy(p, arg1, len1); p += len1;
        memcpy(p, arg2, len2); p += len2;
        *p = '\0';
        
        const char *envp = "TERM=xterm-256color\0PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin\0HOME=/root\0USER=root\0\0";
        
        err = do_execve("/bin/sh", 3, argv, envp);
        if (err < 0) {
            CFBridgingRelease(tty->data);
            tty->data = NULL;
            tty_release(tty);
            [[AudioKeepAliveManager sharedManager] endKeepAlive];
            if (current != NULL) {
                lock(&pids_lock);
                task_destroy(current);
                unlock(&pids_lock);
                current = NULL;
            }
            NSError *error = [NSError errorWithDomain:@"iSHCommandRunner"
                                                 code:err
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to execute /bin/sh"}];
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(-1, nil, error);
                });
            }
            return;
        }
        
        int pid = current->pid;
        ctx.pid = pid;
        
        [self.contextsLock lock];
        self.activeContexts[@(pid)] = ctx;
        [self.contextsLock unlock];
        
        // Timeout handling
        if (timeout > 0) {
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
            __weak typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                NSError *timeoutError = [NSError errorWithDomain:@"iSHCommandRunner"
                                                            code:-2
                                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Command timed out after %.1f seconds", timeout]}];
                sys_kill(ctx.pid, SIGKILL_);
                [weakSelf finishContext:ctx exitCode:-1 error:timeoutError];
            });
            ctx.timeoutTimer = timer;
            dispatch_resume(timer);
        }
        
        task_start(current);
        current = NULL;
    });
}

@end
