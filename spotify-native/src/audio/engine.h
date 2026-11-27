// Unified audio playback protocol shared by SPFairPlayEngine (primary) and SPSoloistEngine (fallback).
#import <Foundation/Foundation.h>

#import "model/playback.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPAudioEngineKind) {
    SPAudioEngineKindFairPlay = 0,
    SPAudioEngineKindSoloist = 1,
};

typedef NS_ENUM(NSInteger, SPAudioEngineStatus) {
    SPAudioEngineStatusIdle = 0,
    SPAudioEngineStatusStarting,
    SPAudioEngineStatusWaitingForPairing,
    SPAudioEngineStatusReady,
    SPAudioEngineStatusPlaying,
    SPAudioEngineStatusPaused,
    SPAudioEngineStatusFailed,
};

/// Song Radio continuation helper: returns `[clickedTrackURI] + deduped radio tracks` (excluding clicked track),
/// falling back to `fallbackURIs` (excluding clicked track) when radio returns no additional tracks.
NSArray<NSString *> *SPTrackWithRecommendations(NSString *trackURI,
                                                NSArray<NSString *> *_Nullable radioURIs,
                                                NSArray<NSString *> *_Nullable fallbackURIs);

@protocol SPAudioEngine;

@protocol SPAudioEngineDelegate <NSObject>
@optional
- (void)audioEngine:(id<SPAudioEngine>)engine didUpdatePlaybackState:(SPPlaybackState *)state;
- (void)audioEngine:(id<SPAudioEngine>)engine didChangeStatus:(SPAudioEngineStatus)status error:(nullable NSError *)error;
@end

@protocol SPAudioEngine <NSObject>
@property (nonatomic, readonly) SPAudioEngineKind kind;
@property (nonatomic, readonly) SPAudioEngineStatus status;
@property (nonatomic, readonly) NSInteger volumePercent;
@property (nonatomic, readonly, nullable) SPPlaybackState *playbackState;
@property (nonatomic, weak, nullable) id<SPAudioEngineDelegate> delegate;

- (void)startWithCompletion:(nullable void (^)(NSError *_Nullable error))completion;
- (void)stop;

- (void)playTrackURI:(NSString *)trackURI
        inContextURI:(nullable NSString *)contextURI
          trackIndex:(NSInteger)trackIndex
          completion:(nullable void (^)(NSError *_Nullable error))completion;
- (void)playTrackURIs:(NSArray<NSString *> *)trackURIs
           completion:(nullable void (^)(NSError *_Nullable error))completion;
/// Plays a standalone clicked track (e.g. search result) followed immediately by its Song Radio tracks,
/// falling back to `fallbackURIs` if radio resolution fails or returns empty.
- (void)playTrackURIWithRadio:(NSString *)trackURI
                 fallbackURIs:(nullable NSArray<NSString *> *)fallbackURIs
                   completion:(nullable void (^)(NSError *_Nullable error))completion;

- (void)pause;
- (void)resume;
- (void)togglePlayPause;
- (void)skipNext;
- (void)skipPrevious;
- (void)seekToMs:(int64_t)positionMs;
- (void)setVolumePercent:(NSInteger)percent;
- (void)setShuffle:(BOOL)enabled;
- (void)setRepeatMode:(SPRepeatMode)mode;
- (void)enqueueTrackURI:(NSString *)trackURI;
/// Jumps non-destructively to the 0-based index inside `playbackState.nextTracks` (preserving the rest of the queue).
- (void)skipToQueueIndex:(NSInteger)queueIndex;
@end

NS_ASSUME_NONNULL_END
