// Owns playing one file's stream.
#import <dlfcn.h>

#import "ui/files/filenet.h"
#import "ui/files/player.h"

/// How often the time and progress move while playing.
static const NSTimeInterval kTick = 0.25;

static void *CoreMediaHandle(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY | RTLD_LOCAL); });
    return handle;
}

static CMTime MakeTime(Float64 seconds, int32_t timescale) {
    static CMTime (*fn)(Float64, int32_t);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = dlsym(CoreMediaHandle(), "CMTimeMakeWithSeconds"); });
    return fn ? fn(seconds, timescale) : (CMTime){0, timescale, kCMTimeFlags_Valid, 0};
}

static Float64 TimeSeconds(CMTime time) {
    static Float64 (*fn)(CMTime);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = dlsym(CoreMediaHandle(), "CMTimeGetSeconds"); });
    return fn ? fn(time) : 0;
}

static CMTime ZeroTime(void) {
    static CMTime zero;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const CMTime *sym = dlsym(CoreMediaHandle(), "kCMTimeZero");
        zero = sym ? *sym : (CMTime){0, 1, kCMTimeFlags_Valid, 0};
    });
    return zero;
}

@implementation SNMediaPlayer {
    id _timeObserver;
    id _endObserver;
    NSTimeInterval _fileDuration;
}

+ (instancetype)playerForFile:(SNFile *)file {
    // The client's sources: a video's transcoded mp4, an audio clip's aac, else the upload.
    NSURL *url = file.mp4URL ?: file.aacURL ?: file.privateURL;
    AVURLAsset *asset = url ? SNFileAsset(url) : nil;
    if (!asset) return nil;
    void *av = SNLoadAVFoundation();
    Class itemClass = av ? NSClassFromString(@"AVPlayerItem") : Nil;
    Class playerClass = av ? NSClassFromString(@"AVPlayer") : Nil;
    if (!itemClass || !playerClass) return nil;
    SNMediaPlayer *media = [self new];
    media->_fileDuration = file.duration;
    media->_rate = 1;
    AVPlayerItem *item = [itemClass playerItemWithAsset:asset];
    media->_player = [playerClass playerWithPlayerItem:item];
    // A short look ahead: the reader may stop after a few seconds of a long recording.
    item.preferredForwardBufferDuration = 10;
    __weak SNMediaPlayer *weak = media;
    media->_timeObserver = [media->_player addPeriodicTimeObserverForInterval:MakeTime(kTick, 600) queue:dispatch_get_main_queue()
                                                                   usingBlock:^(CMTime time) { [weak changed]; }];
    CFStringRef const *endSym = (CFStringRef const *)dlsym(av, "AVPlayerItemDidPlayToEndTimeNotification");
    NSNotificationName endName = (endSym && *endSym) ? (__bridge NSString *)*endSym : @"AVPlayerItemDidPlayToEndTimeNotification";
    media->_endObserver = [NSNotificationCenter.defaultCenter addObserverForName:endName object:item queue:NSOperationQueue.mainQueue
                                                                     usingBlock:^(NSNotification *note) { [weak finished]; }];
    return media;
}

- (void)dealloc {
    [_player pause];
    if (_timeObserver) [_player removeTimeObserver:_timeObserver];
    if (_endObserver) [NSNotificationCenter.defaultCenter removeObserver:_endObserver];
    [_player replaceCurrentItemWithPlayerItem:nil];
}

- (BOOL)isPlaying { return _player.rate != 0; }

- (NSTimeInterval)currentTime {
    double seconds = TimeSeconds(_player.currentTime);
    return isfinite(seconds) ? MAX(0, seconds) : 0;
}

- (NSTimeInterval)duration {
    double seconds = TimeSeconds(_player.currentItem.duration);
    return isfinite(seconds) && seconds > 0 ? seconds : _fileDuration;
}

- (BOOL)isMuted { return _player.muted; }

- (void)setMuted:(BOOL)muted {
    _player.muted = muted;
    [self changed];
}

- (void)setRate:(float)rate {
    _rate = rate;
    if (self.playing) _player.rate = rate;
    [self changed];
}

- (void)play {
    // Played to the end, it starts over.
    if (self.duration > 0 && self.currentTime >= self.duration - 0.05) [_player seekToTime:ZeroTime()];
    _player.rate = _rate;
    [self changed];
}

- (void)pause {
    [_player pause];
    [self changed];
}

- (void)seekToFraction:(double)fraction { [self seekToTime:MAX(0, MIN(1, fraction)) * self.duration]; }

- (void)seekToTime:(NSTimeInterval)time {
    __weak SNMediaPlayer *weak = self;
    [_player seekToTime:MakeTime(time, 600) toleranceBefore:ZeroTime() toleranceAfter:ZeroTime() completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weak changed]; });
    }];
    [self changed];
}

- (void)finished {
    [_player pause];
    [self changed];
}

- (void)changed {
    if (self.onChange) self.onChange(self);
}

@end
