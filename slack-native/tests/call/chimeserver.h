// A Chime signalling server on 127.0.0.1 for the call tests, on SNTestSocketServer: it decodes what
// the client sends and answers as Chime does (JOIN with JOIN_ACK then INDEX, SUBSCRIBE with
// SUBSCRIBE_ACK, PING with PONG, LEAVE with LEAVE_ACK), and pushes what the audio host reports.
// Main queue.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNTestChimeServer : NSObject
/// Listening on a free port; nil when the listener could not start.
+ (nullable instancetype)start;
/// The meeting's SignalingUrl (ws://127.0.0.1:<port>/control/<made-up meeting>).
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) NSUInteger connectionCount;
/// Each connection's handshake headers (SNTestSocketServer's handshakes).
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *handshakes;
/// Every frame received, oldest first, decoded with the proto's field names:
/// @{@"type": @"SUBSCRIBE", @"timestamp_ms": @…, @"sub": @{@"sdp_offer": …, @"send_streams": @[…]}}.
/// A field the decoder does not know shows as @"field<number>".
@property (nonatomic, readonly) NSArray<NSDictionary *> *received;
- (NSArray<NSDictionary *> *)receivedOfType:(NSString *)type;
/// JOIN_ACK's turn_credentials: @{@"username", @"password", @"ttl", @"uris"}; nil sends none.
@property (nonatomic, copy, nullable) NSDictionary *turn;
/// Makes SUBSCRIBE_ACK's answer for the offer and hands it to `reply` (at any time). nil answers
/// with a fixed SDP at once.
@property (nonatomic, copy, nullable) void (^answerOffer)(NSString *offer, void (^reply)(NSString *answer));
/// Each YES at first.
@property (nonatomic) BOOL answersJoin, answersPings, acksLeave;
/// AUDIO_STREAM_ID_INFO; each stream @{@"audio_stream_id", @"attendee_id", @"external_user_id",
/// @"muted", @"dropped"}, keys left out are not sent.
- (void)sendStreams:(NSArray<NSDictionary *> *)streams;
/// AUDIO_METADATA; each @{@"audio_stream_id", @"volume", @"signal_strength"}, as above.
- (void)sendLevels:(NSArray<NSDictionary *> *)levels;
- (void)sendAudioStatus:(uint32_t)status;
/// A NOTIFICATION frame carrying an SdkErrorFrame with `status`.
- (void)sendErrorStatus:(uint32_t)status;
/// A PING from the server.
- (void)sendPing:(uint32_t)pingID;
- (void)closeWithCode:(uint16_t)code;
/// Drops the connection without a close frame.
- (void)dropConnection;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
