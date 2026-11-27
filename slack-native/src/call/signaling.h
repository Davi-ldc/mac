// The Amazon Chime signalling connection of one call, as the official client's Chime SDK speaks it:
// a websocket to the meeting's SignalingUrl carrying protobuf SdkSignalFrames
// (call/frames.h). It joins, hands over the offer and gets the answer, mutes, reports who is
// heard and leaves. Everything runs and calls back on the main thread.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// JOIN_ACK's turn_credentials.
@interface SNChimeTURN : NSObject
@property (nonatomic, copy) NSString *username, *password;
@property (nonatomic, copy) NSArray<NSString *> *uris;
@property (nonatomic) NSTimeInterval ttl;
@end

/// One attendee as the audio host reports them (AUDIO_STREAM_ID_INFO names the streams,
/// AUDIO_METADATA gives their levels), merged by audio stream ID.
@interface SNChimeAttendee : NSObject
@property (nonatomic, copy) NSString *attendeeID;
@property (nonatomic, copy, nullable) NSString *externalUserID;
/// 0 (silent) to 1, as Chime's volume indicator normalizes it.
@property (nonatomic) double volume, signalStrength;
@property (nonatomic) BOOL muted;
/// Left the meeting, or their connection dropped.
@property (nonatomic) BOOL gone;
@end

/// onClose's errors. Any other code is Chime's: a status (an error frame's, or AUDIO_STATUS's: 410
/// the meeting ended, 411 the attendee was removed, 301 they joined from another device) or the
/// websocket's close code (4410 the meeting ended, 4500-4599 a server failure).
extern NSErrorDomain const SNChimeErrorDomain;
typedef NS_ERROR_ENUM(SNChimeErrorDomain, SNChimeError) {
    /// SNChimeMissedPongLimit pings in a row went unanswered.
    SNChimeErrorNoPongs = 1,
    /// The answer came only compressed (JOIN never asks for compression).
    SNChimeErrorProtocol = 2,
    /// The connection died without a close code (what a browser reports as 1006).
    SNChimeErrorDropped = 1006,
};
/// After this many unanswered pings Chime's client counts the connection lost.
static const NSInteger SNChimeMissedPongLimit = 4;

/// The websocket URL for a SignalingUrl, with the query Chime's client adds.
NSURL *SNChimeSignalingURL(NSURL *signalingURL);

@interface SNChimeSignaling : NSObject
/// `url` is the meeting's MediaPlacement.SignalingUrl, `joinToken` the attendee's JoinToken.
- (instancetype)initWithURL:(NSURL *)url joinToken:(NSString *)joinToken urlSession:(NSURLSession *)urlSession;
/// The attendee's AttendeeId: SUBSCRIBE describes the audio it sends as theirs. Set before
/// subscribing.
@property (nonatomic, copy, nullable) NSString *attendeeID;
/// Seconds between pings (Chime's client: 10).
@property (nonatomic) NSTimeInterval pingInterval;
/// Opens the websocket and sends JOIN; onJoined gets JOIN_ACK's TURN credentials (nil when it had
/// none) once the first INDEX followed, as Chime's client waits for it before subscribing.
- (void)start;
@property (nonatomic, copy, nullable) void (^onJoined)(SNChimeTURN *_Nullable turn);
/// SUBSCRIBE with the local offer, sending audio to `audioHost` (MediaPlacement.AudioHostUrl).
- (void)subscribeWithOffer:(NSString *)sdp audioHost:(NSString *)audioHost muted:(BOOL)muted;
/// SUBSCRIBE_ACK's SDP answer.
@property (nonatomic, copy, nullable) void (^onAnswer)(NSString *sdp);
/// AUDIO_CONTROL.
- (void)setMuted:(BOOL)muted;
/// Attendees whose state changed.
@property (nonatomic, copy, nullable) void (^onAttendees)(NSArray<SNChimeAttendee *> *attendees);
/// The connection failed or closed without leaving (an error frame, a close, no pongs).
@property (nonatomic, copy, nullable) void (^onClose)(NSError *_Nullable error);
/// LEAVE, then LEAVE_ACK or `timeout`, then the socket closes; `completion` gets whether Chime
/// acknowledged. Also works on a connection that never joined (a leave recovered at launch).
- (void)leaveWithin:(NSTimeInterval)timeout completion:(nullable void (^)(BOOL acknowledged))completion;
@end

NS_ASSUME_NONNULL_END
