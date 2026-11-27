// Immutable Spotify playback, queue, and Connect cluster models with protobuf decoders.
#import <Foundation/Foundation.h>

#import "model/device.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPRepeatMode) {
    SPRepeatOff = 0,
    SPRepeatContext = 1,
    SPRepeatTrack = 2,
};

SPRepeatMode SPRepeatModeNext(SPRepeatMode mode);

@interface SPQueueTrack : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *uri;
@property (nonatomic, readonly, copy, nullable) NSString *trackID;
@property (nonatomic, readonly, copy) NSString *uid;
@property (nonatomic, readonly, copy) NSString *provider;
@property (nonatomic, readonly) BOOL isHidden;
@property (nonatomic, readonly) BOOL isDelimiter;

- (instancetype)initWithURI:(NSString *)uri
                        uid:(NSString *)uid
                   provider:(NSString *)provider
                   isHidden:(BOOL)isHidden NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPPlaybackState : NSObject <NSCopying>
@property (nonatomic, readonly, copy, nullable) NSString *activeDeviceID;
@property (nonatomic, readonly, copy, nullable) NSString *contextURI;
@property (nonatomic, readonly, copy, nullable) NSString *contextName;
@property (nonatomic, readonly, copy, nullable) NSString *currentTrackURI;
@property (nonatomic, readonly, copy, nullable) NSString *currentTrackID;
@property (nonatomic, readonly) int64_t timestampMs;
@property (nonatomic, readonly) int64_t positionAsOfTimestampMs;
@property (nonatomic, readonly) int64_t durationMs;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) BOOL shuffling;
@property (nonatomic, readonly) SPRepeatMode repeatMode;
@property (nonatomic, readonly) BOOL canSkipNext;
@property (nonatomic, readonly) BOOL canShuffle;
@property (nonatomic, readonly) BOOL canRepeatContext;
@property (nonatomic, readonly) BOOL canRepeatTrack;
@property (nonatomic, readonly, copy) NSArray<SPQueueTrack *> *prevTracks;
@property (nonatomic, readonly, copy) NSArray<SPQueueTrack *> *nextTracks;

- (instancetype)initWithActiveDeviceID:(nullable NSString *)activeDeviceID
                            contextURI:(nullable NSString *)contextURI
                           contextName:(nullable NSString *)contextName
                       currentTrackURI:(nullable NSString *)currentTrackURI
                           timestampMs:(int64_t)timestampMs
               positionAsOfTimestampMs:(int64_t)positionAsOfTimestampMs
                            durationMs:(int64_t)durationMs
                             isPlaying:(BOOL)isPlaying
                              isPaused:(BOOL)isPaused
                             shuffling:(BOOL)shuffling
                            repeatMode:(SPRepeatMode)repeatMode
                           canSkipNext:(BOOL)canSkipNext
                            canShuffle:(BOOL)canShuffle
                      canRepeatContext:(BOOL)canRepeatContext
                        canRepeatTrack:(BOOL)canRepeatTrack
                            prevTracks:(NSArray<SPQueueTrack *> *)prevTracks
                            nextTracks:(NSArray<SPQueueTrack *> *)nextTracks NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Interpolates current position at `nowMs` when playing, clamped to `[0, durationMs]`.
- (int64_t)interpolatedPositionMsAt:(int64_t)nowMs;

+ (instancetype)playbackStateFromProtobufData:(NSData *)data activeDeviceID:(nullable NSString *)activeDeviceID;
@end

@interface SPClusterState : NSObject
@property (nonatomic, readonly, copy, nullable) NSString *activeDeviceID;
/// Visible devices suitable for a Speakers list (hidden devices excluded).
@property (nonatomic, readonly, copy) NSArray<SPDevice *> *devices;
/// Every device in the cluster including hidden observers.
@property (nonatomic, readonly, copy) NSArray<SPDevice *> *allDevices;
@property (nonatomic, readonly, nullable) SPPlaybackState *playbackState;

- (instancetype)initWithActiveDeviceID:(nullable NSString *)activeDeviceID
                            allDevices:(NSArray<SPDevice *> *)allDevices
                         playbackState:(nullable SPPlaybackState *)playbackState NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (instancetype)clusterFromProtobufData:(NSData *)data;
+ (instancetype)clusterUpdateFromProtobufData:(NSData *)data;
@end

NS_ASSUME_NONNULL_END
