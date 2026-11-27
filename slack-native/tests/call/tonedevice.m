// Owns the synthetic audio device.
#import "tonedevice.h"

#import <mach/mach_time.h>
#import <os/lock.h>

static const double SNToneRate = 48000;
/// 10 ms, as libwebrtc's own devices tick.
#define SNToneChunk 480u
/// 200 ms of played samples kept for the measures.
#define SNToneWindow 9600

@implementation SNToneDevice {
    id<RTCAudioDeviceDelegate> _delegate;
    RTCAudioDeviceDeliverRecordedDataBlock _deliver;
    RTCAudioDeviceGetPlayoutDataBlock _playout;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    uint64_t _started, _ticks;
    double _phase;
    BOOL _playoutInitialized, _recordingInitialized, _playing, _recording;
    os_unfair_lock _lock;
    int16_t _played[SNToneWindow];
    NSUInteger _playedCount;
}

- (instancetype)initWithFrequency:(double)frequency {
    if (!(self = [super init])) return nil;
    _frequency = frequency;
    _queue = dispatch_queue_create("slack-native.tone", DISPATCH_QUEUE_SERIAL);
    _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
}

- (double)deviceInputSampleRate { return SNToneRate; }
- (double)deviceOutputSampleRate { return SNToneRate; }
- (NSTimeInterval)inputIOBufferDuration { return SNToneChunk / SNToneRate; }
- (NSTimeInterval)outputIOBufferDuration { return SNToneChunk / SNToneRate; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return 0; }
- (NSTimeInterval)outputLatency { return 0; }
- (BOOL)isInitialized { return _delegate != nil; }

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    _delegate = delegate;
    _deliver = delegate.deliverRecordedData;
    _playout = delegate.getPlayoutData;
    return YES;
}

- (BOOL)terminateDevice {
    [self stopRecording];
    [self stopPlayout];
    dispatch_sync(_queue, ^{
        self->_deliver = nil;
        self->_playout = nil;
    });
    _delegate = nil;
    return YES;
}

- (BOOL)isPlayoutInitialized { return _playoutInitialized; }
- (BOOL)isRecordingInitialized { return _recordingInitialized; }
- (BOOL)isPlaying { return _playing; }
- (BOOL)isRecording { return _recording; }
- (BOOL)initializePlayout { return _playoutInitialized = YES; }
- (BOOL)initializeRecording { return _recordingInitialized = YES; }

- (BOOL)startPlayout {
    dispatch_sync(_queue, ^{ self->_playing = YES; });
    [self tick];
    return YES;
}

- (BOOL)stopPlayout {
    dispatch_sync(_queue, ^{ self->_playing = NO; });
    return YES;
}

- (BOOL)startRecording {
    dispatch_sync(_queue, ^{ self->_recording = YES; });
    [self tick];
    return YES;
}

- (BOOL)stopRecording {
    dispatch_sync(_queue, ^{ self->_recording = NO; });
    return YES;
}

/// One timer for both directions, catching up by wall clock so the rate stays 48 kHz however late
/// a firing comes.
- (void)tick {
    dispatch_sync(_queue, ^{
        if (self->_timer) return;
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        dispatch_source_set_timer(self->_timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        self->_started = mach_absolute_time();
        self->_ticks = 0;
        __weak SNToneDevice *weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf fire]; });
        dispatch_resume(self->_timer);
    });
}

- (void)fire {
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    double elapsed = (double)(mach_absolute_time() - _started) * base.numer / base.denom / NSEC_PER_SEC;
    uint64_t due = (uint64_t)(elapsed * SNToneRate / SNToneChunk);
    for (; _ticks < due; _ticks++) {
        if (_recording && _deliver) [self record];
        if (_playing && _playout) [self play];
    }
}

- (void)record {
    int16_t samples[SNToneChunk];
    double step = 2 * M_PI * self.frequency / SNToneRate;
    for (UInt32 i = 0; i < SNToneChunk; i++) {
        samples[i] = (int16_t)(16384 * sin(_phase));
        _phase = fmod(_phase + step, 2 * M_PI);
    }
    AudioBufferList list = {1, {{1, sizeof samples, samples}}};
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp stamp = {.mSampleTime = (Float64)(_ticks * SNToneChunk), .mFlags = kAudioTimeStampSampleTimeValid};
    _deliver(&flags, &stamp, 1, SNToneChunk, &list, NULL, nil);
    _recordedFrames += SNToneChunk;
}

- (void)play {
    int16_t samples[SNToneChunk] = {0};
    AudioBufferList list = {1, {{1, sizeof samples, samples}}};
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp stamp = {.mSampleTime = (Float64)(_ticks * SNToneChunk), .mFlags = kAudioTimeStampSampleTimeValid};
    _playout(&flags, &stamp, 0, SNToneChunk, &list);
    os_unfair_lock_lock(&_lock);
    for (UInt32 i = 0; i < SNToneChunk; i++) _played[(_playedCount + i) % SNToneWindow] = samples[i];
    _playedCount += SNToneChunk;
    os_unfair_lock_unlock(&_lock);
    _playedFrames += SNToneChunk;
}

- (void)copyWindow:(int16_t *)window {
    os_unfair_lock_lock(&_lock);
    for (NSUInteger i = 0; i < SNToneWindow; i++) window[i] = _played[(_playedCount + i) % SNToneWindow];
    os_unfair_lock_unlock(&_lock);
}

- (double)playedLevel {
    int16_t window[SNToneWindow];
    [self copyWindow:window];
    double sum = 0;
    for (NSUInteger i = 0; i < SNToneWindow; i++) sum += (double)window[i] * window[i];
    return sqrt(sum / SNToneWindow) / 32768;
}

- (double)playedFrequency {
    if (self.playedLevel < 0.01) return 0;
    int16_t window[SNToneWindow];
    [self copyWindow:window];
    // Upward crossings with a little hysteresis, so codec noise near zero is not counted.
    NSUInteger crossings = 0;
    BOOL low = window[0] < 0;
    for (NSUInteger i = 1; i < SNToneWindow; i++) {
        if (low && window[i] > 300) {
            crossings++;
            low = NO;
        } else if (!low && window[i] < -300) low = YES;
    }
    return crossings / (SNToneWindow / SNToneRate);
}

@end
