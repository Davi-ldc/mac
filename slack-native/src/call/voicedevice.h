// The Mac's microphone and output for calls: an audio device for libwebrtc (call/audiodevice.h) on
// AVAudioEngine with voice processing, whose echo cancellation hears what the call plays. The
// microphone opens only while libwebrtc records.
#import "call/audiodevice.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNVoiceDevice : NSObject <RTCAudioDevice>
@end

NS_ASSUME_NONNULL_END
