// Spotify Connect dealer WebSocket + connect-state REST/protobuf client.
#import <Foundation/Foundation.h>

#import "auth/auth.h"
#import "model/device.h"
#import "model/playback.h"
#import "net/client.h"
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

/// Returns this Mac's sharing computer name (`scutil` / SCDynamicStore), falling back to hostname.
NSString *SPComputerDeviceName(void);

/// Streams gzip decompression (arbitrary size). Returns input unchanged if not gzip-formatted.
NSData *_Nullable SPGunzipData(NSData *data);

/// Encodes a Connect `PutStateRequest` protobuf payload (with optional `Device.player_state`).
NSData *SPConnectBuildPutStateProtobufWithPlayerState(NSString *deviceID,
                                                      NSString *deviceName,
                                                      BOOL canBePlayer,
                                                      BOOL hidden,
                                                      BOOL isActive,
                                                      uint32_t volume,
                                                      uint64_t timestampMs,
                                                      SPPlaybackState *_Nullable playerState);
NSData *SPConnectBuildPutStateProtobuf(NSString *deviceID,
                                       NSString *deviceName,
                                       BOOL canBePlayer,
                                       BOOL hidden,
                                       BOOL isActive,
                                       uint32_t volume,
                                       uint64_t timestampMs);

@class SPConnectClient;

@protocol SPConnectClientDelegate <NSObject>
@optional
- (void)connectClient:(SPConnectClient *)client didUpdateCluster:(SPClusterState *)cluster;
- (void)connectClient:(SPConnectClient *)client didChangeConnected:(BOOL)connected;
/// Return YES if the command was recognized and dispatched; NO sends success:false ACK to dealer.
- (BOOL)connectClient:(SPConnectClient *)client didReceiveCommandPayload:(NSDictionary *)command;
@end

@interface SPConnectClient : NSObject
@property (nonatomic, weak, nullable) id<SPConnectClientDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *deviceID;
@property (nonatomic, copy) NSString *deviceName;
/// YES when FairPlay engine plays locally on this Mac; NO (hidden observer) when Soloist is the visible speaker.
@property (nonatomic) BOOL canBePlayer;
@property (nonatomic) BOOL hidden;
@property (nonatomic, readonly, copy, nullable) NSString *connectionID;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) NSUInteger reconnectAttempts;

/// Optional override for dealer WebSocket endpoint (e.g. `ws://127.0.0.1:<port>/` in offline tests).
@property (nonatomic, copy, nullable) NSURL *dealerWebSocketURL;
@property (nonatomic) NSTimeInterval pingInterval;
@property (nonatomic) NSTimeInterval pongTimeout;
@property (nonatomic) NSTimeInterval heartbeatInterval;
@property (nonatomic) NSTimeInterval baseReconnectDelay;

- (instancetype)initWithAuth:(SPAuth *)auth
                   netClient:(SPNetClient *)netClient
                       store:(SPStore *)store NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)connect;
- (void)disconnect;

/// Registers or refreshes this device's PutState against connect-state and adopts the returned cluster.
- (void)publishDeviceStateActive:(BOOL)active
                          volume:(uint32_t)volume
                      completion:(nullable void (^)(SPClusterState *_Nullable cluster, NSError *_Nullable error))completion;
- (void)publishDeviceStateActive:(BOOL)active
                          volume:(uint32_t)volume
                   playbackState:(nullable SPPlaybackState *)playbackState
                      completion:(nullable void (^)(SPClusterState *_Nullable cluster, NSError *_Nullable error))completion;

// Remote Spotify Connect commands
- (SPCancelToken *)transferPlaybackToDeviceID:(NSString *)targetDeviceID
                                   completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)setVolumePercent:(NSInteger)percent
                         onDeviceID:(NSString *)targetDeviceID
                         completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)sendPlayerCommand:(NSDictionary *)command
                          toDeviceID:(NSString *)targetDeviceID
                          completion:(nullable void (^)(NSError *_Nullable error))completion;

- (SPCancelToken *)pauseOnDeviceID:(NSString *)deviceID completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)resumeOnDeviceID:(NSString *)deviceID completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)skipNextOnDeviceID:(NSString *)deviceID completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)skipNextToTrackURI:(NSString *)trackURI
                                  uid:(nullable NSString *)uid
                           onDeviceID:(NSString *)deviceID
                           completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)skipPrevOnDeviceID:(NSString *)deviceID completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)seekToMs:(int64_t)positionMs onDeviceID:(NSString *)deviceID completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)setShuffle:(BOOL)enabled onDeviceID:(NSString *)deviceID completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)setRepeatMode:(SPRepeatMode)mode onDeviceID:(NSString *)deviceID completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)playContextURI:(NSString *)contextURI
               startingAtTrackURI:(nullable NSString *)trackURI
                       trackIndex:(NSInteger)trackIndex
                       onDeviceID:(NSString *)deviceID
                       completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)playTrackURIs:(NSArray<NSString *> *)trackURIs
                      onDeviceID:(NSString *)deviceID
                      completion:(nullable void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)addToQueueTrackURI:(NSString *)trackURI
                           onDeviceID:(NSString *)deviceID
                           completion:(nullable void (^)(NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
