// Tests the Mac's call audio as far as a test may go: playout through AVAudioEngine pulls
// libwebrtc's samples and leaves the microphone closed (recording is never started here).
#import <CoreAudio/CoreAudio.h>

#import "../net/stub.h"
#import "call/voicedevice.h"
#import "test.h"

#if SN_WEBRTC

__asm__(".linker_option \"-framework\", \"CoreAudio\"");

@interface SNTestAudioDelegate : NSObject <RTCAudioDeviceDelegate>
@property (atomic) NSUInteger pulledFrames;
@end

@implementation SNTestAudioDelegate

- (RTCAudioDeviceDeliverRecordedDataBlock)deliverRecordedData {
    return ^OSStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, NSInteger bus, UInt32 frames, const AudioBufferList *input, void *context, RTCAudioDeviceRenderRecordedDataBlock render) { return noErr; };
}

- (RTCAudioDeviceGetPlayoutDataBlock)getPlayoutData {
    __weak SNTestAudioDelegate *weakSelf = self;
    return ^OSStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, NSInteger bus, UInt32 frames, AudioBufferList *output) {
        memset(output->mBuffers[0].mData, 0, output->mBuffers[0].mDataByteSize);
        weakSelf.pulledFrames += frames;
        return noErr;
    };
}

- (double)preferredInputSampleRate { return 48000; }
- (double)preferredOutputSampleRate { return 48000; }
- (NSTimeInterval)preferredInputIOBufferDuration { return 0.01; }
- (NSTimeInterval)preferredOutputIOBufferDuration { return 0.01; }
- (void)notifyAudioInputParametersChange {}
- (void)notifyAudioOutputParametersChange {}
- (void)notifyAudioInputInterrupted {}
- (void)notifyAudioOutputInterrupted {}
- (void)dispatchAsync:(dispatch_block_t)block { dispatch_async(dispatch_get_main_queue(), block); }
- (void)dispatchSync:(dispatch_block_t)block { block(); }

@end

/// Whether Core Audio counts this process as using an input (`input`) or output device now.
static BOOL ProcessRunsAudio(BOOL input) {
    pid_t pid = getpid();
    AudioObjectID process = kAudioObjectUnknown;
    UInt32 size = sizeof process;
    AudioObjectPropertyAddress translate = {kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &translate, sizeof pid, &pid, &size, &process) || process == kAudioObjectUnknown) return NO;
    UInt32 running = 0;
    size = sizeof running;
    AudioObjectPropertyAddress address = {input ? kAudioProcessPropertyIsRunningInput : kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return !AudioObjectGetPropertyData(process, &address, 0, NULL, &size, &running) && running;
}

SN_TEST(CallVoiceDevicePlaysWithoutTheMicrophone) {
    SNVoiceDevice *device = [SNVoiceDevice new];
    SNTestAudioDelegate *delegate = [SNTestAudioDelegate new];
    SNExpect([device initializeWithDelegate:delegate] && device.isInitialized, "libwebrtc's delegate taken");
    SNExpect(device.deviceOutputSampleRate == 48000 && device.outputNumberOfChannels == 1 && device.inputNumberOfChannels == 1, "48 kHz mono out, mono in");
    SNExpect([device initializePlayout] && [device startPlayout] && device.isPlaying, "playout starts");
    SNExpect(SNWaitUntil(3, ^BOOL { return delegate.pulledFrames >= 4800; }), "the engine pulls libwebrtc's samples");
    SNExpect(ProcessRunsAudio(NO) && !ProcessRunsAudio(YES), "playing, with the microphone closed");
    [device stopPlayout];
    NSUInteger pulled = delegate.pulledFrames;
    SNSettle(0.1);
    SNExpect(delegate.pulledFrames == pulled && !device.isPlaying, "stopping playout stops pulling");
    SNExpect([device terminateDevice] && !device.isInitialized, "terminated");
}

#endif
