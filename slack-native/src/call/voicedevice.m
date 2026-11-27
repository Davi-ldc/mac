// Owns the Mac's audio for calls: an AVAudioEngine whose input node runs Apple's voice processing
// (echo cancellation against what the engine plays, noise suppression, levels) while libwebrtc
// records, and a source node that plays what libwebrtc decodes.
//
// libwebrtc calls the device on its own audio thread; the engine's render blocks run on Core
// Audio's real-time thread, touching only buffers made beforehand. Every change of what runs
// (playout, recording, a device change) builds the engine anew, a few times a call: an engine
// whose input node was ever touched keeps the microphone open, so one that only plays must be a
// fresh one.
#import "call/voicedevice.h"

// Only calls use it, and only libwebrtc calls it.
#if SN_WEBRTC
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdatomic.h>

static void *AVFoundationHandle(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY | RTLD_LOCAL); });
    return handle;
}

/// What libwebrtc gets and gives: 16-bit mono at 48 kHz on the way out (the engine's mixer
/// converts to the device), the voice processor's own rate on the way in (libwebrtc resamples).
static const double SNPlayoutRate = 48000;
/// More than the engine renders at once (4096 at most by default).
static const AVAudioFrameCount SNMaximumFrames = 8192;

@implementation SNVoiceDevice {
    os_unfair_lock _delegateLock;
    id<RTCAudioDeviceDelegate> _delegate;
    RTCAudioDeviceDeliverRecordedDataBlock _deliver;
    RTCAudioDeviceGetPlayoutDataBlock _playout;
    AVAudioEngine *_engine;
    id _configurationObserver;
    double _inputRate;
    BOOL _playoutInitialized, _recordingInitialized;
    // Read on the real-time thread.
    atomic_bool _playing, _recording;
    int16_t *_playBuffer, *_recordBuffer;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _delegateLock = OS_UNFAIR_LOCK_INIT;
    _inputRate = SNPlayoutRate;
    _playBuffer = calloc(SNMaximumFrames, sizeof(int16_t));
    _recordBuffer = calloc(SNMaximumFrames, sizeof(int16_t));
    return self;
}

- (id<RTCAudioDeviceDelegate>)currentDelegate {
    os_unfair_lock_lock(&_delegateLock);
    id<RTCAudioDeviceDelegate> delegate = _delegate;
    os_unfair_lock_unlock(&_delegateLock);
    return delegate;
}

- (void)dealloc {
    [self terminateDevice];
    free(_playBuffer);
    free(_recordBuffer);
}

- (double)deviceInputSampleRate { return _inputRate; }
- (double)deviceOutputSampleRate { return SNPlayoutRate; }
- (NSTimeInterval)inputIOBufferDuration { return 0.01; }
- (NSTimeInterval)outputIOBufferDuration { return 0.01; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return _recordingInitialized && _engine ? _engine.inputNode.presentationLatency : 0; }
- (NSTimeInterval)outputLatency { return _engine ? _engine.outputNode.presentationLatency : 0; }
- (BOOL)isInitialized { return self.currentDelegate != nil; }
- (BOOL)isPlayoutInitialized { return _playoutInitialized; }
- (BOOL)isRecordingInitialized { return _recordingInitialized; }
- (BOOL)isPlaying { return atomic_load_explicit(&_playing, memory_order_acquire); }
- (BOOL)isRecording { return atomic_load_explicit(&_recording, memory_order_acquire); }

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    os_unfair_lock_lock(&_delegateLock);
    if (_delegate) {
        os_unfair_lock_unlock(&_delegateLock);
        return YES;
    }
    _delegate = delegate;
    _deliver = delegate.deliverRecordedData;
    _playout = delegate.getPlayoutData;
    os_unfair_lock_unlock(&_delegateLock);
    return YES;
}

- (BOOL)terminateDevice {
    atomic_store_explicit(&_playing, false, memory_order_release);
    atomic_store_explicit(&_recording, false, memory_order_release);
    _playoutInitialized = _recordingInitialized = NO;
    [self discardEngine];
    os_unfair_lock_lock(&_delegateLock);
    _deliver = nil;
    _playout = nil;
    _delegate = nil;
    os_unfair_lock_unlock(&_delegateLock);
    return YES;
}

- (BOOL)initializePlayout {
    _playoutInitialized = YES;
    return YES;
}

- (BOOL)startPlayout {
    atomic_store_explicit(&_playing, true, memory_order_release);
    return [self apply];
}

- (BOOL)stopPlayout {
    atomic_store_explicit(&_playing, false, memory_order_release);
    _playoutInitialized = NO;
    return [self apply];
}

/// The microphone opens here: libwebrtc reads the voice processor's rate right after.
- (BOOL)initializeRecording {
    _recordingInitialized = YES;
    return [self apply];
}

- (BOOL)startRecording {
    if (!_recordingInitialized && ![self initializeRecording]) return NO;
    atomic_store_explicit(&_recording, true, memory_order_release);
    return YES;
}

- (BOOL)stopRecording {
    atomic_store_explicit(&_recording, false, memory_order_release);
    _recordingInitialized = NO;
    return [self apply];
}

- (void)discardEngine {
    [_engine stop];
    if (_configurationObserver) [NSNotificationCenter.defaultCenter removeObserver:_configurationObserver];
    _configurationObserver = nil;
    _engine = nil;
}

/// A new engine for what libwebrtc wants now, running; none when it wants nothing.
- (BOOL)apply {
    [self discardEngine];
    BOOL input = _recordingInitialized, output = atomic_load_explicit(&_playing, memory_order_acquire);
    if (!input && !output) return YES;
    void *av = AVFoundationHandle();
    Class engineClass = av ? NSClassFromString(@"AVAudioEngine") : Nil;
    Class formatClass = av ? NSClassFromString(@"AVAudioFormat") : Nil;
    if (!engineClass || !formatClass) return NO;
    _engine = [engineClass new];
    AVAudioFormat *playout = [[formatClass alloc] initStandardFormatWithSampleRate:SNPlayoutRate channels:1];
    AVAudioSourceNode *source = [self sourceNode:playout];
    [_engine attachNode:source];
    [_engine connect:source to:_engine.mainMixerNode format:playout];
    NSError *error;
    if (input) {
        AVAudioInputNode *inputNode = _engine.inputNode;
        // On the input node, voice processing takes the output node with it: the echo it cancels
        // is what this engine plays.
        if (![inputNode setVoiceProcessingEnabled:YES error:&error]) {
            NSLog(@"slack-native: voice processing: %@", error.localizedDescription);
            [self discardEngine];
            [self.currentDelegate notifyAudioInputInterrupted];
            return NO;
        }
        // Other apps' sound is left as it is rather than ducked under the call.
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = (AVAudioVoiceProcessingOtherAudioDuckingConfiguration){.enableAdvancedDucking = NO, .duckingLevel = AVAudioVoiceProcessingOtherAudioDuckingLevelMin};
        AVAudioFormat *format = [inputNode outputFormatForBus:0];
        if (format.sampleRate <= 0) {
            [self discardEngine];
            [self.currentDelegate notifyAudioInputInterrupted];
            return NO;
        }
        _inputRate = format.sampleRate;
        AVAudioSinkNode *sink = [self sinkNode];
        [_engine attachNode:sink];
        [_engine connect:inputNode to:sink format:format];
    }
    // A device plugged in or out, or the default one changed: the engine has stopped by itself.
    __weak SNVoiceDevice *weakSelf = self;
    CFStringRef const *changeSym = (CFStringRef const *)dlsym(av, "AVAudioEngineConfigurationChangeNotification");
    NSNotificationName changeName = (changeSym && *changeSym) ? (__bridge NSString *)*changeSym : @"AVAudioEngineConfigurationChangeNotification";
    _configurationObserver = [NSNotificationCenter.defaultCenter addObserverForName:changeName object:_engine queue:nil usingBlock:^(NSNotification *note) {
        SNVoiceDevice *device = weakSelf;
        id<RTCAudioDeviceDelegate> delegate = device.currentDelegate;
        if (!delegate) return;
        [delegate dispatchAsync:^{
            SNVoiceDevice *device = weakSelf;
            id<RTCAudioDeviceDelegate> current = device.currentDelegate;
            if (!device || !current) return;
            double rate = device->_inputRate;
            [device apply];
            if (device->_inputRate != rate) [current notifyAudioInputParametersChange];
        }];
    }];
    [_engine prepare];
    if (![_engine startAndReturnError:&error]) {
        NSLog(@"slack-native: audio engine: %@", error.localizedDescription);
        [self discardEngine];
        id<RTCAudioDeviceDelegate> delegate = self.currentDelegate;
        if (input) [delegate notifyAudioInputInterrupted];
        if (output) [delegate notifyAudioOutputInterrupted];
        return NO;
    }
    return YES;
}

- (AVAudioSourceNode *)sourceNode:(AVAudioFormat *)format {
    __unsafe_unretained SNVoiceDevice *device = self;
    // _playout stays alive until terminateDevice (after discardEngine stops the audio thread).
    __unsafe_unretained RTCAudioDeviceGetPlayoutDataBlock pull = _playout;
    int16_t *buffer = _playBuffer;
    return [[NSClassFromString(@"AVAudioSourceNode") alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frames, AudioBufferList *output) {
        float *samples = output->mBuffers[0].mData;
        if (!atomic_load_explicit(&device->_playing, memory_order_acquire) || !pull || frames > SNMaximumFrames) {
            memset(samples, 0, frames * sizeof(float));
            *isSilence = YES;
            return noErr;
        }
        AudioBufferList list = {1, {{1, frames * (UInt32)sizeof(int16_t), buffer}}};
        AudioUnitRenderActionFlags flags = 0;
        pull(&flags, timestamp, 0, frames, &list);
        for (AVAudioFrameCount i = 0; i < frames; i++) samples[i] = buffer[i] / 32768.0f;
        return noErr;
    }];
}

- (AVAudioSinkNode *)sinkNode {
    __unsafe_unretained SNVoiceDevice *device = self;
    __unsafe_unretained RTCAudioDeviceDeliverRecordedDataBlock deliver = _deliver;
    int16_t *buffer = _recordBuffer;
    return [[NSClassFromString(@"AVAudioSinkNode") alloc] initWithReceiverBlock:^OSStatus(const AudioTimeStamp *timestamp, AVAudioFrameCount frames, const AudioBufferList *input) {
        if (!atomic_load_explicit(&device->_recording, memory_order_acquire) || !deliver || frames > SNMaximumFrames || !input->mNumberBuffers) return noErr;
        // The voice processor may hand over several microphone channels; the first is the voice.
        const float *samples = input->mBuffers[0].mData;
        UInt32 stride = MAX(1u, input->mBuffers[0].mNumberChannels);
        for (AVAudioFrameCount i = 0; i < frames; i++) buffer[i] = (int16_t)(MAX(-1.0f, MIN(1.0f, samples[i * stride])) * 32767);
        AudioBufferList list = {1, {{1, frames * (UInt32)sizeof(int16_t), buffer}}};
        AudioUnitRenderActionFlags flags = 0;
        deliver(&flags, timestamp, 1, frames, &list, NULL, nil);
        return noErr;
    }];
}

@end

#endif
