// The real-time connection: Slack's websocket (flannel) for one workspace. Asks
// client.getWebSocketURL for where to connect (every time: reconnect_url frames are not kept),
// signs the handshake with the session (the same cookie jar as HTTP), keeps the connection alive
// with pings, notices a dead one (missed pongs, silence, sleep) and reconnects with backoff until
// stopped. Frames are parsed off the main thread; events go out on the main thread.
#import <Foundation/Foundation.h>

#import "source/source.h"
#import "net/api.h"
#import "net/session.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNLiveClient : NSObject
/// `api` answers client.getWebSocketURL; `session` signs the handshake and holds the team's
/// xoxc; `urlSession` is the app's one NSURLSession (shared with HTTP).
- (instancetype)initWithAPI:(id<SNAPI>)api session:(SNSession *)session teamID:(NSString *)teamID urlSession:(NSURLSession *)urlSession;
/// Connects, and keeps reconnecting until -stop.
- (void)start;
- (void)stop;
@property (nonatomic, readonly) SNConnectionState state;
/// Every event frame except hello, pong, reconnect_url, goodbye and error, in order, on the main
/// thread.
@property (nonatomic, copy, nullable) void (^onEvent)(NSDictionary *event);
/// After each hello: `fastReconnect` is hello's fast_reconnect (the server replayed what was
/// missed); sync gap-fills when NO.
@property (nonatomic, copy, nullable) void (^onConnect)(BOOL fastReconnect);
@property (nonatomic, copy, nullable) void (^onStateChange)(SNConnectionState state);
/// User IDs to subscribe presence for; sent as presence_sub {ids} after every hello
/// (batch_presence_aware: Slack sends presence only for subscribed users).
@property (nonatomic, copy, nullable) NSArray<NSString *> *_Nullable (^presenceUserIDs)(void);
/// Sends a frame with the next "id"; NO when not connected, when its JSON is over 16 KB (Slack
/// disconnects on those) or for typing in read-only mode (net/switches.h).
- (BOOL)sendFrame:(NSDictionary *)frame;
/// Pings every pingInterval (20 s); the connection is dropped after 2 unanswered pings or
/// silenceTimeout (50 s) without any frame, checked by wall clock so a timer firing late after
/// sleep catches it, and again at wake. Reconnects back off from backoffBase (1 s) doubling to
/// backoffMax (30 s) with jitter; the backoff resets after stableAfter (30 s) connected.
@property (nonatomic) NSTimeInterval pingInterval, silenceTimeout, backoffBase, backoffMax, stableAfter;
@end

/// The delay before reconnect attempt `attempt` (0-based): between half and all of
/// min(base * 2^attempt, max), so many clients dropped together do not return together.
NSTimeInterval SNLiveBackoff(NSInteger attempt, NSTimeInterval base, NSTimeInterval max);
/// The websocket URL for client.getWebSocketURL's primary_websocket_url and routing_context,
/// with the web client's query (notes/protocol.txt REAL-TIME); nil unless ws or wss.
NSURL *_Nullable SNLiveURL(NSString *primaryURL, NSString *_Nullable routingContext, NSString *token);

NS_ASSUME_NONNULL_END
