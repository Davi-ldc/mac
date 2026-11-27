// An in-process stand-in for Chime's audio host in tests: a libwebrtc peer connection of its own,
// on the loopback interface only, that answers a call's offer, plays a tone into the call and
// measures what it hears. Only in builds with libwebrtc (SN_WEBRTC). Main thread.
#import <Foundation/Foundation.h>

#import "tonedevice.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNTestAudioHost : NSObject
/// Plays a sine of `frequency` Hz into the call.
- (instancetype)initWithFrequency:(double)frequency;
/// What it records (its tone) and what it hears from the call (playedLevel, playedFrequency).
@property (nonatomic, readonly) SNToneDevice *device;
/// Answers SUBSCRIBE's offer as the audio host: audio both ways, video refused, its candidates
/// gathered into the answer.
- (void)answerOffer:(NSString *)offer completion:(void (^)(NSString *_Nullable answer, NSError *_Nullable error))completion;
/// Its peer connection reached the call.
@property (nonatomic, readonly) BOOL connected;
- (void)close;
@end

NS_ASSUME_NONNULL_END
