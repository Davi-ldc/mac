// The live client against a local websocket server: handshake, hello, events, pings, liveness,
// fresh URLs after a drop, goodbye, frame size, stopping, the trace and read-only mode. Short timings keep the suite to a few seconds.
#import "live/live.h"
#import "net/switches.h"
#import "server.h"
#import "test.h"

/// Answers client.getWebSocketURL with the test server and counts the calls.
@interface SNTestLiveAPI : NSObject <SNAPI>
@property (nonatomic, copy) NSString *url;
@property (nonatomic) NSInteger calls;
@end

@implementation SNTestLiveAPI
- (void)call:(NSString *)method params:(NSDictionary *)params priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    if ([method isEqualToString:@"client.getWebSocketURL"]) self.calls++;
    NSDictionary *response = @{@"ok" : @YES, @"primary_websocket_url" : self.url, @"routing_context" : @"ctx-test"};
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(response, nil);
    });
}
- (void)callEdge:(NSString *)path body:(NSDictionary *)body priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {}
- (dispatch_block_t)upload:(NSURL *)file name:(NSString *)name mimeType:(NSString *)mimeType to:(NSURL *)url
                  progress:(void (^)(double))progress completion:(void (^)(NSInteger))completion {
    return ^{};
}
@end

static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) SNSettle(0.01);
    return condition();
}

static SNSession *TestSession(void) {
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : @"d", NSHTTPCookieValue : @"made-up%2Fcookie",
                                                                NSHTTPCookieDomain : @"127.0.0.1", NSHTTPCookiePath : @"/"}];
    SNSessionTeam *team = [SNSessionTeam teamWithJSON:@{@"id" : @"T0TEST", @"token" : @"xoxc-made-up", @"url" : @"https://example.invalid/"}];
    return [[SNSession alloc] initWithCookies:@[ cookie ] teams:@[ team ] userAgent:@"SlackNativeTest/1"];
}

/// A client on a fresh server with short timings; nil (and a note) when the test cannot run here.
static SNLiveClient *Client(SNTestSocketServer **server, SNTestLiveAPI **api) {
    *server = [SNTestSocketServer start];
    if (!*server) {
        printf("skip: no local listener\n");
        return nil;
    }
    (*server).helloFrame = @{@"type" : @"hello"};
    *api = [SNTestLiveAPI new];
    (*api).url = (*server).url;
    NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    SNLiveClient *client = [[SNLiveClient alloc] initWithAPI:*api session:TestSession() teamID:@"T0TEST" urlSession:urlSession];
    client.pingInterval = 0.2;
    client.silenceTimeout = 0.6;
    client.backoffBase = 0.05;
    client.backoffMax = 0.2;
    client.stableAfter = 10;
    return client;
}

/// Starts the client and waits for hello; NO when the connection never came up (reported).
static BOOL Connect(SNLiveClient *client) {
    [client start];
    if (WaitUntil(2, ^BOOL { return client.state == SNConnectionConnected; })) return YES;
    SNExpect(NO, "connects to the local server (ATS or the sandbox may block ws://127.0.0.1)");
    return NO;
}

SN_TEST(LiveBuildsTheWebSocketURL) {
    NSString *url = SNLiveURL(@"wss://wss-primary.example.invalid/?flag=1", @"ctx/1", @"xoxc-made-up").absoluteString;
    SNExpect([url hasPrefix:@"wss://wss-primary.example.invalid/?flag=1&token=xoxc-made-up&sync_desync=1&slack_client=desktop&start_args="],
             "the primary URL keeps its query and the token comes first");
    SNExpect([url containsString:@"start_args=?agent=client%26org_wide_aware=true%26eac_cache_ts=true%26cache_ts=0%26name_tagging=true"
                                 @"%26only_self_subteams=true%26connect_only=true%26ms_latest=true&"],
             "start_args is one value: its & escaped, ? and = kept");
    SNExpect([url hasSuffix:@"&no_query_on_subscribe=1&flannel=3&lazy_channels=1&gateway_server=ctx/1&batch_presence_aware=1"], "the rest in order");
    SNExpect(![SNLiveURL(@"wss://a.example.invalid/", nil, @"xoxc-1").absoluteString containsString:@"gateway_server"], "no routing context, no gateway_server");
    SNExpect(SNLiveURL(@"https://a.example.invalid/", nil, @"xoxc-1") == nil, "only ws and wss");
}

SN_TEST(LiveBacksOffWithJitter) {
    BOOL bounded = YES;
    for (NSInteger attempt = 0; attempt < 12; attempt++)
        for (int i = 0; i < 20; i++) {
            NSTimeInterval cap = MIN(pow(2, (double)attempt), 30), delay = SNLiveBackoff(attempt, 1, 30);
            bounded = bounded && delay >= cap / 2 && delay <= cap;
        }
    SNExpect(bounded, "each delay between half and all of min(base * 2^n, max)");
    SNExpect(SNLiveBackoff(40, 1, 30) <= 30 && SNLiveBackoff(40, 1, 30) >= 15, "capped for any attempt");
    NSTimeInterval spread = 0;
    for (int i = 0; i < 20; i++) spread = MAX(spread, fabs(SNLiveBackoff(3, 1, 30) - SNLiveBackoff(3, 1, 30)));
    SNExpect(spread > 0, "jitter varies");
}

SN_TEST(LiveConnectsAndSubscribesPresence) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    server.helloFrame = @{@"type" : @"hello", @"fast_reconnect" : @YES};
    NSMutableArray *states = [NSMutableArray new];
    __block NSNumber *fast = nil;
    client.onStateChange = ^(SNConnectionState state) { [states addObject:@(state)]; };
    client.onConnect = ^(BOOL fastReconnect) { fast = @(fastReconnect); };
    client.presenceUserIDs = ^NSArray<NSString *> * { return @[ @"U01", @"U02" ]; };
    if (!Connect(client)) return [server stop];
    SNExpect(([states isEqualToArray:@[ @(SNConnectionConnecting), @(SNConnectionConnected) ]]), "connecting, then connected at hello");
    SNExpect(fast.boolValue, "onConnect with hello's fast_reconnect");
    SNExpect(WaitUntil(1, ^BOOL { return server.received.count > 0; }), "a frame reached the server");
    NSDictionary *sub = server.received.firstObject;
    SNExpect([sub[@"type"] isEqual:@"presence_sub"] && [sub[@"ids"] isEqual:(@[ @"U01", @"U02" ])] && sub[@"id"], "presence_sub with the IDs, numbered");
    NSDictionary *headers = server.handshakes.firstObject;
    if (headers.count) {
        SNExpect([headers[@"cookie"] isEqualToString:@"d=made-up%2Fcookie"], "handshake sends the jar's cookie as stored");
        SNExpect([headers[@"origin"] isEqualToString:@"https://app.slack.com"], "handshake sends the web client's Origin");
        SNExpect([headers[@"user-agent"] isEqualToString:@"SlackNativeTest/1"], "handshake sends the session's user agent");
    } else printf("skip: Network.framework exposed no handshake headers\n");
    SNExpect(api.calls == 1, "one client.getWebSocketURL");
    [client stop];
    [server stop];
}

SN_TEST(LiveDeliversEventsInOrder) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    NSMutableArray<NSDictionary *> *events = [NSMutableArray new];
    client.onEvent = ^(NSDictionary *event) { [events addObject:event]; };
    if (!Connect(client)) return [server stop];
    [server send:@{@"type" : @"message", @"channel" : @"C1", @"ts" : @"1.000001"}];
    [server send:@{@"type" : @"pong", @"reply_to" : @99}];
    [server send:@{@"ok" : @YES, @"reply_to" : @3}];
    [server send:@{@"type" : @"user_typing", @"channel" : @"C1", @"user" : @"U02"}];
    [server send:@{@"type" : @"reconnect_url", @"url" : server.url}];
    [server send:@{@"type" : @"message", @"channel" : @"C1", @"ts" : @"1.000002"}];
    SNExpect(WaitUntil(1, ^BOOL { return events.count >= 3; }), "events arrive");
    SNSettle(0.05);
    NSArray *types = [events valueForKey:@"type"];
    SNExpect(([types isEqualToArray:@[ @"message", @"user_typing", @"message" ]]), "only events, none of the control frames or acks");
    SNExpect([events[2][@"ts"] isEqual:@"1.000002"], "in the order sent");
    [client stop];
    [server stop];
}

SN_TEST(LivePingsAndAnswersPings) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    if (!Connect(client)) return [server stop];
    BOOL (^pings)(void) = ^BOOL {
        NSUInteger count = 0;
        for (NSDictionary *frame in server.received) count += [frame[@"type"] isEqual:@"ping"];
        return count >= 3;
    };
    SNExpect(WaitUntil(1.5, pings), "pings every pingInterval");
    SNExpect(client.state == SNConnectionConnected && server.connectionCount == 1, "answered pings keep the connection");
    [server send:@{@"type" : @"ping", @"id" : @7}];
    SNExpect(WaitUntil(1, ^BOOL {
                 for (NSDictionary *frame in server.received)
                     if ([frame[@"type"] isEqual:@"pong"] && [frame[@"reply_to"] isEqual:@7]) return YES;
                 return NO;
             }),
             "a server ping is answered with reply_to");
    [client stop];
    [server stop];
}

SN_TEST(LiveDropsASilentConnection) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    server.answersPings = NO;
    __block NSInteger connects = 0;
    client.onConnect = ^(BOOL fast) { connects++; };
    if (!Connect(client)) return [server stop];
    NSDate *start = NSDate.date;
    SNExpect(WaitUntil(1.5, ^BOOL { return client.state == SNConnectionConnecting; }), "a silent connection is dropped");
    SNExpect(-start.timeIntervalSinceNow < client.silenceTimeout + 0.3, "within the silence allowed");
    SNExpect(WaitUntil(1.5, ^BOOL { return connects >= 2 && client.state == SNConnectionConnected; }), "and reconnects");
    SNExpect(server.connectionCount >= 2 && api.calls >= 2, "on a fresh connection from a fresh URL");
    [client stop];
    [server stop];
}

SN_TEST(LiveAsksForAFreshURLAfterADrop) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    if (!Connect(client)) return [server stop];
    [server send:@{@"type" : @"reconnect_url", @"url" : [server.url stringByAppendingString:@"stale"]}];
    SNSettle(0.05);
    [server dropConnection];
    SNExpect(WaitUntil(1.5, ^BOOL { return server.connectionCount == 2 && client.state == SNConnectionConnected; }), "reconnects after a drop");
    SNExpect(api.calls == 2, "through client.getWebSocketURL, not the reconnect_url kept from before the drop");
    [client stop];
    [server stop];
}

SN_TEST(LiveReconnectsAfterGoodbye) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    if (!Connect(client)) return [server stop];
    [server send:@{@"type" : @"reconnect_url", @"url" : server.url}];
    [server send:@{@"type" : @"goodbye"}];
    NSDate *start = NSDate.date;
    SNExpect(WaitUntil(1, ^BOOL { return server.connectionCount == 2 && client.state == SNConnectionConnected; }), "goodbye reconnects");
    SNExpect(-start.timeIntervalSinceNow < 0.5, "at once");
    SNExpect(api.calls == 2, "with a fresh URL");
    [client stop];
    [server stop];
}

SN_TEST(LiveRefusesLargeFrames) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    SNExpect((![client sendFrame:@{@"type" : @"typing", @"channel" : @"C1"}]), "nothing is sent before hello");
    if (!Connect(client)) return [server stop];
    NSString *big = [@"" stringByPaddingToLength:17 * 1024 withString:@"x" startingAtIndex:0];
    SNExpect((![client sendFrame:@{@"type" : @"message", @"text" : big}]), "a frame over 16 KB is refused");
    SNExpect(([client sendFrame:@{@"type" : @"typing", @"channel" : @"C1"}]), "a small one is sent");
    SNExpect(WaitUntil(1, ^BOOL {
                 for (NSDictionary *frame in server.received)
                     if ([frame[@"type"] isEqual:@"typing"]) return frame[@"id"] != nil;
                 return NO;
             }),
             "with an id");
    for (NSDictionary *frame in server.received) SNExpect(![frame[@"type"] isEqual:@"message"], "the big frame never left");
    [client stop];
    [server stop];
}

SN_TEST(LiveStopsOffline) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    if (!Connect(client)) return [server stop];
    [client stop];
    SNExpect(client.state == SNConnectionOffline, "offline after stop");
    SNSettle(0.4);
    SNExpect(server.connectionCount == 1 && client.state == SNConnectionOffline, "no reconnect after stop");
    SNExpect(![client sendFrame:@{@"type" : @"typing"}], "nothing sent after stop");
    [server stop];
}

SN_TEST(LiveTracesFramesAndKeepsTypingInReadOnly) {
    SNTestSocketServer *server;
    SNTestLiveAPI *api;
    SNLiveClient *client = Client(&server, &api);
    if (!client) return;
    NSURL *previous = SNTraceFile(), *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"sn-live-trace.log"]];
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    SNSetTraceFile(file);
    BOOL wasReadOnly = SNReadOnly();
    SNSetReadOnly(YES);
    client.presenceUserIDs = ^NSArray<NSString *> * { return @[ @"U01" ]; };
    if (Connect(client)) {
        [server send:@{@"type" : @"message", @"channel" : @"C1", @"ts" : @"1.000001", @"text" : @"secret words"}];
        [server send:@{@"type" : @"message", @"subtype" : @"message_changed", @"channel" : @"C1", @"ts" : @"1.000002",
                       @"message" : @{@"type" : @"message", @"ts" : @"1.000001", @"text" : @"secret edit"}}];
        SNExpect(!([client sendFrame:@{@"type" : @"typing", @"channel" : @"C1"}]), "typing is not sent");
        SNExpect(WaitUntil(1, ^BOOL { return server.received.count > 0; }), "presence_sub still is");
        SNSettle(0.1);
        for (NSDictionary *frame in server.received) SNExpect(![frame[@"type"] isEqual:@"typing"], "no typing frame reached the server");
        NSString *trace = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
        SNExpect([trace containsString:@"\tws:hello\t"] && [trace containsString:@"\tws:message\t"], "a line per frame type");
        SNExpect([trace containsString:@"\tws:message/message_changed\t"], "messages with their subtype");
        SNExpect([trace containsString:@"\tws>typing\t-\tread_only\t"], "the refused typing is traced");
        SNExpect(![trace containsString:@"secret"] && ![trace containsString:@"C1"], "no content or channel");
    }
    SNSetReadOnly(wasReadOnly);
    SNSetTraceFile(previous);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    [client stop];
    [server stop];
}
