// Loopback HTTP/1.1 + RFC 6455 WebSocket mock server on 127.0.0.1:<ephemeral-port> for offline tests.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPMockRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers; // lowercased keys
@property (nonatomic, copy) NSData *body;
- (nullable NSDictionary *)jsonBody;
- (nullable NSString *)bodyString;
@end

@interface SPMockResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSData *body;
@property (nonatomic) NSTimeInterval delaySeconds;
+ (instancetype)responseWithStatus:(NSInteger)status json:(id)jsonObject;
+ (instancetype)responseWithStatus:(NSInteger)status contentType:(NSString *)contentType data:(NSData *)data;
@end

/// Loopback HTTP server. Handlers execute on a background queue.
@interface SPMockHTTPServer : NSObject
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) NSURL *baseURL;
@property (nonatomic, copy, nullable) SPMockResponse *(^handler)(SPMockRequest *req);
@property (nonatomic, readonly) NSArray<SPMockRequest *> *recordedRequests;

- (BOOL)start;
- (void)stop;
- (NSURL *)urlForPath:(NSString *)path;
@end

/// Loopback RFC 6455 WebSocket server for offline Spotify Connect dealer testing.
@interface SPMockWebSocketServer : NSObject
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) NSURL *wsURL;
@property (nonatomic, readonly, copy, nullable) NSString *lastRequestPath;
@property (nonatomic, readonly) NSArray<NSString *> *receivedTextFrames;
@property (nonatomic, readonly) BOOL hasClient;

- (BOOL)start;
- (void)stop;
- (BOOL)sendTextFrame:(NSString *)text;
- (void)closeClient;
@end

NS_ASSUME_NONNULL_END
