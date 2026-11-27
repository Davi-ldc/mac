// Keychain single-blob storage, Keymaster PKCE OAuth, Client-Token protobuf, Pathfinder/spclient transport, and SPSearchController tests.
#import "test.h"
#import "mockserver.h"
#import "auth/auth.h"
#import "auth/keychain.h"
#import "model/protobuf.h"
#import "net/client.h"
#import "net/search.h"
#import "store/store.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static NSData *BuildGrantedClientTokenProtobuf(NSString *token, uint64_t expiresAfterSeconds) {
    return [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeVarint:1 field:1]; // RESPONSE_GRANTED_TOKEN
        [w writeMessageField:2 block:^(SPProtobufWriter *g) {
            [g writeString:token field:1];
            [g writeVarint:expiresAfterSeconds field:2];
        }];
    }];
}

static void SendLoopbackGET(uint16_t port, NSString *pathAndQuery) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(port);
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            NSString *req = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nConnection: close\r\n\r\n",
                             pathAndQuery, (unsigned)port];
            NSData *d = [req dataUsingEncoding:NSUTF8StringEncoding];
            send(fd, d.bytes, d.length, 0);
            uint8_t sink[512];
            recv(fd, sink, sizeof(sink), 0);
        }
        close(fd);
    });
}

@interface SPTestSearchDelegate : NSObject <SPSearchControllerDelegate>
@property (nonatomic, strong) NSMutableArray<SPSearchResults *> *updates;
@property (nonatomic, strong) NSMutableArray<NSError *> *errors;
@end

@implementation SPTestSearchDelegate
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _updates = [NSMutableArray new];
    _errors = [NSMutableArray new];
    return self;
}
- (void)searchController:(SPSearchController *)controller didUpdateResults:(SPSearchResults *)results {
    (void)controller;
    [_updates addObject:results];
}
- (void)searchController:(SPSearchController *)controller didFailRemoteWithError:(NSError *)error forQuery:(NSString *)query {
    (void)controller; (void)query;
    [_errors addObject:error];
}
@end

SP_TEST(KeychainSingleBlobAndOffMainThreadRead) {
    SPMemorySecretStore *secrets = [SPMemorySecretStore new];
    SPSessionBlob *blob = [[SPSessionBlob alloc] initWithAccessToken:@"acc-1"
                                                        refreshToken:@"ref-1"
                                                accessTokenExpiresAt:2000000000.0
                                                            username:@"alice"
                                                            deviceID:@"0123456789abcdef0123456789abcdef01234567"
                                                         clientToken:@"ct-1"
                                                clientTokenExpiresAt:2000003600.0
                                                          soloistKey:@"sol-secret"];
    SPExpect(SPSaveSessionBlob(blob, secrets), @"session blob saved");
    SPExpectEqualInt(secrets.writeCount, 1, "single Keychain write");
    SPExpectEqualInt(secrets.accounts.count, 1, "exactly one Keychain item");

    // Verify off-main-thread load performs ONE read.
    __block SPSessionBlob *loaded = nil;
    __block BOOL callbackOnMain = NO;
    __block BOOL done = NO;
    SPLoadSessionBlobAsync(secrets, ^(SPSessionBlob *b) {
        loaded = b;
        callbackOnMain = NSThread.isMainThread;
        done = YES;
    });
    SPExpect(SPWaitUntil(2.0, ^BOOL { return done; }), @"async session load completed");
    SPExpect(callbackOnMain, @"completion delivered on main thread");
    SPExpectEqualInt(secrets.readCount, 1, "entire session read in ONE secret-store call");
    SPExpectEqualStr(loaded.accessToken, @"acc-1", "accessToken round-tripped");
    SPExpectEqualStr(loaded.refreshToken, @"ref-1", "refreshToken round-tripped");
    SPExpectEqualStr(loaded.clientToken, @"ct-1", "clientToken round-tripped");
    SPExpectEqualStr(loaded.soloistKey, @"sol-secret", "soloistKey round-tripped");
    SPExpectEqualStr(loaded.deviceID, @"0123456789abcdef0123456789abcdef01234567", "deviceID round-tripped");
}

SP_TEST(AuthPKCELoopbackFlowAndEphemeralProbeMode) {
    // Verify RFC 7636 S256 test vector.
    NSString *rfcVerifier = @"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    SPExpectEqualStr([SPPKCE codeChallengeForVerifier:rfcVerifier],
                     @"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                     "PKCE S256 matches RFC 7636 vector");
    SPExpectEqualInt([SPPKCE generateDeviceID].length, 40, "deviceID is 40 hex chars");

    // State mismatch rejection.
    NSURLComponents *badCB = [SPLoopbackServer parseHTTPRequestLine:@"GET /login?code=abc&state=wrong HTTP/1.1\r\n"];
    NSError *stateErr = nil;
    SPExpect([SPAuth authorizationCodeFromCallback:badCB expectedState:@"expected" error:&stateErr] == nil, @"state mismatch rejected");
    SPExpectEqualInt(stateErr.code, SPAuthErrorStateMismatch, "state mismatch error code");

    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock auth server started");
    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.path isEqualToString:@"/api/token"]) {
            NSString *body = req.bodyString ?: @"";
            if ([body containsString:@"grant_type=authorization_code"] &&
                [body containsString:@"code=mock-auth-code"] &&
                [body containsString:@"code_verifier="]) {
                return [SPMockResponse responseWithStatus:200 json:@{
                    @"access_token" : @"bearer-from-pkce",
                    @"refresh_token" : @"refresh-initial",
                    @"expires_in" : @3600,
                    @"username" : @"davi",
                }];
            }
            return [SPMockResponse responseWithStatus:400 json:@{@"error" : @"invalid_grant"}];
        }
        return [SPMockResponse responseWithStatus:404 json:@{}];
    };

    // Ephemeral mode (persist:NO) used by fairplay_probe --oauth-login must write ZERO Keychain items.
    SPMemorySecretStore *ephemeralSecrets = [SPMemorySecretStore new];
    SPAuth *ephemeralAuth = [[SPAuth alloc] initWithSecretStore:ephemeralSecrets];
    ephemeralAuth.authorizeEndpoint = [server urlForPath:@"/authorize"];
    ephemeralAuth.tokenEndpoint = [server urlForPath:@"/api/token"];

    __block SPSessionBlob *authedBlob = nil;
    __block NSError *authedErr = nil;
    __block BOOL done = NO;
    [ephemeralAuth authorizeWithBrowserOpener:^BOOL(NSURL *url) {
        NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *state = nil, *redir = nil, *clientID = nil, *method = nil;
        for (NSURLQueryItem *qi in comps.queryItems) {
            if ([qi.name isEqualToString:@"state"]) state = qi.value;
            else if ([qi.name isEqualToString:@"redirect_uri"]) redir = qi.value;
            else if ([qi.name isEqualToString:@"client_id"]) clientID = qi.value;
            else if ([qi.name isEqualToString:@"code_challenge_method"]) method = qi.value;
        }
        SPExpectEqualStr(clientID, SPKeymasterClientID, "desktop client_id sent");
        SPExpectEqualStr(method, @"S256", "S256 challenge method sent");
        NSURLComponents *redirComps = [NSURLComponents componentsWithString:redir ?: @""];
        uint16_t port = (uint16_t)redirComps.port.unsignedIntValue;
        SPExpect(port > 0, @"ephemeral loopback port allocated");
        SendLoopbackGET(port, [NSString stringWithFormat:@"/login?code=mock-auth-code&state=%@", state]);
        return YES;
    } persist:NO timeout:5.0 completion:^(SPSessionBlob *blob, NSError *error) {
        authedBlob = blob;
        authedErr = error;
        done = YES;
    }];

    SPExpect(SPWaitUntil(5.0, ^BOOL { return done; }), @"PKCE loopback OAuth completed");
    SPExpect(authedErr == nil && [authedBlob.accessToken isEqualToString:@"bearer-from-pkce"], @"PKCE token obtained");
    SPExpectEqualInt(ephemeralSecrets.writeCount, 0, "persist:NO writes nothing to secret store");

    [server stop];
}

SP_TEST(AuthRefreshTokenRotationAndCoalescing) {
    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock refresh server started");
    __block int refreshHits = 0;
    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.path isEqualToString:@"/api/token"]) {
            refreshHits++;
            SPMockResponse *resp = [SPMockResponse responseWithStatus:200 json:@{
                @"access_token" : @"bearer-rotated-2",
                @"refresh_token" : @"refresh-rotated-2",
                @"expires_in" : @3600,
            }];
            resp.delaySeconds = 0.05;
            return resp;
        }
        return [SPMockResponse responseWithStatus:404 json:@{}];
    };

    SPMemorySecretStore *secrets = [SPMemorySecretStore new];
    // Access token already expired -> triggers automatic refresh & rotation.
    SPSessionBlob *expired = [[SPSessionBlob alloc] initWithAccessToken:@"bearer-old"
                                                           refreshToken:@"refresh-old"
                                                   accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 - 60.0
                                                               username:@"davi"
                                                               deviceID:[SPPKCE generateDeviceID]
                                                            clientToken:nil
                                                   clientTokenExpiresAt:0
                                                             soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets session:expired urlSession:nil];
    auth.tokenEndpoint = [server urlForPath:@"/api/token"];

    __block NSString *t1 = nil, *t2 = nil;
    __block int finished = 0;
    [auth accessTokenWithCompletion:^(NSString *tok, NSError *err) { (void)err; t1 = tok; finished++; }];
    [auth accessTokenWithCompletion:^(NSString *tok, NSError *err) { (void)err; t2 = tok; finished++; }];

    SPExpect(SPWaitUntil(3.0, ^BOOL { return finished == 2; }), @"both coalesced token waiters completed");
    SPExpectEqualInt(refreshHits, 1, "concurrent refreshes coalesced into 1 HTTP POST");
    SPExpectEqualStr(t1, @"bearer-rotated-2", "waiter 1 got rotated access token");
    SPExpectEqualStr(t2, @"bearer-rotated-2", "waiter 2 got rotated access token");
    SPExpectEqualStr(auth.session.refreshToken, @"refresh-rotated-2", "rotated refresh token stored in memory");
    SPSessionBlob *persisted = SPLoadSessionBlob(secrets);
    SPExpectEqualStr(persisted.refreshToken, @"refresh-rotated-2", "rotated refresh token persisted to secret store");

    [server stop];
}

SP_TEST(AuthClientTokenProtobufAndChallenge) {
    NSData *reqPB = [SPClientToken encodeRequestWithClientID:SPKeymasterClientID deviceID:@"deadbeef"];
    SPExpect(reqPB.length > 20, @"Client-Token protobuf request encoded");
    uint64_t reqType = 0;
    SPExpect(SPProtobufFirstVarint(reqPB, 1, &reqType) && reqType == 1, @"request_type = CLIENT_DATA (1)");

    // Challenge response surfaces SPAuthErrorClientTokenChallenged.
    NSData *chalPB = [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeVarint:2 field:1]; // RESPONSE_CHALLENGES_UNSOLVED
    }];
    NSError *chalErr = nil;
    SPExpect([SPClientToken decodeResponseData:chalPB now:1000.0 error:&chalErr] == nil, @"challenged response fails");
    SPExpectEqualInt(chalErr.code, SPAuthErrorClientTokenChallenged, "challenged error code");

    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock clienttoken server started");
    __block int ctHits = 0;
    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        ctHits++;
        SPExpectEqualStr(req.headers[@"content-type"], @"application/x-protobuf", "protobuf Content-Type");
        NSData *pb = BuildGrantedClientTokenProtobuf([NSString stringWithFormat:@"ct-mock-%d", ctHits], 1209600);
        return [SPMockResponse responseWithStatus:200 contentType:@"application/x-protobuf" data:pb];
    };

    SPMemorySecretStore *secrets = [SPMemorySecretStore new];
    SPSessionBlob *initial = [[SPSessionBlob alloc] initWithAccessToken:@"acc-live"
                                                           refreshToken:@"ref-live"
                                                   accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                               username:@"davi"
                                                               deviceID:[SPPKCE generateDeviceID]
                                                            clientToken:nil
                                                   clientTokenExpiresAt:0
                                                             soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets session:initial urlSession:nil];
    auth.clientTokenEndpoint = [server urlForPath:@"/v1/clienttoken"];

    __block NSString *ct1 = nil;
    __block BOOL done = NO;
    [auth clientTokenWithCompletion:^(NSString *ct, NSError *err) { (void)err; ct1 = ct; done = YES; }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }), @"client token fetched");
    SPExpectEqualStr(ct1, @"ct-mock-1", "client token decoded from protobuf");
    SPExpectEqualStr(SPLoadSessionBlob(secrets).clientToken, @"ct-mock-1", "client token persisted inside single session blob");

    // Invalidating with stale token does not drop ct-mock-1.
    [auth invalidateClientTokenIfMatching:@"ct-stale"];
    SPExpectEqualStr(auth.session.clientToken, @"ct-mock-1", "non-matching invalidation ignored");

    // Invalidating with matching token causes a fresh fetch.
    [auth invalidateClientTokenIfMatching:@"ct-mock-1"];
    done = NO;
    __block NSString *ct2 = nil;
    [auth clientTokenWithCompletion:^(NSString *ct, NSError *err) { (void)err; ct2 = ct; done = YES; }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }), @"replacement client token fetched");
    SPExpectEqualStr(ct2, @"ct-mock-2", "replacement client token obtained");

    [server stop];
}

SP_TEST(NetClientPathfinderAndSpclientAndTokenRetry) {
    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock API server started");
    __block int ctGen = 0;
    __block int pfAttempt = 0;
    __block BOOL sawOptionsPreflight = NO;

    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.path isEqualToString:@"/v1/clienttoken"]) {
            ctGen++;
            return [SPMockResponse responseWithStatus:200
                                          contentType:@"application/x-protobuf"
                                                 data:BuildGrantedClientTokenProtobuf([NSString stringWithFormat:@"ct-%d", ctGen], 3600)];
        }
        if ([req.path isEqualToString:@"/pathfinder/v2/query"]) {
            NSDictionary *body = req.jsonBody;
            NSString *op = body[@"operationName"];
            if ([op isEqualToString:@"profileAttributes"]) {
                pfAttempt++;
                if (pfAttempt == 1) {
                    // Reject first client token to verify automatic client-token invalidation & single retry.
                    SPMockResponse *r = [SPMockResponse responseWithStatus:401 json:@{@"error" : @"expired_client_token"}];
                    r.headers = @{@"Content-Type" : @"application/json", @"client-token-error" : @"EXPIRED"};
                    return r;
                }
                return [SPMockResponse responseWithStatus:200 json:@{
                    @"data" : @{@"me" : @{@"profile" : @{@"username" : @"davi", @"name" : @"Davi", @"uri" : @"spotify:user:davi"}}}
                }];
            }
            if ([op isEqualToString:@"areEntitiesInLibrary"]) {
                return [SPMockResponse responseWithStatus:200 json:@{
                    @"data" : @{@"lookup" : @[ @{@"data" : @{@"saved" : @YES}}, @{@"data" : @{@"__typename" : @"NotFound"}} ]}
                }];
            }
            if ([op isEqualToString:@"addToLibrary"]) {
                return [SPMockResponse responseWithStatus:200 json:@{
                    @"data" : @{@"addLibraryItems" : @{@"__typename" : @"AddLibraryItemsResponse"}}
                }];
            }
            if ([op isEqualToString:@"getAlbum"]) {
                return [SPMockResponse responseWithStatus:200 json:@{
                    @"errors" : @[ @{@"message" : @"PersistedQueryNotFound", @"extensions" : @{@"code" : @"PERSISTED_QUERY_NOT_FOUND"}} ]
                }];
            }
        }
        if ([req.path hasPrefix:@"/metadata/4/track/"]) {
            if ([req.method isEqualToString:@"OPTIONS"]) {
                sawOptionsPreflight = YES;
                return [SPMockResponse responseWithStatus:204 contentType:@"" data:[NSData data]];
            }
            return [SPMockResponse responseWithStatus:200 json:@{
                @"name" : @"Never Gonna Give You Up",
                @"duration" : @213573,
                @"artist" : @[ @{@"name" : @"Rick Astley"} ],
                @"file" : @[ @{@"file_id" : @"0123456789abcdef0123456789abcdef01234567", @"format" : @"MP4_256_CBCS"} ],
            }];
        }
        if ([req.path hasPrefix:@"/context-resolve/v1/spotify%3Astation%3Atrack%3A"]) {
            return [SPMockResponse responseWithStatus:200 json:@{
                @"pages" : @[ @{@"tracks" : @[ @{@"uri" : @"spotify:track:rad1"}, @{@"uri" : @"spotify:track:rad2"} ]} ],
            }];
        }
        if ([req.path isEqualToString:@"/playlist/v2/playlist"]) {
            return [SPMockResponse responseWithStatus:200 json:@{@"uri" : @"spotify:playlist:newpl99"}];
        }
        return [SPMockResponse responseWithStatus:404 json:@{}];
    };

    SPSessionBlob *sess = [[SPSessionBlob alloc] initWithAccessToken:@"tok-ok"
                                                        refreshToken:@"ref-ok"
                                                accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                            username:@"davi"
                                                            deviceID:[SPPKCE generateDeviceID]
                                                         clientToken:@"ct-0-expired"
                                                clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                          soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new] session:sess urlSession:nil];
    auth.clientTokenEndpoint = [server urlForPath:@"/v1/clienttoken"];

    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    net.pathfinderURL = [server urlForPath:@"/pathfinder/v2/query"];
    net.spclientBaseURL = server.baseURL;
    net.retryDelays = @[];
    SPExpect(net.urlSession.configuration.URLCache == nil, @"URLCache disabled on SPNetClient session");

    // 1. Profile with automatic 401 client-token refresh & retry.
    __block SPUserProfile *prof = nil;
    __block NSError *err = nil;
    __block BOOL done = NO;
    [net fetchProfileWithCompletion:^(SPUserProfile *p, NSError *e) { prof = p; err = e; done = YES; }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }), @"profile fetch completed");
    SPExpect(err == nil && [prof.username isEqualToString:@"davi"], @"profile fetched after client-token retry");
    SPExpectEqualInt(pfAttempt, 2, "retried once after client-token 401");
    SPExpectEqualStr(auth.session.clientToken, @"ct-1", "client token refreshed during retry");

    // 2. Positional areEntitiesInLibrary + addToLibrary.
    done = NO;
    __block NSDictionary<NSString *, NSNumber *> *statuses = nil;
    [net checkEntitiesInLibrary:@[ @"spotify:track:t1", @"spotify:track:t2" ] completion:^(NSDictionary *s, NSError *e) {
        statuses = s; err = e; done = YES;
    }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }), @"areEntitiesInLibrary completed");
    SPExpect([statuses[@"t1"] boolValue] && ![statuses[@"t2"] boolValue], @"positional saved statuses decoded");

    done = NO;
    [net addToLibraryURIs:@[ @"spotify:track:t2" ] completion:^(NSError *e) { err = e; done = YES; }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }) && err == nil, @"addToLibrary accepted");

    // 3. Retired persisted query error detection.
    done = NO;
    [net fetchAlbumWithID:@"alb1" completion:^(SPAlbum *a, NSArray<SPTrack *> *t, NSError *e) { (void)a; (void)t; err = e; done = YES; }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }), @"retired hash call completed");
    SPExpectEqualInt(err.code, SPNetErrorPersistedQueryNotFound, "PersistedQueryNotFound surfaced distinctly");

    // 4. spclient metadata (with OPTIONS preflight), radio seed, and playlist/v2 create.
    done = NO;
    __block SPTrack *metaTrack = nil;
    [net fetchTrackMetadataWithID:@"4cOdK2wGLETKBW3PvgPWqT" completion:^(NSDictionary *raw, SPTrack *tr, NSError *e) {
        (void)raw; metaTrack = tr; err = e; done = YES;
    }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }) && err == nil, @"spclient metadata fetched");
    SPExpect(sawOptionsPreflight, @"OPTIONS preflight sent before metadata/4/track");
    SPExpectEqualStr(metaTrack.name, @"Never Gonna Give You Up", "metadata track name");

    done = NO;
    __block NSArray<NSString *> *radio = nil;
    [net fetchRadioSeedForTrackURI:@"spotify:track:4cOdK2wGLETKBW3PvgPWqT" deviceID:auth.deviceID completion:^(NSArray<NSString *> *r, NSError *e) {
        radio = r; err = e; done = YES;
    }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }) && err == nil, @"radio seed resolved");
    SPExpectEqualInt(radio.count, 2, "two radio tracks returned");

    done = NO;
    __block NSString *newPlID = nil;
    [net createPlaylistWithName:@"Road Trip" description:@"Fast" completion:^(NSString *pid, NSError *e) {
        newPlID = pid; err = e; done = YES;
    }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return done; }) && err == nil, @"playlist/v2 created");
    SPExpectEqualStr(newPlID, @"newpl99", "new playlist ID extracted from CreateListReply");

    [server stop];
}

SP_TEST(SearchControllerInstantLocalDebounceAndCancellation) {
    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock search server started");
    __block int desktopCalls = 0;
    __block NSMutableArray<NSString *> *seenQueries = [NSMutableArray new];

    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        NSDictionary *body = req.jsonBody;
        NSString *op = body[@"operationName"];
        NSString *term = body[@"variables"][@"searchTerm"] ?: body[@"variables"][@"query"] ?: @"";
        if ([op isEqualToString:@"searchDesktop"]) {
            desktopCalls++;
            @synchronized(seenQueries) { [seenQueries addObject:term]; }
            SPMockResponse *r = [SPMockResponse responseWithStatus:200 json:@{
                @"data" : @{
                    @"searchV2" : @{
                        @"tracksV2" : @{
                            @"totalCount" : @2,
                            @"items" : @[
                                @{@"item" : @{@"data" : @{@"id" : @"loc-1", @"uri" : @"spotify:track:loc-1", @"name" : @"Instant Crush", @"duration" : @{@"totalMilliseconds" : @337000}, @"artists" : @{@"items" : @[ @{@"profile" : @{@"name" : @"Daft Punk"}} ]}}}},
                                @{@"item" : @{@"data" : @{@"id" : [NSString stringWithFormat:@"rem-%@", term], @"uri" : [NSString stringWithFormat:@"spotify:track:rem-%@", term], @"name" : [NSString stringWithFormat:@"Remote %@ Hit", term], @"duration" : @{@"totalMilliseconds" : @200000}, @"artists" : @{@"items" : @[ @{@"profile" : @{@"name" : @"Remote Artist"}} ]}}}},
                            ],
                        },
                    },
                },
            }];
            // Delay "first" so typing "second" cancels/supersedes it in flight.
            if ([term isEqualToString:@"first"]) r.delaySeconds = 0.25;
            return r;
        }
        if ([op isEqualToString:@"searchSuggestions"]) {
            return [SPMockResponse responseWithStatus:200 json:@{
                @"data" : @{
                    @"searchV2" : @{
                        @"topResultsV2" : @{
                            @"itemsV2" : @[
                                @{@"item" : @{@"__typename" : @"SearchAutoCompleteEntity", @"data" : @{@"query" : [term stringByAppendingString:@" remix"]}}},
                            ],
                        },
                    },
                },
            }];
        }
        return [SPMockResponse responseWithStatus:404 json:@{}];
    };

    SPStore *store = [[SPStore alloc] initWithDatabase:nil];
    SPTrack *localTrack = [[SPTrack alloc] initWithTrackID:@"loc-1"
                                                       uri:@"spotify:track:loc-1"
                                                      name:@"Instant Crush"
                                                   albumID:nil albumName:@"RAM"
                                                  artistID:nil artistName:@"Daft Punk" artistNames:@[ @"Daft Punk" ]
                                                durationMs:337000 trackNumber:5 discNumber:1
                                                artworkURL:nil artworkSmallURL:nil
                                                  playable:YES unplayableReason:nil];
    [store upsertTracks:@[ localTrack ]];
    [store setLibraryTrackIDs:@[ @"loc-1" ] addedAtByID:nil];

    SPSessionBlob *sess = [[SPSessionBlob alloc] initWithAccessToken:@"tok" refreshToken:@"ref"
                                                accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                            username:@"davi" deviceID:[SPPKCE generateDeviceID]
                                                         clientToken:@"ct"
                                                clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                          soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new] session:sess urlSession:nil];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    net.pathfinderURL = [server urlForPath:@"/pathfinder/v2/query"];
    net.retryDelays = @[];

    SPSearchController *sc = [[SPSearchController alloc] initWithStore:store client:net];
    sc.debounceInterval = 0.040;
    SPTestSearchDelegate *del = [SPTestSearchDelegate new];
    sc.delegate = del;

    // 1. Rapid keystrokes: immediate synchronous local update, only final debounced query hits network.
    [sc updateQuery:@"i"];
    [sc updateQuery:@"in"];
    [sc updateQuery:@"instant"];
    SPExpect(del.updates.count >= 1 && del.updates.lastObject.isLocalOnly, @"synchronous local results delivered before debounce");
    SPExpectEqualInt(del.updates.lastObject.tracks.count, 1, "local match found immediately");

    SPExpect(SPWaitUntil(2.0, ^BOOL {
        return sc.currentResults != nil && !sc.currentResults.isLocalOnly &&
               sc.currentResults.tracks.count == 2 && sc.currentResults.suggestions.count == 1;
    }), @"debounced remote searchDesktop + searchSuggestions merged");
    SPExpectEqualInt(desktopCalls, 1, "debounce collapsed 3 keystrokes into 1 remote searchDesktop");
    SPExpectEqualInt(sc.currentResults.tracks.count, 2, "local and remote merged without duplicating loc-1");
    SPExpectEqualStr(sc.currentResults.suggestions[0].text, @"instant remix", "typeahead suggestion merged");

    // 2. Stale in-flight cancellation: fire "first" (slow), then supersede with "second" (fast).
    [sc updateQuery:@"first"];
    SPExpect(SPWaitUntil(1.0, ^BOOL {
        @synchronized(seenQueries) { return [seenQueries containsObject:@"first"]; }
    }), @"slow 'first' request sent to mock server");
    [sc updateQuery:@"second"];

    SPExpect(SPWaitUntil(2.0, ^BOOL {
        return [sc.currentResults.query isEqualToString:@"second"] && !sc.currentResults.isLocalOnly;
    }), @"'second' remote results arrived");
    // Wait past "first"'s 250ms delay to verify stale response never overwrites "second".
    SPWaitUntil(0.30, ^BOOL { return NO; });
    SPExpectEqualStr(sc.currentResults.query, @"second", "stale 'first' response dropped by generation counter");
    SPExpectEqualStr(sc.currentResults.tracks.lastObject.trackID, @"rem-second", "only 'second' remote tracks shown");

    [sc cancel];
    [server stop];
}

SP_TEST(AuthKeychainFileBasedFlagsNoDeadlockSignOutGenAndLoopbackProbes) {
    // 1. SPKeychain file-based login keychain query flags (BP-C1):
    // NEVER combine kSecReturnData = @YES with kSecMatchLimitAll (returns errSecParam -50 on macOS).
    SPSessionBlob *storedBlob = [[SPSessionBlob alloc] initWithAccessToken:@"tok-kc"
                                                              refreshToken:@"ref-kc"
                                                      accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600
                                                                  username:@"davi"
                                                                  deviceID:[SPPKCE generateDeviceID]
                                                               clientToken:nil
                                                      clientTokenExpiresAt:0
                                                                soloistKey:nil];
    NSData *blobData = [storedBlob toJSONData];
    __block BOOL sawInvalidCombo = NO;
    __block int copyMatchCalls = 0;

    SPKeychain *kc = [[SPKeychain alloc] initWithService:@"local.spotify-native.test.kc"
                                               fileBased:YES
                                            copyMatching:^OSStatus(CFDictionaryRef query, CFTypeRef *result) {
        copyMatchCalls++;
        NSDictionary *q = (__bridge NSDictionary *)query;
        BOOL retData = [q[(id)kSecReturnData] boolValue];
        BOOL limitAll = [q[(id)kSecMatchLimit] isEqual:(id)kSecMatchLimitAll];
        if (retData && limitAll) {
            sawInvalidCombo = YES;
            return errSecParam; // -50, matching macOS legacy login keychain
        }
        if (retData && [q[(id)kSecMatchLimit] isEqual:(id)kSecMatchLimitOne]) {
            if (result) *result = CFBridgingRetain([blobData copy]);
            return errSecSuccess;
        }
        return errSecItemNotFound;
    }];

    SPSessionBlob *loaded = SPLoadSessionBlob(kc);
    SPExpect(!sawInvalidCombo, @"SPKeychain never combines kSecReturnData with kSecMatchLimitAll");
    SPExpectEqualInt(copyMatchCalls, 1, "file-based keychain loaded session in 1 Keychain call");
    SPExpect(loaded != nil && [loaded.accessToken isEqualToString:@"tok-kc"], @"session loaded cleanly without errSecParam");

    // 2. SPAuth non-deadlocking callbacks & sign-out generation guard (BP-H4):
    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock auth server started");
    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.path isEqualToString:@"/api/token"]) {
            SPMockResponse *r = [SPMockResponse responseWithStatus:200 json:@{
                @"access_token" : @"tok-resurrected",
                @"refresh_token" : @"ref-resurrected",
                @"expires_in" : @3600,
            }];
            r.delaySeconds = 0.15;
            return r;
        }
        if ([req.path isEqualToString:@"/playlist/v2/playlist/pl1/changes"]) {
            NSDictionary *body = req.jsonBody;
            NSArray *deltas = body[@"deltas"];
            NSDictionary *op = deltas.firstObject[@"ops"][0];
            if ([op[@"kind"] isEqualToString:@"REM"] && [op[@"rem"][@"fromIndex"] integerValue] == 2) {
                return [SPMockResponse responseWithStatus:200 json:@{}];
            }
        }
        return [SPMockResponse responseWithStatus:404 json:@{}];
    };

    // Valid token -> synchronously accessing auth.session/deviceID inside completion must NOT deadlock!
    SPMemorySecretStore *mem1 = [SPMemorySecretStore new];
    SPAuth *auth1 = [[SPAuth alloc] initWithSecretStore:mem1 session:storedBlob urlSession:nil];
    __block BOOL reentrantDone = NO;
    __block NSString *reentrantDevID = nil;
    [auth1 accessTokenWithCompletion:^(NSString *tok, NSError *err) {
        (void)tok; (void)err;
        // Calls dispatch_sync(_queue) synchronously from inside completion callback!
        reentrantDevID = auth1.deviceID;
        (void)auth1.session;
        reentrantDone = YES;
    }];
    SPExpect(SPWaitUntil(2.0, ^BOOL { return reentrantDone; }), @"SPAuth completion ran off _queue without self-deadlock");
    SPExpectEqualStr(reentrantDevID, storedBlob.deviceID, "re-entrant auth.deviceID read succeeded");

    // Expired token -> start refresh, signOut mid-flight -> late response must NOT resurrect session!
    SPMemorySecretStore *mem2 = [SPMemorySecretStore new];
    SPSessionBlob *expired = [[SPSessionBlob alloc] initWithAccessToken:@"old"
                                                           refreshToken:@"ref-old"
                                                   accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 - 60
                                                               username:@"davi"
                                                               deviceID:[SPPKCE generateDeviceID]
                                                            clientToken:nil
                                                   clientTokenExpiresAt:0
                                                             soloistKey:nil];
    SPSaveSessionBlob(expired, mem2);
    SPAuth *auth2 = [[SPAuth alloc] initWithSecretStore:mem2 session:expired urlSession:nil];
    auth2.tokenEndpoint = [server urlForPath:@"/api/token"];

    __block BOOL refreshDone = NO;
    __block NSError *refreshErr = nil;
    [auth2 accessTokenWithCompletion:^(NSString *tok, NSError *err) {
        (void)tok;
        refreshErr = err;
        refreshDone = YES;
    }];
    SPWaitUntil(0.03, ^BOOL { return NO; });
    [auth2 signOut];
    SPExpect(SPWaitUntil(2.0, ^BOOL { return refreshDone; }), @"refresh callback finished after signOut");
    SPExpect(refreshErr != nil, @"refresh after signOut failed cleanly");
    SPExpect(auth2.session == nil, @"signOut prevented late token response from resurrecting session");
    SPWaitUntil(0.10, ^BOOL { return mem2.accounts.count == 0; });
    SPExpectEqualInt(mem2.accounts.count, 0, "async keychain delete cleared secret store without resurrection");

    // 3. SPLoopbackServer ignores non-/login browser probes (BP-H9):
    SPLoopbackServer *lb = [SPLoopbackServer new];
    NSError *lbErr = nil;
    SPExpect([lb startWithError:&lbErr], @"loopback server started");
    __block NSURLComponents *gotCallback = nil;
    [lb waitForCallbackWithTimeout:3.0 completion:^(NSURLComponents *cb, NSError *err) {
        (void)err;
        gotCallback = cb;
    }];
    SendLoopbackGET(lb.port, @"/apple-touch-icon.png");
    SendLoopbackGET(lb.port, @"/");
    SPWaitUntil(0.06, ^BOOL { return NO; });
    SPExpect(gotCallback == nil, @"non-/login probes did not abort loopback listener");
    SendLoopbackGET(lb.port, @"/login?code=validcode&state=s1");
    SPExpect(SPWaitUntil(2.0, ^BOOL { return gotCallback != nil; }), @"real /login callback succeeded after probes");
    SPExpectEqualStr(gotCallback.path, @"/login", "captured /login callback path");

    // 4. SPNetClient removeTrackURI via playlist/v2 changes (BP-H8):
    SPSessionBlob *netSess = [[SPSessionBlob alloc] initWithAccessToken:@"tok" refreshToken:@"ref"
                                                   accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600
                                                               username:@"davi" deviceID:[SPPKCE generateDeviceID]
                                                            clientToken:@"ct" clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600
                                                             soloistKey:nil];
    SPAuth *netAuth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new] session:netSess urlSession:nil];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:netAuth];
    net.spclientBaseURL = [server urlForPath:@"/"];
    __block BOOL rmDone = NO;
    __block NSError *rmErr = nil;
    [net removeTrackURI:@"spotify:track:t1" atIndex:2 uid:@"uid-item-42" fromPlaylistID:@"pl1" completion:^(NSError *err) {
        rmErr = err;
        rmDone = YES;
    }];
    SPExpect(SPWaitUntil(2.0, ^BOOL { return rmDone; }) && rmErr == nil, @"removeTrackURI sent playlist/v2 REM at index");

    [server stop];
}
