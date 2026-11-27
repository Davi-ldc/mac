// libwebrtc's injectable audio device (RTCPeerConnectionFactory's
// initWithEncoderFactory:decoderFactory:audioDevice:). The macOS framework ships without its
// header, so the protocols are declared here with the selectors and block types its audio device
// module calls. Samples are 16-bit integers, interleaved, at the rates and channel counts the
// device reports; the module re-chunks them into 10 ms frames itself.
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef OSStatus (^RTCAudioDeviceGetPlayoutDataBlock)(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp, NSInteger inputBusNumber, UInt32 frameCount, AudioBufferList *outputData);
typedef OSStatus (^RTCAudioDeviceRenderRecordedDataBlock)(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp, NSInteger inputBusNumber, UInt32 frameCount, AudioBufferList *outputData, void *_Nullable renderContext);
typedef OSStatus (^RTCAudioDeviceDeliverRecordedDataBlock)(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp, NSInteger inputBusNumber, UInt32 frameCount, const AudioBufferList *_Nullable inputData, void *_Nullable renderContext, NS_NOESCAPE RTCAudioDeviceRenderRecordedDataBlock _Nullable renderBlock);

/// What libwebrtc hands the device: where recorded samples go and where played ones come from
/// (both safe to call from the device's real-time thread), and its own thread for the rest.
@protocol RTCAudioDeviceDelegate <NSObject>
@property (readonly) RTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData;
@property (readonly) double preferredInputSampleRate;
@property (readonly) NSTimeInterval preferredInputIOBufferDuration;
@property (readonly) double preferredOutputSampleRate;
@property (readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property (readonly) RTCAudioDeviceGetPlayoutDataBlock getPlayoutData;
/// The device's rate, channels or buffer changed: libwebrtc reads them again.
- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
/// On libwebrtc's audio device thread, where it calls the device.
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
@end

@protocol RTCAudioDevice <NSObject>
@property (readonly) double deviceInputSampleRate;
@property (readonly) NSTimeInterval inputIOBufferDuration;
@property (readonly) NSInteger inputNumberOfChannels;
@property (readonly) NSTimeInterval inputLatency;
@property (readonly) double deviceOutputSampleRate;
@property (readonly) NSTimeInterval outputIOBufferDuration;
@property (readonly) NSInteger outputNumberOfChannels;
@property (readonly) NSTimeInterval outputLatency;
@property (readonly) BOOL isInitialized;
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;
@property (readonly) BOOL isPlayoutInitialized;
- (BOOL)initializePlayout;
@property (readonly) BOOL isPlaying;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
@property (readonly) BOOL isRecordingInitialized;
- (BOOL)initializeRecording;
@property (readonly) BOOL isRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;
@end

NS_ASSUME_NONNULL_END
