// Chime's SdkSignalFrame (SignalingProtocol.proto, Apache-2.0) as an audio-only client uses it:
// the frames it sends, encoded as the Chime SDK JS 3.32.0 that Slack ships fills them, and the
// fields it reads from the frames it receives. On the websocket every frame is one binary
// message: a type byte (SNChimeFrameTypeRTC) and the encoded SdkSignalFrame.
#import <Foundation/Foundation.h>

#import "call/signaling.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, SNChimeFrameType) {
    SNChimeFrameJoin = 1,
    SNChimeFrameJoinAck = 2,
    SNChimeFrameSubscribe = 3,
    SNChimeFrameSubscribeAck = 4,
    SNChimeFrameIndex = 5,
    SNChimeFrameLeave = 9,
    SNChimeFrameLeaveAck = 10,
    SNChimeFrameBitrates = 13,
    SNChimeFrameAudioControl = 16,
    SNChimeFrameAudioMetadata = 17,
    SNChimeFrameAudioStreamIDInfo = 18,
    SNChimeFramePingPong = 19,
    SNChimeFrameAudioStatus = 20,
    SNChimeFrameNotification = 34,
};

/// The byte before every frame on the websocket.
static const uint8_t SNChimeFrameTypeRTC = 5;

/// The frame's name in the trace ("JOIN_ACK"), or its number.
NSString *SNChimeFrameName(SNChimeFrameType type);

/// JOIN's SdkClientDetails, written in field order; nil fields are left out.
@interface SNChimeClientDetails : NSObject
@property (nonatomic, copy, nullable) NSString *platformName, *platformVersion, *clientSource, *sdkVersion, *utcOffset, *osName, *osVersion;
/// What this Mac reports.
+ (instancetype)current;
@end

/// "-03:00" for a zone 3 hours behind UTC, as the SDK's getFormattedOffset.
NSString *SNChimeUTCOffset(NSTimeZone *zone, NSDate *date);

// The client's frames, each a whole websocket message (type byte included). `timestamp` is
// SdkSignalFrame.timestamp_ms (Unix milliseconds).

NSData *SNChimeJoinMessage(uint64_t timestamp, uint32_t audioSessionID, SNChimeClientDetails *details);
/// Audio sent to and received from `audioHost`, the offer uncompressed (JOIN does not ask for
/// compression).
NSData *SNChimeSubscribeMessage(uint64_t timestamp, NSString *sdpOffer, NSString *audioHost, NSString *attendeeID, BOOL muted);
NSData *SNChimeAudioControlMessage(uint64_t timestamp, BOOL muted);
NSData *SNChimePingPongMessage(uint64_t timestamp, uint32_t pingID, BOOL pong);
NSData *SNChimeLeaveMessage(uint64_t timestamp);

/// One AUDIO_STREAM_ID_INFO entry.
@interface SNChimeStreamInfo : NSObject
@property (nonatomic, readonly) uint32_t audioStreamID;
@property (nonatomic, readonly, nullable) NSString *attendeeID, *externalUserID;
@property (nonatomic, readonly) BOOL hasMuted, muted, dropped;
@end

/// One AUDIO_METADATA attendee state, by audio stream.
@interface SNChimeAudioLevel : NSObject
@property (nonatomic, readonly) uint32_t audioStreamID;
/// Attenuation in dB below full scale (14 loud, 42 silent), and 0-2 bars.
@property (nonatomic, readonly) uint32_t volume, signalStrength;
@property (nonatomic, readonly) BOOL hasVolume, hasSignalStrength;
@end

/// A frame from the server, with the fields the client reads.
@interface SNChimeFrame : NSObject
/// From a websocket message (type byte included); nil when it does not decode.
+ (nullable instancetype)frameWithMessage:(NSData *)message;
@property (nonatomic, readonly) SNChimeFrameType type;
@property (nonatomic, readonly) uint64_t timestamp;
/// SdkErrorFrame, which may come with any frame (0: none).
@property (nonatomic, readonly) uint32_t errorStatus;
@property (nonatomic, readonly, nullable) NSString *errorDescription;
/// JOIN_ACK.
@property (nonatomic, readonly, nullable) SNChimeTURN *turn;
/// SUBSCRIBE_ACK; `compressedAnswer` when the answer came only compressed.
@property (nonatomic, readonly, nullable) NSString *sdpAnswer;
@property (nonatomic, readonly) BOOL compressedAnswer;
/// PING_PONG.
@property (nonatomic, readonly) BOOL isPong;
@property (nonatomic, readonly) uint32_t pingID;
/// AUDIO_STATUS (0 when the frame has none).
@property (nonatomic, readonly) uint32_t audioStatus;
@property (nonatomic, readonly) NSArray<SNChimeStreamInfo *> *streams;
@property (nonatomic, readonly) NSArray<SNChimeAudioLevel *> *levels;
/// NOTIFICATION's message.
@property (nonatomic, readonly, nullable) NSString *notification;
@end

/// Chime's volume indicator scale: 1 at 14 dB of attenuation or less, 0 at 42 or more.
double SNChimeNormalizedVolume(uint32_t volume);

NS_ASSUME_NONNULL_END
