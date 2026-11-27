// A synthetic audio device for calls in tests: it "records" a sine at 48 kHz mono and measures
// what libwebrtc plays out, paced by a timer instead of the Mac's microphone and speakers (so a
// test never opens the microphone).
#import "call/audiodevice.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNToneDevice : NSObject <RTCAudioDevice>
/// Records a sine of `frequency` Hz at half of full scale; 0 records silence.
- (instancetype)initWithFrequency:(double)frequency;
@property (atomic) double frequency;
/// Over the last 200 ms played out: root mean square as a fraction of full scale, and the dominant
/// frequency in Hz by zero crossings (0 when it is silent).
@property (nonatomic, readonly) double playedLevel, playedFrequency;
/// Frames handed to libwebrtc and taken from it so far.
@property (atomic, readonly) NSUInteger recordedFrames, playedFrames;
@end

NS_ASSUME_NONNULL_END
