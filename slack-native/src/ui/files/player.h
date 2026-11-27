// One AVPlayer for a video or audio file, made when the reader presses play and released as soon
// as its view leaves the screen: nothing streams, decodes or ticks for files nobody plays.
#import <AVFoundation/AVFoundation.h>

#import "model/message.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNMediaPlayer : NSObject
/// nil when the file cannot be streamed (no URL, or no credentials: fixture runs).
+ (nullable instancetype)playerForFile:(SNFile *)file;
@property (nonatomic, readonly) AVPlayer *player;
@property (nonatomic, readonly, getter=isPlaying) BOOL playing;
@property (nonatomic, readonly) NSTimeInterval currentTime;
/// The file's own length until the stream knows better.
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, getter=isMuted) BOOL muted;
/// The playback speed (Slack offers 0.25 to 2), kept while paused.
@property (nonatomic) float rate;
- (void)play;
- (void)pause;
- (void)seekToFraction:(double)fraction;
- (void)seekToTime:(NSTimeInterval)time;
/// Called on the main thread a few times a second while playing, and on every change of state
/// (play, pause, seek, the end).
@property (nonatomic, copy, nullable) void (^onChange)(SNMediaPlayer *player);
@end

NS_ASSUME_NONNULL_END
