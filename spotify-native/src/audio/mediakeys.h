// macOS Media Keys & Control Center bridge (MPNowPlayingInfoCenter + MPRemoteCommandCenter).
#import <Foundation/Foundation.h>

#import "audio/engine.h"
#import "model/playback.h"
#import "model/track.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPMediaKeysBridge : NSObject
@property (nonatomic, weak, nullable) id<SPAudioEngine> engine;

- (instancetype)initWithEngine:(id<SPAudioEngine>)engine NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Registers MPRemoteCommandCenter handlers (play, pause, toggle, next, prev, seek).
- (void)activate;
- (void)deactivate;

/// Updates MPNowPlayingInfoCenter with current playback state and track metadata.
- (void)updateNowPlayingWithState:(nullable SPPlaybackState *)state track:(nullable SPTrack *)track;

/// Pure dictionary builder (exposed for headless unit testing).
+ (NSDictionary<NSString *, id> *)nowPlayingInfoForState:(nullable SPPlaybackState *)state
                                                   track:(nullable SPTrack *)track
                                                   nowMs:(int64_t)nowMs;

/// Marshals a remote-command action onto the main queue before invoking the audio engine (exposed for unit tests).
- (void)dispatchRemoteCommand:(void (^)(id<SPAudioEngine> engine))action;
@end

NS_ASSUME_NONNULL_END
