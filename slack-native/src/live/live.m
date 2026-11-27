// Owns the websocket: connecting, frames, liveness and reconnection.
#import <AppKit/AppKit.h>

#import "live/live.h"
#import "model/json.h"
#import "net/switches.h"

/// Slack closes the connection on a client frame larger than this.
static const NSUInteger SNLiveMaxFrame = 16 * 1024;

NSTimeInterval SNLiveBackoff(NSInteger attempt, NSTimeInterval base, NSTimeInterval max) {
    NSTimeInterval delay = MIN(base * pow(2, (double)MIN(MAX(attempt, 0), 30)), max);
    return delay / 2 + delay / 2 * ((double)arc4random_uniform(1001) / 1000);
}

/// Encodes a query value as the web client does: '&', '+', '#' and '%' escaped, while '?' and
/// '=' stay as they are (start_args nests a query of its own).
static NSString *QueryValue(NSString *value) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&+#%"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

NSURL *SNLiveURL(NSString *primaryURL, NSString *routingContext, NSString *token) {
    if (![primaryURL hasPrefix:@"wss://"] && ![primaryURL hasPrefix:@"ws://"]) return nil;
    NSString *startArgs = @"?agent=client&org_wide_aware=true&eac_cache_ts=true&cache_ts=0&name_tagging=true"
                          @"&only_self_subteams=true&connect_only=true&ms_latest=true";
    NSMutableArray<NSArray<NSString *> *> *params = [@[
        @[ @"token", token ], @[ @"sync_desync", @"1" ], @[ @"slack_client", @"desktop" ], @[ @"start_args", startArgs ],
        @[ @"no_query_on_subscribe", @"1" ], @[ @"flannel", @"3" ], @[ @"lazy_channels", @"1" ]
    ] mutableCopy];
    if (routingContext.length) [params addObject:@[ @"gateway_server", routingContext ]];
    [params addObject:@[ @"batch_presence_aware", @"1" ]];
    NSMutableArray<NSString *> *pairs = [NSMutableArray new];
    for (NSArray<NSString *> *param in params) [pairs addObject:[NSString stringWithFormat:@"%@=%@", param[0], QueryValue(param[1])]];
    NSString *separator = [primaryURL containsString:@"?"] ? @"&" : @"?";
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@%@%@", primaryURL, separator, [pairs componentsJoinedByString:@"&"]]];
}

/// A timer on the main run loop in common modes, so it fires while a menu is open or the window
/// is resized.
static NSTimer *MainTimer(NSTimeInterval delay, void (^block)(NSTimer *timer)) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:block];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

@implementation SNLiveClient {
    id<SNAPI> _api;
    SNSession *_session;
    NSString *_teamID;
    NSURLSession *_urlSession;
    NSURLSessionWebSocketTask *_task;
    /// Bumped whenever the connection is dropped, so callbacks of an older one are ignored.
    NSUInteger _generation;
    BOOL _running, _tookCookies;
    NSInteger _frameID, _attempt, _unansweredPings;
    NSDate *_lastFrame, *_lastPing;
    NSTimer *_checkTimer, *_connectTimer, *_stableTimer;
    id _wakeObserver;
}

- (instancetype)initWithAPI:(id<SNAPI>)api session:(SNSession *)session teamID:(NSString *)teamID urlSession:(NSURLSession *)urlSession {
    if (!(self = [super init])) return nil;
    _api = api;
    _session = session;
    _teamID = [teamID copy];
    _urlSession = urlSession;
    _pingInterval = 20;
    _silenceTimeout = 50;
    _backoffBase = 1;
    _backoffMax = 30;
    _stableAfter = 30;
    __weak SNLiveClient *weakSelf = self;
    _wakeObserver = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil
                                                                                  queue:NSOperationQueue.mainQueue
                                                                             usingBlock:^(NSNotification *note) { [weakSelf check]; }];
    return self;
}

- (void)dealloc {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_wakeObserver];
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    [_checkTimer invalidate];
    [_connectTimer invalidate];
    [_stableTimer invalidate];
}

- (void)setState:(SNConnectionState)state {
    if (_state == state) return;
    _state = state;
    if (self.onStateChange) self.onStateChange(state);
}

- (void)start {
    if (_running) return;
    _running = YES;
    _attempt = 0;
    self.state = SNConnectionConnecting;
    [self connect];
}

- (void)stop {
    _running = NO;
    [self tearDown];
    self.state = SNConnectionOffline;
}

/// Closes the current connection and forgets its timers.
- (void)tearDown {
    _generation++;
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    _task = nil;
    [_checkTimer invalidate];
    [_connectTimer invalidate];
    [_stableTimer invalidate];
    _checkTimer = _connectTimer = _stableTimer = nil;
}

#pragma mark Connecting

- (void)connect {
    if (!_running) return;
    NSUInteger generation = ++_generation;
    NSString *token = [_session teamWithID:_teamID].token;
    __weak SNLiveClient *weakSelf = self;
    [_api call:@"client.getWebSocketURL" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        SNLiveClient *client = weakSelf;
        if (!client || client->_generation != generation || !client->_running) return;
        NSString *primary = SNJSONString(response, @"primary_websocket_url");
        NSURL *url = primary && token ? SNLiveURL(primary, SNJSONString(response, @"routing_context"), token) : nil;
        if (url) [client open:url];
        else [client reconnectAfter:SNLiveBackoff(client->_attempt++, client.backoffBase, client.backoffMax)];
    }];
}

- (void)open:(NSURL *)url {
    NSURLRequest *request = [_session requestWithURL:url];
    _task = [_urlSession webSocketTaskWithRequest:request];
    _task.maximumMessageSize = 8 * 1024 * 1024;
    _tookCookies = NO;
    _unansweredPings = 0;
    _lastFrame = _lastPing = NSDate.date;
    [_task resume];
    [self receive:_task generation:_generation];
    [self scheduleCheck];
}

- (void)receive:(NSURLSessionWebSocketTask *)task generation:(NSUInteger)generation {
    __weak SNLiveClient *weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        // Parsed on URLSession's queue; the main thread only handles the frame.
        NSData *data = message.type == NSURLSessionWebSocketMessageTypeString ? [message.string dataUsingEncoding:NSUTF8StringEncoding] : message.data;
        id frame = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            SNLiveClient *client = weakSelf;
            if (!client || client->_generation != generation) return;
            if (error || !message) return [client drop];
            [client received:[frame isKindOfClass:NSDictionary.class] ? frame : nil bytes:data.length task:task];
            if (client->_generation == generation) [client receive:task generation:generation];
        });
    }];
}

/// The connection is gone or unusable: back off and connect again.
- (void)drop {
    if (!_running) return;
    [self tearDown];
    self.state = SNConnectionConnecting;
    [self reconnectAfter:SNLiveBackoff(_attempt++, self.backoffBase, self.backoffMax)];
}

- (void)reconnectAfter:(NSTimeInterval)delay {
    if (!_running) return;
    [_connectTimer invalidate];
    __weak SNLiveClient *weakSelf = self;
    _connectTimer = MainTimer(delay, ^(NSTimer *timer) { [weakSelf connect]; });
}

#pragma mark Frames

- (void)received:(NSDictionary *)frame bytes:(NSUInteger)bytes task:(NSURLSessionWebSocketTask *)task {
    _lastFrame = NSDate.date;
    if (!_tookCookies && [task.response isKindOfClass:NSHTTPURLResponse.class]) {
        _tookCookies = YES;
        [_session takeCookiesFromResponse:(NSHTTPURLResponse *)task.response];
    }
    if (!frame) return;
    NSString *type = SNJSONString(frame, @"type");
    if (SNTracing()) {
        // A message's subtype tells edits, deletions, replies and broadcasts apart.
        NSString *subtype = [type isEqualToString:@"message"] ? SNJSONString(frame, @"subtype") : nil;
        SNTrace([NSString stringWithFormat:@"ws:%@%@%@", type ?: @"-", subtype ? @"/" : @"", subtype ?: @""], 0, @"ok", -1, bytes);
    }
    if ([type isEqualToString:@"hello"]) {
        SNTraceLaunch(@"hello");
        [self hello:frame];
    }
    else if ([type isEqualToString:@"pong"]) _unansweredPings = 0;
    else if ([type isEqualToString:@"ping"]) [self send:@{@"type" : @"pong", @"reply_to" : frame[@"id"] ?: @0}];
    // Not followed: a reconnect comes after a drop, and a drop is often sleep, after which the
    // URL is stale. Every connection starts from client.getWebSocketURL.
    else if ([type isEqualToString:@"reconnect_url"]) return;
    else if ([type isEqualToString:@"goodbye"]) {
        // Slack ends every connection after some hours; the next one starts at once.
        [self tearDown];
        self.state = SNConnectionConnecting;
        [self reconnectAfter:0];
    } else if ([type isEqualToString:@"error"]) {
        if (SNJSONInteger(SNJSONObject(frame, @"error"), @"code") == 1) [self drop];
    } else if (type && self.onEvent) self.onEvent(frame);
}

- (void)hello:(NSDictionary *)frame {
    self.state = SNConnectionConnected;
    __weak SNLiveClient *weakSelf = self;
    [_stableTimer invalidate];
    _stableTimer = MainTimer(self.stableAfter, ^(NSTimer *timer) {
        SNLiveClient *client = weakSelf;
        if (client) client->_attempt = 0;
    });
    NSArray<NSString *> *ids = self.presenceUserIDs ? self.presenceUserIDs() : nil;
    if (ids.count) [self sendFrame:@{@"type" : @"presence_sub", @"ids" : ids}];
    [self scheduleCheck];
    if (self.onConnect) self.onConnect(SNJSONBool(frame, @"fast_reconnect"));
}

- (BOOL)sendFrame:(NSDictionary *)frame {
    // Typing is the one frame others see; presence subscriptions only ask.
    if (SNReadOnly() && [frame[@"type"] isEqual:@"typing"]) {
        SNTrace(@"ws>typing", 0, @"read_only", -1, 0);
        return NO;
    }
    if (self.state != SNConnectionConnected) return NO;
    return [self send:frame];
}

- (BOOL)send:(NSDictionary *)frame {
    if (!_task) return NO;
    NSMutableDictionary *numbered = [frame mutableCopy];
    numbered[@"id"] = @(++_frameID);
    NSData *data = [NSJSONSerialization isValidJSONObject:numbered] ? [NSJSONSerialization dataWithJSONObject:numbered options:0 error:nil] : nil;
    if (!data || data.length > SNLiveMaxFrame) return NO;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [_task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text] completionHandler:^(NSError *error) {}];
    return YES;
}

#pragma mark Liveness

/// One timer, due at whichever comes first: the next ping or the end of the silence allowed.
- (void)scheduleCheck {
    [_checkTimer invalidate];
    NSTimeInterval silence = [_lastFrame dateByAddingTimeInterval:self.silenceTimeout].timeIntervalSinceNow;
    NSTimeInterval ping = self.state == SNConnectionConnected ? [_lastPing dateByAddingTimeInterval:self.pingInterval].timeIntervalSinceNow : silence;
    NSTimeInterval delay = MAX(MIN(silence, ping), 0);
    __weak SNLiveClient *weakSelf = self;
    _checkTimer = MainTimer(delay, ^(NSTimer *timer) { [weakSelf check]; });
    _checkTimer.tolerance = MIN(self.pingInterval, self.silenceTimeout) / 10;
}

- (void)check {
    if (!_task) return;
    if (-_lastFrame.timeIntervalSinceNow >= self.silenceTimeout) return [self drop];
    if (self.state == SNConnectionConnected && -_lastPing.timeIntervalSinceNow >= self.pingInterval) {
        if (_unansweredPings >= 2) return [self drop];
        _unansweredPings++;
        _lastPing = NSDate.date;
        [self send:@{@"type" : @"ping"}];
    }
    [self scheduleCheck];
}

@end
