// A websocket server on 127.0.0.1 for the live client's tests (Network.framework), speaking
// Slack's frames as far as the tests need. Everything runs on the main queue.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNTestSocketServer : NSObject
/// Listening on a free port; nil when the listener could not start within a second.
+ (nullable instancetype)start;
@property (nonatomic, readonly) uint16_t port;
/// ws://127.0.0.1:<port>/
@property (nonatomic, readonly) NSString *url;
/// Sent to every new connection (nil: nothing).
@property (nonatomic, copy, nullable) NSDictionary *helloFrame;
/// Answers {"type":"ping","id":n} with {"type":"pong","reply_to":n} (default YES).
@property (nonatomic) BOOL answersPings;
@property (nonatomic, readonly) NSUInteger connectionCount;
/// Accepted when a client offers it, and named in the handshake's answer (nil: none).
@property (nonatomic, copy, nullable) NSString *subprotocol;
/// The handshake headers of each connection, lowercased names; the subprotocols offered are
/// under "sec-websocket-protocol", comma separated.
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *handshakes;
/// Frames received from clients, all connections, oldest first.
@property (nonatomic, readonly) NSArray<NSDictionary *> *received;
/// Binary messages from clients, which then are not in `received`.
@property (nonatomic, copy, nullable) void (^onData)(NSData *message);
/// To the newest connection.
- (void)send:(NSDictionary *)frame;
/// A binary message to the newest connection.
- (void)sendData:(NSData *)message;
/// Closes the newest connection with a close frame carrying `code`.
- (void)closeWithCode:(uint16_t)code;
/// Drops the newest connection without a close frame.
- (void)dropConnection;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
