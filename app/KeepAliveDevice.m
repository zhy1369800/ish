//
//  KeepAliveDevice.m
//  iSH
//

#import <Foundation/Foundation.h>
#include "KeepAliveDevice.h"
#import "AudioKeepAliveManager.h"
#include "kernel/fs.h"
#include "fs/dev.h"
#include "kernel/errno.h"

static int keepalive_open(int major, int minor, struct fd *fd) {
    return 0;
}

static int keepalive_close(struct fd *fd) {
    return 0;
}

static ssize_t keepalive_read(struct fd *fd, void *buf, size_t size) {
    if (size == 0)
        return 0;
    
    BOOL active = [AudioKeepAliveManager.sharedManager isKeepingAlive];
    const char *statusStr = active ? "1\n" : "0\n";
    size_t len = strlen(statusStr);
    
    if (fd->offset >= (off_t)len)
        return 0; // EOF
    
    size_t to_read = len - (size_t)fd->offset;
    if (to_read > size)
        to_read = size;
    
    memcpy(buf, statusStr + fd->offset, to_read);
    fd->offset += to_read;
    return to_read;
}

static ssize_t keepalive_write(struct fd *fd, const void *buf, size_t size) {
    if (size == 0)
        return 0;
    
    // Read up to 32 bytes for command
    char input[33] = {0};
    size_t copy_size = size > 32 ? 32 : size;
    memcpy(input, buf, copy_size);
    
    NSString *cmd = [[NSString stringWithUTF8String:input] stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    
    if ([cmd isEqualToString:@"1"] || [cmd isEqualToString:@"on"] ||
        [cmd isEqualToString:@"start"] || [cmd isEqualToString:@"enable"]) {
        [AudioKeepAliveManager.sharedManager beginKeepAlive];
    } else if ([cmd isEqualToString:@"0"] || [cmd isEqualToString:@"off"] ||
               [cmd isEqualToString:@"stop"] || [cmd isEqualToString:@"disable"]) {
        [AudioKeepAliveManager.sharedManager endKeepAlive];
    }
    
    return size;
}

const struct dev_ops keepalive_dev = {
    .open = keepalive_open,
    .fd.close = keepalive_close,
    .fd.read = keepalive_read,
    .fd.write = keepalive_write,
};
