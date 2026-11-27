// Spotify Connect dealer WebSocket + connect-state REST/protobuf client.
#import "connect/connect.h"
#import "model/json.h"
#import "model/protobuf.h"

#import <SystemConfiguration/SystemConfiguration.h>
#import <math.h>
#import <zlib.h>

NSString *SPComputerDeviceName(void) {
    CFStringRef nameRef = SCDynamicStoreCopyComputerName(NULL, NULL);
    NSString *name = CFBridgingRelease(nameRef);
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length) return name;
    NSString *host = NSProcessInfo.processInfo.hostName;
    return host.length ? host : @"Mac";
}

NSData *SPGunzipData(NSData *data) {
    if (data.length < 2) return data;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (bytes[0] != 0x1Fu || bytes[1] != 0x8Bu) return data;

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    zs.next_in = (Bytef *)data.bytes;
    zs.avail_in = (uInt)data.length;
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) return nil;

    NSMutableData *out = [NSMutableData dataWithCapacity:data.length * 4];
    uint8_t chunk[16384];
    int rc = Z_OK;
    while (rc == Z_OK) {
        zs.next_out = chunk;
        zs.avail_out = sizeof(chunk);
        rc = inflate(&zs, Z_NO_FLUSH);
        size_t produced = sizeof(chunk) - zs.avail_out;
        if (produced > 0) [out appendBytes:chunk length:produced];
    }
    inflateEnd(&zs);
    return (rc == Z_STREAM_END) ? [out copy] : nil;
}

static NSData *EncodeProvidedTrackProtobuf(NSString *uri, NSString *uid, NSString *provider) {
    return [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *t) {
        [t writeString:uri ?: @"" field:1];
        if (uid.length) [t writeString:uid field:2];
        if (provider.length) [t writeString:provider field:6];
    }];
}

static NSData *EncodePlayerStateProtobuf(SPPlaybackState *ps, uint64_t fallbackTimestampMs) {
    return [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        uint64_t ts = ps.timestampMs > 0 ? (uint64_t)ps.timestampMs : fallbackTimestampMs;
        [w writeVarint:ts field:1];
        if (ps.contextURI.length) {
            [w writeString:ps.contextURI field:2];
            [w writeString:[NSString stringWithFormat:@"context://%@", ps.contextURI] field:3];
        }
        if (ps.currentTrackURI.length) {
            [w writeBytes:EncodeProvidedTrackProtobuf(ps.currentTrackURI, @"0", @"context") field:7];
        }
        [w writeVarint:(uint64_t)MAX(0, ps.positionAsOfTimestampMs) field:10];
        [w writeVarint:(uint64_t)MAX(0, ps.durationMs) field:11];
        [w writeBool:(ps.isPlaying || ps.isPaused) field:12];
        [w writeBool:ps.isPaused field:13];
        [w writeMessageField:16 block:^(SPProtobufWriter *opt) {
            [opt writeFlag:ps.shuffling field:1];
            [opt writeFlag:(ps.repeatMode != SPRepeatOff) field:2];
            [opt writeFlag:(ps.repeatMode == SPRepeatTrack) field:3];
        }];
        NSUInteger prevStart = ps.prevTracks.count > 16 ? ps.prevTracks.count - 16 : 0;
        for (NSUInteger i = prevStart; i < ps.prevTracks.count; i++) {
            SPQueueTrack *qt = ps.prevTracks[i];
            if (qt.uri.length) {
                [w writeBytes:EncodeProvidedTrackProtobuf(qt.uri, qt.uid, qt.provider) field:19];
            }
        }
        NSUInteger nextCap = MIN(ps.nextTracks.count, (NSUInteger)32);
        for (NSUInteger i = 0; i < nextCap; i++) {
            SPQueueTrack *qt = ps.nextTracks[i];
            if (qt.uri.length) {
                [w writeBytes:EncodeProvidedTrackProtobuf(qt.uri, qt.uid, qt.provider) field:20];
            }
        }
    }];
}

NSData *SPConnectBuildPutStateProtobufWithPlayerState(NSString *deviceID,
                                                      NSString *deviceName,
                                                      BOOL canBePlayer,
                                                      BOOL hidden,
                                                      BOOL isActive,
                                                      uint32_t volume,
                                                      uint64_t timestampMs,
                                                      SPPlaybackState *playerState) {
    NSData *capsData = [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeFlag:canBePlayer field:2];        // can_be_player
        [w writeFlag:NO field:3];                 // restrict_to_local
        [w writeFlag:YES field:5];                // gaia_eq_connect_id
        [w writeFlag:YES field:7];                // is_observable
        [w writeVarint:64 field:8];               // volume_steps
        [w writeString:@"audio/track" field:9];   // supported_types
        [w writeString:@"audio/episode" field:9]; // supported_types
        [w writeFlag:YES field:10];               // command_acks
        [w writeFlag:hidden field:12];            // hidden
        [w writeFlag:YES field:15];               // supports_playlist_v2
        [w writeFlag:canBePlayer field:16];       // is_controllable
        [w writeFlag:YES field:17];               // supports_external_episodes
        [w writeFlag:YES field:18];               // supports_set_backend_metadata
        [w writeFlag:YES field:19];               // supports_transfer_command
        [w writeFlag:YES field:20];               // supports_command_request
        [w writeFlag:YES field:23];               // supports_gzip_pushes
        [w writeFlag:YES field:25];               // supports_set_options_command
    }];

    NSData *deviceInfoData = [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeFlag:canBePlayer field:1];             // can_play
        [w writeVarint:volume field:2];                // volume
        [w writeString:deviceName ?: @"Mac" field:3];  // name
        [w writeBytes:capsData field:4];               // capabilities
        [w writeString:@"0.1.0" field:6];              // device_software_version
        [w writeVarint:SPDeviceTypeComputer field:7];  // device_type = COMPUTER
        [w writeString:@"3.2.6" field:9];              // spirc_version
        [w writeString:deviceID field:10];             // device_id
        [w writeNonEmptyString:SPKeymasterClientID field:13];
        [w writeString:@"Apple" field:14];             // brand
        [w writeString:@"Mac" field:15];               // model
    }];

    NSData *playerStateData = playerState ? EncodePlayerStateProtobuf(playerState, timestampMs) : nil;
    NSData *deviceWrapper = [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeBytes:deviceInfoData field:1];
        if (playerStateData.length) {
            [w writeBytes:playerStateData field:2];    // Device.player_state
        }
    }];

    uint64_t reason = (playerState && isActive) ? 2ULL : 1ULL; // PLAYER_STATE_CHANGED vs SPIRC_HELLO
    return [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeBytes:deviceWrapper field:2];      // device
        [w writeVarint:2 field:3];                 // member_type = CONNECT_STATE
        [w writeFlag:isActive field:4];            // is_active
        [w writeVarint:reason field:5];            // put_state_reason
        [w writeVarint:timestampMs field:12];      // client_side_timestamp
    }];
}

NSData *SPConnectBuildPutStateProtobuf(NSString *deviceID,
                                       NSString *deviceName,
                                       BOOL canBePlayer,
                                       BOOL hidden,
                                       BOOL isActive,
                                       uint32_t volume,
                                       uint64_t timestampMs) {
    return SPConnectBuildPutStateProtobufWithPlayerState(deviceID, deviceName, canBePlayer, hidden, isActive, volume, timestampMs, nil);
}

@implementation SPConnectClient {
    SPAuth *_auth;
    SPNetClient *_net;
    SPStore *_store;
    dispatch_queue_t _queue;

    NSURLSessionWebSocketTask *_wsTask;
    dispatch_source_t _pingTimer;
    dispatch_source_t _heartbeatTimer;
    dispatch_source_t _reconnectTimer;

    BOOL _wantConnected;
    BOOL _isConnected;
    NSString *_connectionID;
    NSUInteger _reconnectAttempts;
    uint64_t _sessionGen;
    BOOL _lastActive;
    uint32_t _lastVolume;
    SPPlaybackState *_lastPlaybackState;
}

- (instancetype)initWithAuth:(SPAuth *)auth netClient:(SPNetClient *)netClient store:(SPStore *)store {
    if (!(self = [super init])) return nil;
    _auth = auth;
    _net = netClient;
    _store = store;
    _deviceID = [auth.deviceID copy];
    _deviceName = SPComputerDeviceName();
    _canBePlayer = YES;
    _hidden = NO;
    _pingInterval = 30.0;
    _pongTimeout = 3.0;
    _heartbeatInterval = 30.0;
    _baseReconnectDelay = 1.0;
    _lastVolume = 65535u;
    _queue = dispatch_queue_create("local.spotify-native.connect", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    if (_pingTimer) { dispatch_source_cancel(_pingTimer); _pingTimer = nil; }
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    if (_reconnectTimer) { dispatch_source_cancel(_reconnectTimer); _reconnectTimer = nil; }
    [_wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    _wsTask = nil;
}

- (BOOL)isConnected {
    __block BOOL c = NO;
    dispatch_sync(_queue, ^{ c = self->_isConnected; });
    return c;
}

- (NSString *)connectionID {
    __block NSString *cid = nil;
    dispatch_sync(_queue, ^{ cid = self->_connectionID; });
    return cid;
}

- (NSUInteger)reconnectAttempts {
    __block NSUInteger n = 0;
    dispatch_sync(_queue, ^{ n = self->_reconnectAttempts; });
    return n;
}

- (void)connect {
    dispatch_async(_queue, ^{
        self->_wantConnected = YES;
        self->_reconnectAttempts = 0;
        [self openWebSocketOnQueue];
    });
}

- (void)disconnect {
    dispatch_async(_queue, ^{
        self->_wantConnected = NO;
        self->_sessionGen++;
        [self tearDownSocketOnQueueNotify:YES];
    });
}

- (void)cancelTimersOnQueue {
    if (_pingTimer) { dispatch_source_cancel(_pingTimer); _pingTimer = nil; }
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    if (_reconnectTimer) { dispatch_source_cancel(_reconnectTimer); _reconnectTimer = nil; }
}

- (void)tearDownSocketOnQueueNotify:(BOOL)notify {
    [self cancelTimersOnQueue];
    BOOL wasConnected = _isConnected;
    _isConnected = NO;
    _connectionID = nil;
    if (_wsTask) {
        [_wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        _wsTask = nil;
    }
    if (notify && wasConnected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_store setConnected:NO];
            if ([self.delegate respondsToSelector:@selector(connectClient:didChangeConnected:)]) {
                [self.delegate connectClient:self didChangeConnected:NO];
            }
        });
    }
}

- (void)openWebSocketOnQueue {
    if (!_wantConnected) return;
    [self tearDownSocketOnQueueNotify:NO];
    uint64_t gen = ++_sessionGen;

    [_auth accessTokenWithCompletion:^(NSString *token, NSError *err) {
        dispatch_async(self->_queue, ^{
            if (!self->_wantConnected || self->_sessionGen != gen) return;
            if (err || !token.length) {
                [self scheduleReconnectOnQueueForGen:gen];
                return;
            }
            NSURL *base = self.dealerWebSocketURL ?: [NSURL URLWithString:@"wss://dealer.spotify.com/"];
            NSURLComponents *c = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
            NSMutableArray<NSURLQueryItem *> *q = [NSMutableArray arrayWithArray:c.queryItems ?: @[]];
            [q addObject:[NSURLQueryItem queryItemWithName:@"access_token" value:token]];
            c.queryItems = q;
            NSURL *wsURL = c.URL ?: base;

            NSURLSessionWebSocketTask *task = [self->_net.urlSession webSocketTaskWithURL:wsURL];
            task.maximumMessageSize = 4 * 1024 * 1024;
            self->_wsTask = task;
            self->_isConnected = YES;
            [task resume];

            [self startReceiveLoopOnQueueForTask:task gen:gen];
            [self startPingTimerOnQueueForTask:task gen:gen];
        });
    }];
}

- (void)scheduleReconnectOnQueueForGen:(uint64_t)gen {
    if (!_wantConnected || _sessionGen != gen) return;
    [self tearDownSocketOnQueueNotify:YES];
    NSTimeInterval base = _baseReconnectDelay > 0.0 ? _baseReconnectDelay : 1.0;
    NSTimeInterval delay = MIN(30.0, base * pow(2.0, (double)MIN(_reconnectAttempts, (NSUInteger)5)));
    _reconnectAttempts++;

    _reconnectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_reconnectTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_reconnectTimer, ^{
        SPConnectClient *strong = weakSelf;
        if (!strong || !strong->_wantConnected) return;
        [strong openWebSocketOnQueue];
    });
    dispatch_resume(_reconnectTimer);
}

- (void)startPingTimerOnQueueForTask:(NSURLSessionWebSocketTask *)task gen:(uint64_t)gen {
    if (_pingInterval <= 0) return;
    _pingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t intervalNs = (uint64_t)(_pingInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(_pingTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
                              intervalNs,
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pingTimer, ^{
        SPConnectClient *strong = weakSelf;
        if (!strong || strong->_sessionGen != gen || strong->_wsTask != task) return;
        __block BOOL ponged = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(strong.pongTimeout * NSEC_PER_SEC)), strong->_queue, ^{
            if (!ponged && strong->_sessionGen == gen) {
                [strong scheduleReconnectOnQueueForGen:gen];
            }
        });
        // Protocol-level WebSocket PING frame (Spotify dealer closes on JSON {"type":"ping"}).
        [task sendPingWithPongReceiveHandler:^(NSError *error) {
            dispatch_async(strong->_queue, ^{
                ponged = YES;
                if (error && strong->_sessionGen == gen) {
                    [strong scheduleReconnectOnQueueForGen:gen];
                }
            });
        }];
    });
    dispatch_resume(_pingTimer);
}

- (void)startHeartbeatTimerOnQueueForGen:(uint64_t)gen {
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    if (_heartbeatInterval <= 0) return;
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t intervalNs = (uint64_t)(_heartbeatInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(_heartbeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
                              intervalNs,
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{
        SPConnectClient *strong = weakSelf;
        if (!strong || strong->_sessionGen != gen || !strong->_connectionID.length) return;
        [strong publishDeviceStateActive:strong->_lastActive volume:strong->_lastVolume completion:nil];
    });
    dispatch_resume(_heartbeatTimer);
}

- (void)sendTextJSONOnQueue:(NSDictionary *)obj {
    if (!_wsTask || !_isConnected) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    // Must send TEXT frames — Spotify dealer drops connections on binary frames.
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return;
    [_wsTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text] completionHandler:^(NSError *err) {
        (void)err;
    }];
}

- (void)startReceiveLoopOnQueueForTask:(NSURLSessionWebSocketTask *)task gen:(uint64_t)gen {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        SPConnectClient *outer = weakSelf;
        if (!outer) return;
        dispatch_async(outer->_queue, ^{
            SPConnectClient *strong = weakSelf;
            if (!strong || strong->_sessionGen != gen || strong->_wsTask != task) return;
            if (error || !message) {
                [strong scheduleReconnectOnQueueForGen:gen];
                return;
            }
            NSData *raw = message.type == NSURLSessionWebSocketMessageTypeString
                ? [message.string dataUsingEncoding:NSUTF8StringEncoding]
                : message.data;
            if (raw.length) [strong handleDealerFrameDataOnQueue:raw gen:gen];
            [strong startReceiveLoopOnQueueForTask:task gen:gen];
        });
    }];
}

static NSData *ExtractDealerPayload(NSDictionary *msg) {
    NSArray *payloads = SPJSONArray(msg[@"payloads"]);
    id first = payloads.firstObject;
    NSData *raw = nil;
    if ([first isKindOfClass:NSString.class]) {
        raw = [[NSData alloc] initWithBase64EncodedString:(NSString *)first options:NSDataBase64DecodingIgnoreUnknownCharacters];
    } else if ([first isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)first;
        NSMutableData *buf = [NSMutableData dataWithCapacity:arr.count];
        for (id n in arr) {
            uint8_t b = (uint8_t)SPJSONInt(n, 0);
            [buf appendBytes:&b length:1];
        }
        raw = buf;
    }
    if (!raw.length) return nil;
    NSDictionary *headers = SPJSONDict(msg[@"headers"]);
    NSString *te = SPJSONString(headers[@"Transfer-Encoding"]) ?: SPJSONString(headers[@"transfer-encoding"]);
    if ([te isEqualToString:@"gzip"]) {
        return SPGunzipData(raw);
    }
    return raw;
}

- (void)handleDealerFrameDataOnQueue:(NSData *)data gen:(uint64_t)gen {
    NSDictionary *msg = SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
    if (!msg) return;
    NSString *type = SPJSONString(msg[@"type"]);
    // Requests name their topic in `message_ident`, messages in `uri`.
    NSString *uri = SPJSONString(msg[@"uri"]) ?: SPJSONString(msg[@"message_ident"]);
    NSDictionary *headers = SPJSONDict(msg[@"headers"]);

    if ([type isEqualToString:@"ping"]) {
        [self sendTextJSONOnQueue:@{@"type" : @"pong"}];
        return;
    }
    if ([type isEqualToString:@"pong"]) return;

    if ([type isEqualToString:@"request"]) {
        NSString *key = SPJSONString(msg[@"key"]);
        if ([uri hasPrefix:@"hm://connect-state/v1/cluster"]) {
            NSData *payload = ExtractDealerPayload(msg);
            if (payload.length) [self adoptClusterDataOnQueue:payload];
            if (key.length) {
                [self sendTextJSONOnQueue:@{@"type" : @"reply", @"key" : key, @"payload" : @{@"success" : @YES}}];
            }
            return;
        }
        NSDictionary *cmd = SPJSONDict(msg[@"payload"]);
        if (cmd) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL handled = NO;
                if ([self.delegate respondsToSelector:@selector(connectClient:didReceiveCommandPayload:)]) {
                    handled = [self.delegate connectClient:self didReceiveCommandPayload:cmd];
                }
                if (key.length) {
                    dispatch_async(self->_queue, ^{
                        if (self->_sessionGen == gen) {
                            [self sendTextJSONOnQueue:@{@"type" : @"reply", @"key" : key, @"payload" : @{@"success" : @(handled)}}];
                        }
                    });
                }
            });
        } else if (key.length) {
            [self sendTextJSONOnQueue:@{@"type" : @"reply", @"key" : key, @"payload" : @{@"success" : @NO}}];
        }
        return;
    }

    if (![type isEqualToString:@"message"] || !uri.length) return;

    if ([uri isEqualToString:@"hm://pusher/v1/connections/"]) {
        NSString *cid = SPJSONString(headers[@"Spotify-Connection-Id"]) ?: SPJSONString(headers[@"spotify-connection-id"]);
        if (cid.length) [self onConnectionIDReceivedOnQueue:cid gen:gen];
    } else if ([uri hasPrefix:@"hm://pusher/v1/connections/"]) {
        NSString *suffix = [uri substringFromIndex:@"hm://pusher/v1/connections/".length];
        NSString *decoded = suffix.stringByRemovingPercentEncoding ?: suffix;
        if (decoded.length) [self onConnectionIDReceivedOnQueue:decoded gen:gen];
    } else if ([uri hasPrefix:@"hm://connect-state/v1/cluster"]) {
        NSData *payload = ExtractDealerPayload(msg);
        if (payload.length) [self adoptClusterDataOnQueue:payload];
    }
}

- (void)onConnectionIDReceivedOnQueue:(NSString *)cid gen:(uint64_t)gen {
    _connectionID = [cid copy];
    _reconnectAttempts = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_store setConnected:YES];
        if ([self.delegate respondsToSelector:@selector(connectClient:didChangeConnected:)]) {
            [self.delegate connectClient:self didChangeConnected:YES];
        }
    });
    [self startHeartbeatTimerOnQueueForGen:gen];
    [self publishDeviceStateActive:_lastActive volume:_lastVolume playbackState:_lastPlaybackState completion:nil];
}

- (void)adoptClusterDataOnQueue:(NSData *)clusterUpdateBytes {
    SPClusterState *cluster = [SPClusterState clusterUpdateFromProtobufData:clusterUpdateBytes];
    if (!cluster) return;
    [self publishClusterToStore:cluster];
}

- (void)publishClusterToStore:(SPClusterState *)cluster {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_store applyClusterState:cluster];
        if ([self.delegate respondsToSelector:@selector(connectClient:didUpdateCluster:)]) {
            [self.delegate connectClient:self didUpdateCluster:cluster];
        }
    });
}

#pragma mark - Connect-State REST & PutState

- (NSURL *)spclientURL:(NSString *)path {
    NSString *trimmed = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    return [NSURL URLWithString:trimmed relativeToURL:[_net.spclientBaseURL URLByAppendingPathComponent:@""]].absoluteURL;
}

- (void)publishDeviceStateActive:(BOOL)active
                          volume:(uint32_t)volume
                      completion:(void (^)(SPClusterState *, NSError *))completion {
    [self publishDeviceStateActive:active volume:volume playbackState:nil completion:completion];
}

- (void)publishDeviceStateActive:(BOOL)active
                          volume:(uint32_t)volume
                   playbackState:(SPPlaybackState *)playbackState
                      completion:(void (^)(SPClusterState *, NSError *))completion {
    dispatch_async(_queue, ^{
        self->_lastActive = active;
        self->_lastVolume = volume;
        if (playbackState) {
            self->_lastPlaybackState = playbackState;
        } else if (!active) {
            self->_lastPlaybackState = nil;
        }
        NSString *cid = self->_connectionID;
        if (!cid.length) {
            if (completion) completion(nil, [NSError errorWithDomain:SPNetErrorDomain code:SPNetErrorHTTPStatus userInfo:@{NSLocalizedDescriptionKey : @"No dealer connection ID"}]);
            return;
        }
        uint64_t tsMs = (uint64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
        SPPlaybackState *ps = playbackState ?: self->_lastPlaybackState;
        NSData *body = SPConnectBuildPutStateProtobufWithPlayerState(self->_deviceID, self.deviceName, self.canBePlayer, self.hidden, active, volume, tsMs, ps);
        NSURL *url = [self spclientURL:[NSString stringWithFormat:@"connect-state/v1/devices/%@", self->_deviceID]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"PUT";
        req.HTTPBody = body;
        [req setValue:cid forHTTPHeaderField:@"X-Spotify-Connection-Id"];
        [req setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];

        [self->_net sendSignedRequest:req retryReads:NO completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
            if (err || !http || http.statusCode < 200 || http.statusCode >= 300) {
                NSError *outErr = err ?: [NSError errorWithDomain:SPNetErrorDomain code:SPNetErrorHTTPStatus userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"PutState HTTP %ld", (long)(http ? http.statusCode : -1)]}];
                if (completion) completion(nil, outErr);
                return;
            }
            SPClusterState *cluster = data.length ? [SPClusterState clusterFromProtobufData:data] : nil;
            if (cluster) [self publishClusterToStore:cluster];
            if (completion) completion(cluster, nil);
        }];
    });
}

- (SPCancelToken *)transferPlaybackToDeviceID:(NSString *)targetDeviceID
                                   completion:(void (^)(NSError *))completion {
    NSURL *url = [self spclientURL:[NSString stringWithFormat:@"connect-state/v1/connect/transfer/from/%@/to/%@", _deviceID, targetDeviceID]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    // Transfer takes NO body (empty JSON object is not equivalent).
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return [_net sendSignedRequest:req retryReads:NO completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        (void)data;
        if (err) { if (completion) completion(err); return; }
        if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            if (completion) completion([NSError errorWithDomain:SPNetErrorDomain code:SPNetErrorHTTPStatus userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Transfer HTTP %ld", (long)(http ? http.statusCode : -1)]}]);
            return;
        }
        if (completion) completion(nil);
    }];
}

- (SPCancelToken *)setVolumePercent:(NSInteger)percent
                         onDeviceID:(NSString *)targetDeviceID
                         completion:(void (^)(NSError *))completion {
    NSInteger clamped = MIN(100, MAX(0, percent));
    NSInteger wireVol = (NSInteger)llround(((double)clamped / 100.0) * 65535.0);
    NSURL *url = [self spclientURL:[NSString stringWithFormat:@"connect-state/v1/connect/volume/from/%@/to/%@", _deviceID, targetDeviceID]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"PUT";
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"volume" : @(wireVol)} options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return [_net sendSignedRequest:req retryReads:NO completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        (void)data;
        if (err) { if (completion) completion(err); return; }
        if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            if (completion) completion([NSError errorWithDomain:SPNetErrorDomain code:SPNetErrorHTTPStatus userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Volume HTTP %ld", (long)(http ? http.statusCode : -1)]}]);
            return;
        }
        if (completion) completion(nil);
    }];
}

- (SPCancelToken *)sendPlayerCommand:(NSDictionary *)command
                          toDeviceID:(NSString *)targetDeviceID
                          completion:(void (^)(NSError *))completion {
    NSMutableDictionary *cmd = [command mutableCopy];
    if (!cmd[@"logging_params"]) {
        cmd[@"logging_params"] = @{@"command_initiated_time" : @((int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0))};
    }
    NSDictionary *envelope = @{@"command" : cmd};
    NSURL *url = [self spclientURL:[NSString stringWithFormat:@"connect-state/v1/player/command/from/%@/to/%@", _deviceID, targetDeviceID]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return [_net sendSignedRequest:req retryReads:NO completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err) { if (completion) completion(err); return; }
        if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            NSString *detail = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (completion) completion([NSError errorWithDomain:SPNetErrorDomain code:SPNetErrorHTTPStatus userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Command HTTP %ld %@", (long)(http ? http.statusCode : -1), detail ?: @""]}]);
            return;
        }
        if (completion) completion(nil);
    }];
}

- (SPCancelToken *)pauseOnDeviceID:(NSString *)deviceID completion:(void (^)(NSError *))completion {
    return [self sendPlayerCommand:@{@"endpoint" : @"pause"} toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)resumeOnDeviceID:(NSString *)deviceID completion:(void (^)(NSError *))completion {
    return [self sendPlayerCommand:@{@"endpoint" : @"resume"} toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)skipNextOnDeviceID:(NSString *)deviceID completion:(void (^)(NSError *))completion {
    return [self sendPlayerCommand:@{@"endpoint" : @"skip_next"} toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)skipNextToTrackURI:(NSString *)trackURI
                                  uid:(NSString *)uid
                           onDeviceID:(NSString *)deviceID
                           completion:(void (^)(NSError *))completion {
    NSMutableDictionary *track = [@{@"uri" : trackURI ?: @""} mutableCopy];
    if (uid.length) track[@"uid"] = uid;
    return [self sendPlayerCommand:@{@"endpoint" : @"skip_next", @"track" : track}
                        toDeviceID:deviceID
                        completion:completion];
}

- (SPCancelToken *)skipPrevOnDeviceID:(NSString *)deviceID completion:(void (^)(NSError *))completion {
    return [self sendPlayerCommand:@{@"endpoint" : @"skip_prev"} toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)seekToMs:(int64_t)positionMs onDeviceID:(NSString *)deviceID completion:(void (^)(NSError *))completion {
    return [self sendPlayerCommand:@{@"endpoint" : @"seek_to", @"value" : @(MAX(0, positionMs))} toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)setShuffle:(BOOL)enabled onDeviceID:(NSString *)deviceID completion:(void (^)(NSError *))completion {
    return [self sendPlayerCommand:@{@"endpoint" : @"set_shuffling_context", @"value" : @(enabled)} toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)setRepeatMode:(SPRepeatMode)mode onDeviceID:(NSString *)deviceID completion:(void (^)(NSError *))completion {
    return [self sendPlayerCommand:@{
        @"endpoint" : @"set_options",
        @"repeating_context" : @(mode != SPRepeatOff),
        @"repeating_track" : @(mode == SPRepeatTrack),
    } toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)playContextURI:(NSString *)contextURI
               startingAtTrackURI:(NSString *)trackURI
                       trackIndex:(NSInteger)trackIndex
                       onDeviceID:(NSString *)deviceID
                       completion:(void (^)(NSError *))completion {
    NSMutableDictionary *skipTo = [NSMutableDictionary new];
    if (trackURI.length) skipTo[@"track_uri"] = trackURI;
    else if (trackIndex >= 0) skipTo[@"track_index"] = @(trackIndex);
    else if ([contextURI hasPrefix:@"spotify:track:"]) skipTo[@"track_uri"] = contextURI;

    NSDictionary *options = skipTo.count ? @{@"skip_to" : skipTo} : @{};
    NSDictionary *cmd = @{
        @"endpoint" : @"play",
        @"context" : @{
            @"uri" : contextURI,
            @"url" : [NSString stringWithFormat:@"context://%@", contextURI],
        },
        @"play_origin" : @{@"feature_identifier" : @"spotify-native"},
        @"options" : options,
    };
    return [self sendPlayerCommand:cmd toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)playTrackURIs:(NSArray<NSString *> *)trackURIs
                      onDeviceID:(NSString *)deviceID
                      completion:(void (^)(NSError *))completion {
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:trackURIs.count];
    for (NSString *uri in trackURIs) [tracks addObject:@{@"uri" : uri}];
    NSDictionary *cmd = @{
        @"endpoint" : @"play",
        @"context" : @{@"pages" : @[ @{@"tracks" : tracks} ]},
        @"play_origin" : @{@"feature_identifier" : @"spotify-native"},
        @"options" : @{},
    };
    return [self sendPlayerCommand:cmd toDeviceID:deviceID completion:completion];
}

- (SPCancelToken *)addToQueueTrackURI:(NSString *)trackURI
                           onDeviceID:(NSString *)deviceID
                           completion:(void (^)(NSError *))completion {
    NSDictionary *cmd = @{
        @"endpoint" : @"add_to_queue",
        @"track" : @{
            @"uri" : trackURI,
            @"metadata" : @{@"is_queued" : @"true"},
            @"provider" : @"queue",
        },
    };
    return [self sendPlayerCommand:cmd toDeviceID:deviceID completion:completion];
}

@end
