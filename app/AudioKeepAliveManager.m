//
//  AudioKeepAliveManager.m
//  iSH
//

#import "AudioKeepAliveManager.h"
#import <AVFoundation/AVFoundation.h>

@interface AudioKeepAliveManager ()

@property (nonatomic, assign) NSUInteger activeTaskCount;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSRecursiveLock *lock;

@end

@implementation AudioKeepAliveManager

+ (instancetype)sharedManager {
    static AudioKeepAliveManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _lock = [[NSRecursiveLock alloc] init];
        _activeTaskCount = 0;
        [self setupInterruptionHandling];
    }
    return self;
}

- (BOOL)isKeepingAlive {
    [self.lock lock];
    BOOL keeping = (self.activeTaskCount > 0);
    [self.lock unlock];
    return keeping;
}

- (void)beginKeepAlive {
    [self.lock lock];
    self.activeTaskCount++;
    if (self.activeTaskCount == 1) {
        [self startSilentAudio];
    }
    [self.lock unlock];
}

- (void)endKeepAlive {
    [self.lock lock];
    if (self.activeTaskCount > 0) {
        self.activeTaskCount--;
    }
    if (self.activeTaskCount == 0) {
        [self stopSilentAudio];
    }
    [self.lock unlock];
}

#pragma mark - Audio Playback

- (void)startSilentAudio {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        
        // Use playback category with mixWithOthers so it never interrupts background music or calls
        BOOL success = [session setCategory:AVAudioSessionCategoryPlayback
                                withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                      error:&error];
        if (!success) {
            NSLog(@"[AudioKeepAliveManager] Failed to set audio category: %@", error);
        }
        
        success = [session setActive:YES error:&error];
        if (!success) {
            NSLog(@"[AudioKeepAliveManager] Failed to activate audio session: %@", error);
        }
        
        if (!self.audioPlayer) {
            NSData *silentWav = [self generateSilentWavData];
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:silentWav error:&error];
            if (!self.audioPlayer) {
                NSLog(@"[AudioKeepAliveManager] Failed to create audio player: %@", error);
                return;
            }
            self.audioPlayer.numberOfLoops = -1; // Infinite loop
            self.audioPlayer.volume = 0.001f;   // Imperceptible/silent volume
            [self.audioPlayer prepareToPlay];
        }
        
        [self.audioPlayer play];
        NSLog(@"[AudioKeepAliveManager] Silent audio keep-alive started. Active tasks: %lu", (unsigned long)self.activeTaskCount);
    });
}

- (void)stopSilentAudio {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isKeepingAlive]) {
            return;
        }
        if (self.audioPlayer && self.audioPlayer.isPlaying) {
            [self.audioPlayer stop];
        }
        
        NSError *error = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
        if (error) {
            NSLog(@"[AudioKeepAliveManager] Failed to deactivate audio session: %@", error);
        }
        
        NSLog(@"[AudioKeepAliveManager] Silent audio keep-alive stopped. Idle mode resumed.");
    });
}

#pragma mark - Silent WAV Generator

- (NSData *)generateSilentWavData {
    // Standard 1-second 44.1kHz 16-bit Mono PCM WAV
    uint32_t sampleRate = 44100;
    uint16_t channels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sampleRate * channels * (bitsPerSample / 8);
    uint16_t blockAlign = channels * (bitsPerSample / 8);
    uint32_t pcmDataSize = byteRate; // 1 second of audio
    uint32_t totalFileSize = 36 + pcmDataSize;
    
    NSMutableData *data = [NSMutableData dataWithCapacity:44 + pcmDataSize];
    
    // RIFF Header
    [data appendBytes:"RIFF" length:4];
    [data appendBytes:&totalFileSize length:4];
    [data appendBytes:"WAVE" length:4];
    
    // fmt subchunk
    [data appendBytes:"fmt " length:4];
    uint32_t subchunk1Size = 16;
    [data appendBytes:&subchunk1Size length:4];
    uint16_t audioFormat = 1; // PCM
    [data appendBytes:&audioFormat length:2];
    [data appendBytes:&channels length:2];
    [data appendBytes:&sampleRate length:4];
    [data appendBytes:&byteRate length:4];
    [data appendBytes:&blockAlign length:2];
    [data appendBytes:&bitsPerSample length:2];
    
    // data subchunk
    [data appendBytes:"data" length:4];
    [data appendBytes:&pcmDataSize length:4];
    
    // Zeroed PCM samples
    void *silence = calloc(1, pcmDataSize);
    if (silence) {
        [data appendBytes:silence length:pcmDataSize];
        free(silence);
    }
    
    return data;
}

#pragma mark - Interruption Handling

- (void)setupInterruptionHandling {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAudioSessionInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSNumber *typeNumber = userInfo[AVAudioSessionInterruptionTypeKey];
    if (!typeNumber) return;
    
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)typeNumber.unsignedIntegerValue;
    if (type == AVAudioSessionInterruptionTypeEnded) {
        [self.lock lock];
        if (self.activeTaskCount > 0 && self.audioPlayer) {
            NSNumber *optionsNumber = userInfo[AVAudioSessionInterruptionOptionKey];
            if (optionsNumber && (optionsNumber.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume)) {
                [self.audioPlayer play];
            } else {
                [self.audioPlayer play];
            }
            NSLog(@"[AudioKeepAliveManager] Resumed audio playback after interruption.");
        }
        [self.lock unlock];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
