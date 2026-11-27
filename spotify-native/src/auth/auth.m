// Spotify Keymaster OAuth 2.0 PKCE + Client-Token protobuf provider.
#import "auth/auth.h"
#import "model/json.h"
#import "model/protobuf.h"

#import <AppKit/NSWorkspace.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/SecRandom.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

NSString *const SPKeymasterClientID = @"65b708073fc0480ea92a077233ca87bd";
NSTimeInterval const SPKeymasterRefreshBuffer = 300.0;
NSString *const SPAuthErrorDomain = @"local.spotify-native.auth";

static NSError *AuthError(SPAuthErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:SPAuthErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : msg ?: @"Authentication error"}];
}

#pragma mark - SPPKCE

static NSString *Base64URLEncode(NSData *data) {
    NSString *b64 = [data base64EncodedStringWithOptions:0];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return b64;
}

static NSString *RandomBase64URL(size_t byteCount) {
    NSMutableData *data = [NSMutableData dataWithLength:byteCount];
    (void)SecRandomCopyBytes(kSecRandomDefault, byteCount, data.mutableBytes);
    return Base64URLEncode(data);
}

@implementation SPPKCE

+ (NSString *)generateCodeVerifier { return RandomBase64URL(64); }

+ (NSString *)codeChallengeForVerifier:(NSString *)verifier {
    NSData *utf8 = [verifier dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(utf8.bytes, (CC_LONG)utf8.length, digest);
    return Base64URLEncode([NSData dataWithBytes:digest length:sizeof(digest)]);
}

+ (NSString *)generateState { return RandomBase64URL(16); }

+ (NSString *)generateDeviceID {
    uint8_t bytes[20] = {0};
    (void)SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes);
    static const char hex[] = "0123456789abcdef";
    char out[41];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        out[i * 2] = hex[(bytes[i] >> 4) & 0xFu];
        out[i * 2 + 1] = hex[bytes[i] & 0xFu];
    }
    out[40] = '\0';
    return [[NSString alloc] initWithBytes:out length:40 encoding:NSASCIIStringEncoding];
}

@end

#pragma mark - SPLoopbackServer

@implementation SPLoopbackServer {
    int _listenFD;
    dispatch_queue_t _queue;
    dispatch_source_t _acceptSource;
    dispatch_source_t _timeoutTimer;
    BOOL _finished;
    NSURLComponents *_pendingCallback;
    NSError *_pendingError;
    void (^_waiter)(NSURLComponents *_Nullable, NSError *_Nullable);
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _listenFD = -1;
    _queue = dispatch_queue_create("local.spotify-native.oauth-loopback", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    if (_timeoutTimer) {
        dispatch_source_cancel(_timeoutTimer);
        _timeoutTimer = nil;
    }
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    _listenFD = -1;
}

+ (NSURLComponents *)parseHTTPRequestLine:(NSString *)request {
    if (!request.length) return nil;
    NSRange nl = [request rangeOfString:@"\n"];
    NSString *line = nl.location == NSNotFound ? request : [request substringToIndex:nl.location];
    line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    if (parts.count < 2 || ![parts[0] isEqualToString:@"GET"]) return nil;
    NSString *target = parts[1];
    if (![target hasPrefix:@"/"]) return nil;
    return [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:target]];
}

- (BOOL)startWithError:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = AuthError(SPAuthErrorLoopbackFailed, @"socket() failed");
        return NO;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
        close(fd);
        if (error) *error = AuthError(SPAuthErrorLoopbackFailed, @"bind/listen on 127.0.0.1 failed");
        return NO;
    }

    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) != 0 || addr.sin_port == 0) {
        close(fd);
        if (error) *error = AuthError(SPAuthErrorLoopbackFailed, @"getsockname failed");
        return NO;
    }

    _listenFD = fd;
    _port = ntohs(addr.sin_port);

    __weak typeof(self) weakSelf = self;
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(_acceptSource, ^{
        [weakSelf acceptOne];
    });
    int closeFD = fd;
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(closeFD);
    });
    dispatch_resume(_acceptSource);
    return YES;
}

static void SendAllAndHalfClose(int cfd, const char *bytes, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(cfd, bytes + sent, len - sent, 0);
        if (n <= 0) break;
        sent += (size_t)n;
    }
    shutdown(cfd, SHUT_WR);
}

- (void)acceptOne {
    if (_finished || _listenFD < 0) return;
    struct sockaddr_in peer;
    socklen_t peerLen = sizeof(peer);
    int cfd = accept(_listenFD, (struct sockaddr *)&peer, &peerLen);
    if (cfd < 0) return;

    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    // Drain full HTTP request headers before writing so closing the socket never emits a TCP RST.
    char buf[8192];
    ssize_t total = 0;
    while (total < (ssize_t)sizeof(buf) - 1) {
        ssize_t n = recv(cfd, buf + total, sizeof(buf) - 1 - (size_t)total, 0);
        if (n <= 0) break;
        total += n;
        buf[total] = '\0';
        if (strstr(buf, "\r\n\r\n") != NULL || strstr(buf, "\n\n") != NULL) break;
    }

    NSString *reqText = total > 0 ? [[NSString alloc] initWithBytes:buf length:(NSUInteger)total encoding:NSUTF8StringEncoding] : nil;
    NSURLComponents *comps = [SPLoopbackServer parseHTTPRequestLine:reqText];
    if (!comps) {
        const char *bad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        SendAllAndHalfClose(cfd, bad, strlen(bad));
        close(cfd);
        return;
    }

    // Accept ONLY GET /login; answer probes (/favicon.ico, /apple-touch-icon.png, /, etc.) without aborting OAuth.
    if (![comps.path isEqualToString:@"/login"]) {
        const char *probeResp = [comps.path isEqualToString:@"/favicon.ico"]
            ? "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        SendAllAndHalfClose(cfd, probeResp, strlen(probeResp));
        close(cfd);
        return;
    }

    BOOL hasCode = NO;
    for (NSURLQueryItem *qi in comps.queryItems) {
        if ([qi.name isEqualToString:@"code"] && qi.value.length > 0) { hasCode = YES; break; }
    }
    const char *html = hasCode
        ? "<html><body style='font-family:-apple-system;background:#121212;color:#fff;padding:40px'><h2>Signed in to Spotify Native</h2><p>You can close this tab and return to the app.</p></body></html>"
        : "<html><body style='font-family:-apple-system;background:#121212;color:#fff;padding:40px'><h2>Sign-in cancelled</h2><p>You can close this tab and return to the app.</p></body></html>";
    NSString *resp = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
        strlen(html), html];
    const char *rbytes = resp.UTF8String;
    SendAllAndHalfClose(cfd, rbytes, strlen(rbytes));
    close(cfd);

    [self finishOnQueueWithCallback:comps error:nil];
}

- (void)waitForCallbackWithTimeout:(NSTimeInterval)timeout
                        completion:(void (^)(NSURLComponents *, NSError *))completion {
    dispatch_async(_queue, ^{
        if (self->_finished) {
            NSURLComponents *cb = self->_pendingCallback;
            NSError *err = self->_pendingError;
            self->_pendingCallback = nil;
            self->_pendingError = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(cb, err);
            });
            return;
        }
        self->_waiter = [completion copy];
        if (timeout > 0) {
            self->_timeoutTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
            dispatch_source_set_timer(self->_timeoutTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                                      DISPATCH_TIME_FOREVER,
                                      (uint64_t)(0.1 * NSEC_PER_SEC));
            __weak typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(self->_timeoutTimer, ^{
                [weakSelf finishOnQueueWithCallback:nil error:AuthError(SPAuthErrorTimedOut, @"Timed out waiting for Spotify OAuth redirect")];
            });
            dispatch_resume(self->_timeoutTimer);
        }
    });
}

- (void)finishOnQueueWithCallback:(NSURLComponents *)callback error:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    if (_timeoutTimer) {
        dispatch_source_cancel(_timeoutTimer);
        _timeoutTimer = nil;
    }
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    _listenFD = -1;

    void (^waiter)(NSURLComponents *, NSError *) = _waiter;
    _waiter = nil;
    if (waiter) {
        dispatch_async(dispatch_get_main_queue(), ^{
            waiter(callback, error);
        });
    } else {
        _pendingCallback = callback;
        _pendingError = error;
    }
}

- (void)stop {
    dispatch_async(_queue, ^{
        [self finishOnQueueWithCallback:nil error:AuthError(SPAuthErrorLoopbackFailed, @"Loopback server stopped")];
    });
}

@end

#pragma mark - SPClientToken

@implementation SPClientToken

- (instancetype)initWithToken:(NSString *)token expiresAt:(NSTimeInterval)expiresAt {
    if (!(self = [super init])) return nil;
    _token = [token copy];
    _expiresAt = expiresAt;
    return self;
}

+ (NSData *)encodeRequestWithClientID:(NSString *)clientID deviceID:(NSString *)deviceID {
    return [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeVarint:1 field:1]; // REQUEST_CLIENT_DATA_REQUEST
        [w writeMessageField:2 block:^(SPProtobufWriter *cd) {
            [cd writeString:@"0.0.0" field:1]; // client_version verified live
            [cd writeString:clientID field:2];
            [cd writeMessageField:3 block:^(SPProtobufWriter *sdk) {
                [sdk writeMessageField:1 block:^(SPProtobufWriter *plat) {
                    [plat writeMessageField:3 block:^(SPProtobufWriter *mac) { (void)mac; }];
                }];
                [sdk writeString:deviceID field:2];
            }];
        }];
    }];
}

+ (instancetype)decodeResponseData:(NSData *)data now:(NSTimeInterval)now error:(NSError **)error {
    uint64_t responseType = 0;
    if (!SPProtobufFirstVarint(data, 1, &responseType)) {
        if (error) *error = AuthError(SPAuthErrorMalformedResponse, @"Client-Token response missing response_type");
        return nil;
    }
    if (responseType == 2) {
        if (error) *error = AuthError(SPAuthErrorClientTokenChallenged, @"Spotify requested a client-token challenge");
        return nil;
    }
    if (responseType != 1) {
        if (error) *error = AuthError(SPAuthErrorMalformedResponse, @"Unexpected client-token response_type");
        return nil;
    }
    NSData *granted = SPProtobufFirstBytes(data, 2);
    NSString *token = granted ? SPProtobufFirstString(granted, 1) : nil;
    if (!token.length) {
        if (error) *error = AuthError(SPAuthErrorMalformedResponse, @"Client-Token response missing granted_token.token");
        return nil;
    }
    uint64_t expiresAfter = 0;
    NSTimeInterval lifetime = SPProtobufFirstVarint(granted, 2, &expiresAfter) ? (NSTimeInterval)expiresAfter : 3600.0;
    return [[self alloc] initWithToken:token expiresAt:now + lifetime];
}

@end

#pragma mark - SPAuth

static void DispatchAuthCallback(dispatch_block_t block) {
    if (!block) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), block);
}

@implementation SPAuth {
    NSURLSession *_urlSession;
    dispatch_queue_t _queue;
    SPSessionBlob *_session;
    NSString *_deviceID;
    BOOL _persistUpdates;
    uint64_t _authGeneration;
    SPLoopbackServer *_activeLoopbackServer;

    NSMutableArray<void (^)(NSString *_Nullable, NSError *_Nullable)> *_refreshWaiters;
    NSMutableArray<void (^)(NSString *_Nullable, NSError *_Nullable)> *_clientTokenWaiters;
}

+ (NSArray<NSString *> *)desktopScopes {
    return @[
        @"app-remote-control",
        @"playlist-modify",
        @"playlist-modify-private",
        @"playlist-modify-public",
        @"playlist-read",
        @"playlist-read-collaborative",
        @"playlist-read-private",
        @"streaming",
        @"ugc-image-upload",
        @"user-follow-modify",
        @"user-follow-read",
        @"user-library-modify",
        @"user-library-read",
        @"user-modify",
        @"user-modify-playback-state",
        @"user-modify-private",
        @"user-personalized",
        @"user-read-birthdate",
        @"user-read-currently-playing",
        @"user-read-email",
        @"user-read-play-history",
        @"user-read-playback-position",
        @"user-read-playback-state",
        @"user-read-private",
        @"user-read-recently-played",
        @"user-top-read",
    ];
}

+ (NSString *)redirectURIForPort:(uint16_t)port {
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/login", (unsigned)port];
}

+ (NSURL *)authorizationURLWithEndpoint:(NSURL *)endpoint
                                   port:(uint16_t)port
                              challenge:(NSString *)challenge
                                  state:(NSString *)state {
    NSURLComponents *c = [NSURLComponents componentsWithURL:endpoint resolvingAgainstBaseURL:NO];
    if (!c) return nil;
    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client_id" value:SPKeymasterClientID],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:[self redirectURIForPort:port]],
        [NSURLQueryItem queryItemWithName:@"scope" value:[[self desktopScopes] componentsJoinedByString:@" "]],
        [NSURLQueryItem queryItemWithName:@"state" value:state],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:challenge],
    ];
    return c.URL;
}

+ (NSString *)authorizationCodeFromCallback:(NSURLComponents *)callback
                              expectedState:(NSString *)expectedState
                                      error:(NSError **)error {
    NSString *state = nil, *errParam = nil, *code = nil;
    for (NSURLQueryItem *qi in callback.queryItems) {
        if ([qi.name isEqualToString:@"state"]) state = qi.value;
        else if ([qi.name isEqualToString:@"error"]) errParam = qi.value;
        else if ([qi.name isEqualToString:@"code"]) code = qi.value;
    }
    if (!state || ![state isEqualToString:expectedState]) {
        if (error) *error = AuthError(SPAuthErrorStateMismatch, @"OAuth state parameter mismatch");
        return nil;
    }
    if (errParam.length) {
        if (error) *error = AuthError(SPAuthErrorDenied, [NSString stringWithFormat:@"Spotify denied authorization: %@", errParam]);
        return nil;
    }
    if (!code.length) {
        if (error) *error = AuthError(SPAuthErrorNoCode, @"OAuth redirect missing authorization code");
        return nil;
    }
    return code;
}

+ (NSData *)formURLEncodedBody:(NSDictionary<NSString *, NSString *> *)params {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *cs = [NSMutableCharacterSet alphanumericCharacterSet];
        [cs addCharactersInString:@"-._~"];
        allowed = [cs copy];
    });
    NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:params.count];
    NSArray<NSString *> *keys = [params.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *k in keys) {
        NSString *v = params[k];
        NSString *ek = [k stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: k;
        NSString *ev = [v stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: v;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", ek, ev]];
    }
    return [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
}

- (instancetype)initWithSecretStore:(id<SPSecretStore>)secretStore {
    return [self initWithSecretStore:secretStore session:nil urlSession:nil];
}

- (instancetype)initWithSecretStore:(id<SPSecretStore>)secretStore
                            session:(SPSessionBlob *)initialSession
                         urlSession:(NSURLSession *)urlSession {
    if (!(self = [super init])) return nil;
    _secretStore = secretStore;
    _session = initialSession;
    _deviceID = initialSession.deviceID.length ? [initialSession.deviceID copy] : [SPPKCE generateDeviceID];
    _persistUpdates = (secretStore != nil);
    _queue = dispatch_queue_create("local.spotify-native.auth", DISPATCH_QUEUE_SERIAL);
    _authorizeEndpoint = [NSURL URLWithString:@"https://accounts.spotify.com/authorize"];
    _tokenEndpoint = [NSURL URLWithString:@"https://accounts.spotify.com/api/token"];
    _clientTokenEndpoint = [NSURL URLWithString:@"https://clienttoken.spotify.com/v1/clienttoken"];
    if (urlSession) {
        _urlSession = urlSession;
    } else {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _urlSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (SPSessionBlob *)session {
    __block SPSessionBlob *s = nil;
    dispatch_sync(_queue, ^{ s = self->_session; });
    return s;
}

- (NSString *)deviceID {
    __block NSString *d = nil;
    dispatch_sync(_queue, ^{ d = self->_deviceID; });
    return d;
}

- (BOOL)isAuthorizing {
    __block BOOL active = NO;
    dispatch_sync(_queue, ^{ active = (self->_activeLoopbackServer != nil); });
    return active;
}

- (void)adoptSession:(SPSessionBlob *)session {
    dispatch_sync(_queue, ^{
        self->_authGeneration++;
        self->_session = session;
        if (session.deviceID.length) self->_deviceID = [session.deviceID copy];
    });
}

- (void)persistCurrentSessionOnQueue {
    if (_persistUpdates && _secretStore && _session) {
        SPSaveSessionBlobAsync(_session, _secretStore, nil);
    }
}

+ (NSError *)tokenFailureForStatus:(NSInteger)status body:(NSData *)body {
    NSDictionary *d = body.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:body options:0 error:nil]) : nil;
    if ([SPJSONString(d[@"error"]) isEqualToString:@"invalid_grant"]) {
        return AuthError(SPAuthErrorGrantRevoked, @"Spotify session expired or revoked (invalid_grant)");
    }
    NSString *msg = body.length ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : @"";
    return AuthError(SPAuthErrorTokenExchangeFailed, [NSString stringWithFormat:@"HTTP %ld: %@", (long)status, msg ?: @""]);
}

- (void)postTokenParams:(NSDictionary<NSString *, NSString *> *)params
   fallbackRefreshToken:(NSString *)fallbackRefresh
     expectedGeneration:(uint64_t)expectedGen
             completion:(void (^)(SPSessionBlob *_Nullable blob, NSError *_Nullable error))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.tokenEndpoint];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [SPAuth formURLEncodedBody:params];

    [[_urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *netErr) {
        if (netErr) {
            DispatchAuthCallback(^{ if (completion) completion(nil, netErr); });
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (!http || http.statusCode != 200) {
            NSError *statusErr = [SPAuth tokenFailureForStatus:http ? http.statusCode : -1 body:data];
            DispatchAuthCallback(^{ if (completion) completion(nil, statusErr); });
            return;
        }
        NSDictionary *json = data.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSString *access = SPJSONString(json[@"access_token"]);
        NSString *refresh = SPJSONString(json[@"refresh_token"]) ?: fallbackRefresh;
        if (!access.length || !refresh.length) {
            NSError *malErr = AuthError(SPAuthErrorMalformedResponse, @"Token response missing access_token or refresh_token");
            DispatchAuthCallback(^{ if (completion) completion(nil, malErr); });
            return;
        }
        double expiresIn = SPJSONDouble(json[@"expires_in"], 3600.0);
        NSString *username = SPJSONString(json[@"username"]);
        NSTimeInterval expiresAt = NSDate.date.timeIntervalSince1970 + expiresIn;

        dispatch_async(self->_queue, ^{
            if (self->_authGeneration != expectedGen) {
                NSError *staleErr = AuthError(SPAuthErrorNotSignedIn, @"Session signed out during token exchange");
                DispatchAuthCallback(^{ if (completion) completion(nil, staleErr); });
                return;
            }
            SPSessionBlob *updated = self->_session
                ? [self->_session withAccessToken:access refreshToken:refresh expiresAt:expiresAt username:username]
                : [[SPSessionBlob alloc] initWithAccessToken:access
                                                refreshToken:refresh
                                        accessTokenExpiresAt:expiresAt
                                                    username:username ?: @""
                                                    deviceID:self->_deviceID
                                                 clientToken:nil
                                        clientTokenExpiresAt:0
                                                  soloistKey:nil];
            self->_session = updated;
            [self persistCurrentSessionOnQueue];
            DispatchAuthCallback(^{ if (completion) completion(updated, nil); });
        });
    }] resume];
}

- (void)cancelAuthorization {
    __block SPLoopbackServer *server = nil;
    dispatch_sync(_queue, ^{
        self->_authGeneration++;
        server = self->_activeLoopbackServer;
        self->_activeLoopbackServer = nil;
    });
    [server stop];
}

- (void)authorizeWithBrowserOpener:(BOOL (^)(NSURL *))opener
                           persist:(BOOL)persist
                           timeout:(NSTimeInterval)timeout
                        completion:(void (^)(SPSessionBlob *, NSError *))completion {
    SPLoopbackServer *server = [SPLoopbackServer new];
    NSError *startErr = nil;
    if (![server startWithError:&startErr]) {
        DispatchAuthCallback(^{ if (completion) completion(nil, startErr); });
        return;
    }

    NSString *verifier = [SPPKCE generateCodeVerifier];
    NSString *challenge = [SPPKCE codeChallengeForVerifier:verifier];
    NSString *state = [SPPKCE generateState];
    uint16_t port = server.port;

    NSURL *authURL = [SPAuth authorizationURLWithEndpoint:self.authorizeEndpoint port:port challenge:challenge state:state];
    if (!authURL) {
        [server stop];
        NSError *urlErr = AuthError(SPAuthErrorAuthorizationURLFailed, @"Could not construct authorization URL");
        DispatchAuthCallback(^{ if (completion) completion(nil, urlErr); });
        return;
    }

    __block SPLoopbackServer *previousServer = nil;
    __block uint64_t loginGen = 0;
    dispatch_sync(_queue, ^{
        previousServer = self->_activeLoopbackServer;
        self->_activeLoopbackServer = server;
        self->_persistUpdates = persist && (self->_secretStore != nil);
        loginGen = ++self->_authGeneration;
    });
    [previousServer stop];

    BOOL opened = opener ? opener(authURL) : [NSWorkspace.sharedWorkspace openURL:authURL];
    if (!opened) {
        dispatch_sync(_queue, ^{
            if (self->_activeLoopbackServer == server) self->_activeLoopbackServer = nil;
        });
        [server stop];
        NSError *openErr = AuthError(SPAuthErrorBrowserOpenFailed, @"Could not open browser for Spotify login");
        DispatchAuthCallback(^{ if (completion) completion(nil, openErr); });
        return;
    }

    [server waitForCallbackWithTimeout:timeout completion:^(NSURLComponents *callback, NSError *cbErr) {
        [server stop];
        __block BOOL stillCurrent = NO;
        dispatch_sync(self->_queue, ^{
            if (self->_activeLoopbackServer == server) self->_activeLoopbackServer = nil;
            stillCurrent = (self->_authGeneration == loginGen);
        });
        if (!stillCurrent) {
            NSError *cancelErr = AuthError(SPAuthErrorLoopbackFailed, @"Sign-in cancelled");
            DispatchAuthCallback(^{ if (completion) completion(nil, cancelErr); });
            return;
        }
        if (cbErr || !callback) {
            NSError *outErr = cbErr ?: AuthError(SPAuthErrorLoopbackFailed, @"No callback received");
            DispatchAuthCallback(^{ if (completion) completion(nil, outErr); });
            return;
        }
        NSError *codeErr = nil;
        NSString *code = [SPAuth authorizationCodeFromCallback:callback expectedState:state error:&codeErr];
        if (!code) {
            DispatchAuthCallback(^{ if (completion) completion(nil, codeErr); });
            return;
        }
        NSDictionary *params = @{
            @"grant_type" : @"authorization_code",
            @"code" : code,
            @"redirect_uri" : [SPAuth redirectURIForPort:port],
            @"client_id" : SPKeymasterClientID,
            @"code_verifier" : verifier,
        };
        [self postTokenParams:params fallbackRefreshToken:nil expectedGeneration:loginGen completion:^(SPSessionBlob *blob, NSError *err) {
            if (completion) completion(blob, err);
        }];
    }];
}

- (void)accessTokenWithCompletion:(void (^)(NSString *, NSError *))completion {
    dispatch_async(_queue, ^{
        SPSessionBlob *s = self->_session;
        if (!s || (!s.accessToken.length && !s.refreshToken.length)) {
            NSError *err = AuthError(SPAuthErrorNotSignedIn, @"Not signed in");
            DispatchAuthCallback(^{ if (completion) completion(nil, err); });
            return;
        }
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (s.accessToken.length && (s.accessTokenExpiresAt - now) > SPKeymasterRefreshBuffer) {
            NSString *tok = s.accessToken;
            DispatchAuthCallback(^{ if (completion) completion(tok, nil); });
            return;
        }
        if (!s.refreshToken.length) {
            NSError *err = AuthError(SPAuthErrorGrantRevoked, @"Missing refresh token");
            DispatchAuthCallback(^{ if (completion) completion(nil, err); });
            return;
        }
        if (!self->_refreshWaiters) self->_refreshWaiters = [NSMutableArray new];
        if (completion) [self->_refreshWaiters addObject:[completion copy]];
        if (self->_refreshWaiters.count > 1) return; // Join in-flight refresh.

        uint64_t gen = self->_authGeneration;
        NSString *refreshToken = s.refreshToken;
        NSDictionary *params = @{
            @"grant_type" : @"refresh_token",
            @"refresh_token" : refreshToken,
            @"client_id" : SPKeymasterClientID,
        };
        [self postTokenParams:params fallbackRefreshToken:refreshToken expectedGeneration:gen completion:^(SPSessionBlob *blob, NSError *err) {
            dispatch_async(self->_queue, ^{
                BOOL stale = (self->_authGeneration != gen);
                id<SPSecretStore> storeToDelete = nil;
                if (!stale && err && [err.domain isEqualToString:SPAuthErrorDomain] && err.code == SPAuthErrorGrantRevoked) {
                    self->_session = nil;
                    self->_authGeneration++;
                    if (self->_persistUpdates && self->_secretStore) storeToDelete = self->_secretStore;
                }
                NSArray *waiters = [self->_refreshWaiters copy];
                [self->_refreshWaiters removeAllObjects];
                if (storeToDelete) SPDeleteAllSessionsAsync(storeToDelete, nil);
                NSString *outTok = stale ? nil : blob.accessToken;
                NSError *outErr = stale ? AuthError(SPAuthErrorNotSignedIn, @"Signed out") : err;
                DispatchAuthCallback(^{
                    for (void (^w)(NSString *, NSError *) in waiters) {
                        w(outTok, outErr);
                    }
                });
            });
        }];
    });
}

- (void)clientTokenWithCompletion:(void (^)(NSString *, NSError *))completion {
    dispatch_async(_queue, ^{
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (self->_session.clientToken.length && self->_session.clientTokenExpiresAt > now) {
            NSString *ct = self->_session.clientToken;
            DispatchAuthCallback(^{ if (completion) completion(ct, nil); });
            return;
        }
        if (!self->_clientTokenWaiters) self->_clientTokenWaiters = [NSMutableArray new];
        if (completion) [self->_clientTokenWaiters addObject:[completion copy]];
        if (self->_clientTokenWaiters.count > 1) return; // Join in-flight client-token request.

        uint64_t gen = self->_authGeneration;
        NSString *devID = self->_deviceID;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.clientTokenEndpoint];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
        req.HTTPBody = [SPClientToken encodeRequestWithClientID:SPKeymasterClientID deviceID:devID];

        [[self->_urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *netErr) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSError *err = netErr;
            SPClientToken *granted = nil;
            if (!err) {
                if (!http || http.statusCode != 200) {
                    err = AuthError(SPAuthErrorTokenExchangeFailed,
                                    [NSString stringWithFormat:@"Client-Token HTTP %ld", (long)(http ? http.statusCode : -1)]);
                } else {
                    granted = [SPClientToken decodeResponseData:data now:NSDate.date.timeIntervalSince1970 error:&err];
                }
            }
            dispatch_async(self->_queue, ^{
                BOOL stale = (self->_authGeneration != gen);
                if (!stale && granted) {
                    if (self->_session) {
                        self->_session = [self->_session withClientToken:granted.token expiresAt:granted.expiresAt];
                    } else {
                        self->_session = [[SPSessionBlob alloc] initWithAccessToken:nil
                                                                       refreshToken:nil
                                                               accessTokenExpiresAt:0
                                                                           username:@""
                                                                           deviceID:self->_deviceID
                                                                        clientToken:granted.token
                                                               clientTokenExpiresAt:granted.expiresAt
                                                                         soloistKey:nil];
                    }
                    [self persistCurrentSessionOnQueue];
                }
                NSArray *waiters = [self->_clientTokenWaiters copy];
                [self->_clientTokenWaiters removeAllObjects];
                NSString *outTok = stale ? nil : granted.token;
                NSError *outErr = stale ? AuthError(SPAuthErrorNotSignedIn, @"Signed out") : err;
                DispatchAuthCallback(^{
                    for (void (^w)(NSString *, NSError *) in waiters) {
                        w(outTok, outErr);
                    }
                });
            });
        }] resume];
    });
}

- (void)invalidateClientTokenIfMatching:(NSString *)rejectedToken {
    if (!rejectedToken.length) return;
    dispatch_sync(_queue, ^{
        if ([self->_session.clientToken isEqualToString:rejectedToken]) {
            self->_session = [self->_session withClientToken:nil expiresAt:0];
            [self persistCurrentSessionOnQueue];
        }
    });
}

- (void)signOut {
    __block id<SPSecretStore> store = nil;
    __block SPLoopbackServer *server = nil;
    __block NSArray *refreshWaiters = nil;
    __block NSArray *clientWaiters = nil;
    dispatch_sync(_queue, ^{
        self->_authGeneration++;
        self->_session = nil;
        store = self->_secretStore;
        server = self->_activeLoopbackServer;
        self->_activeLoopbackServer = nil;
        refreshWaiters = [self->_refreshWaiters copy];
        [self->_refreshWaiters removeAllObjects];
        clientWaiters = [self->_clientTokenWaiters copy];
        [self->_clientTokenWaiters removeAllObjects];
    });
    [server stop];
    if (store) SPDeleteAllSessionsAsync(store, nil);
    if (refreshWaiters.count || clientWaiters.count) {
        NSError *err = AuthError(SPAuthErrorNotSignedIn, @"Signed out");
        DispatchAuthCallback(^{
            for (void (^w)(NSString *, NSError *) in refreshWaiters) w(nil, err);
            for (void (^w)(NSString *, NSError *) in clientWaiters) w(nil, err);
        });
    }
}

@end
