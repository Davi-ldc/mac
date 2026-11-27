// Sign-in's pure parts, the session's storage and token refresh, with Slack's answers stubbed by a
// URL protocol on a session of the tests' own (nothing reaches the network or the real Keychain).
#import "../net/stub.h"
#import "auth/keychain.h"
#import "auth/reauth.h"
#import "auth/signin.h"
#import "test.h"

/// The stubbed answer for each request: @{@"status", @"headers", @"body" (NSData or JSON object)},
/// or nil for a network failure.
static NSDictionary *_Nullable (^stubAnswer)(NSURLRequest *request);
static NSURLRequest *stubRequest;

@interface SNAuthStubProtocol : NSURLProtocol
@end

@implementation SNAuthStubProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    stubRequest = self.request;
    NSDictionary *answer = stubAnswer ? stubAnswer(self.request) : nil;
    if (!answer) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
        return;
    }
    id body = answer[@"body"];
    NSData *data = [body isKindOfClass:NSData.class] ? body : [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:[answer[@"status"] integerValue] ?: 200
                                                             HTTPVersion:@"HTTP/1.1" headerFields:answer[@"headers"]];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}
@end

static NSURLSession *StubbedSession(void) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[ SNAuthStubProtocol.class ];
    configuration.HTTPShouldSetCookies = NO;
    return [NSURLSession sessionWithConfiguration:configuration];
}

static void WaitFor(BOOL *done) {
    for (int i = 0; i < 200 && !*done; i++) SNSettle(0.01);
}

static NSHTTPCookie *Cookie(NSString *name, NSString *value, NSDate *expires, BOOL httpOnly) {
    NSMutableDictionary *properties = [@{NSHTTPCookieName : name, NSHTTPCookieValue : value, NSHTTPCookieDomain : @".slack.com",
                                         NSHTTPCookiePath : @"/", NSHTTPCookieSecure : @"TRUE"} mutableCopy];
    if (expires) properties[NSHTTPCookieExpires] = expires;
    if (httpOnly) properties[@"HttpOnly"] = @"TRUE";
    return [NSHTTPCookie cookieWithProperties:properties];
}

static SNSession *MadeUpSession(void) {
    SNSessionTeam *team = [SNSessionTeam teamWithJSON:@{@"id" : @"T0NORTHWND", @"token" : @"xoxc-made-up-1", @"url" : @"https://northwind-studio.slack.com/",
                                                        @"name" : @"Northwind Studio", @"domain" : @"northwind-studio", @"user_id" : @"U01ALEX"}];
    // Foundation caps a cookie's life at about 400 days, as Safari does.
    NSDate *expires = [NSDate dateWithTimeIntervalSince1970:floor(NSDate.date.timeIntervalSince1970) + 30 * 86400];
    NSArray *cookies = @[ Cookie(@"d", @"xoxd-made%2Fup%3D", expires, YES), Cookie(@"d-s", @"1795000000", nil, YES), Cookie(@"lc", @"1795000001", expires, NO) ];
    return [[SNSession alloc] initWithCookies:cookies teams:@[ team ] userAgent:SNSafariUserAgent()];
}

SN_TEST(AuthSessionRoundTripsThroughTheSecretStore) {
    SNMemorySecretStore *store = [SNMemorySecretStore new];
    SNExpect(SNLoadSession(store) == nil, "nothing stored, no session");
    SNSession *session = MadeUpSession();
    session.version = @{@"version_ts" : @"1795000000", @"version_hash" : @"0123abcd"};
    SNExpect(SNSaveSession(session, store), "saved");
    SNExpect([store.accounts isEqualToArray:@[ @"T0NORTHWND:U01ALEX" ]], "account is <team>:<user>");
    SNSession *loaded = SNLoadSession(store);
    SNExpect([[loaded teamWithID:@"T0NORTHWND"].token isEqualToString:@"xoxc-made-up-1"], "token kept");
    SNExpect([[loaded teamWithID:@"T0NORTHWND"].url.absoluteString isEqualToString:@"https://northwind-studio.slack.com/"], "workspace URL kept");
    SNExpect([loaded.userAgent isEqualToString:SNSafariUserAgent()], "user agent kept");
    SNExpect([loaded.version[@"version_hash"] isEqualToString:@"0123abcd"], "version values kept");
    NSHTTPCookie *d = nil;
    for (NSHTTPCookie *cookie in loaded.cookies)
        if ([cookie.name isEqualToString:@"d"]) d = cookie;
    SNExpect(loaded.cookies.count == 3, "every cookie kept");
    SNExpect([d.value isEqualToString:@"xoxd-made%2Fup%3D"], "d kept URL-encoded, as stored");
    NSHTTPCookie *original = MadeUpSession().cookies.firstObject;
    SNExpect(d.isHTTPOnly && d.isSecure && fabs([d.expiresDate timeIntervalSinceDate:original.expiresDate]) < 1, "HttpOnly, Secure and expiry kept");
    NSString *header = [loaded cookieHeaderForURL:[NSURL URLWithString:@"https://northwind-studio.slack.com/api/client.counts"]];
    SNExpect([header containsString:@"d=xoxd-made%2Fup%3D"], "the loaded jar sends d");
    SNExpect([SNSession sessionWithData:[@"{\"cookies\":[]}" dataUsingEncoding:NSUTF8StringEncoding]] == nil, "data without teams is no session");
}

SN_TEST(AuthKeepsTheSignedInWorkspaceFirst) {
    SNSessionTeam *org = [SNSessionTeam teamWithJSON:@{@"id" : @"E0ORG", @"token" : @"xoxc-made-up-org", @"url" : @"https://org.enterprise.slack.com/", @"user_id" : @"U01ALEX"}];
    SNSessionTeam *workspace = [SNSessionTeam teamWithJSON:@{@"id" : @"T0NORTHWND", @"token" : @"xoxc-made-up-1", @"url" : @"https://northwind-studio.slack.com/",
                                                             @"user_id" : @"U01ALEX"}];
    NSArray *teams = SNTeamsWithFirst(@[ org, workspace ], SNTeamIDFromClientURL([NSURL URLWithString:@"https://app.slack.com/client/T0NORTHWND/C01GENERAL"]));
    SNSession *session = [[SNSession alloc] initWithCookies:@[] teams:teams userAgent:SNSafariUserAgent()];
    SNSession *loaded = [SNSession sessionWithData:session.data];
    SNExpect([loaded.teams.firstObject.teamID isEqualToString:@"T0NORTHWND"] && [loaded.account isEqualToString:@"T0NORTHWND:U01ALEX"],
             "the workspace the web client opened stays first through the Keychain, though E sorts before T");
}

SN_TEST(AuthSaveReplacesAnotherAccount) {
    SNMemorySecretStore *store = [SNMemorySecretStore new];
    [store setData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding] forAccount:@"T9OLD:U9OLD"];
    SNExpect(SNLoadSession(store) == nil, "an unreadable item is no session");
    SNSaveSession(MadeUpSession(), store);
    SNExpect([store.accounts isEqualToArray:@[ @"T0NORTHWND:U01ALEX" ]], "the older account is deleted");
    SNSaveSession(MadeUpSession(), store);
    SNExpect(store.accounts.count == 1 && SNLoadSession(store) != nil, "saving again updates in place");
}

SN_TEST(AuthReadsTheWebClientConfig) {
    NSString *config = @"{\"teams\":{"
                       @"\"T0NORTHWND\":{\"id\":\"T0NORTHWND\",\"name\":\"Northwind Studio\",\"token\":\"xoxc-made-up-1\","
                       @"\"url\":\"https://northwind-studio.slack.com/\",\"domain\":\"northwind-studio\",\"user_id\":\"U01ALEX\",\"icon\":{}},"
                       @"\"T0SECOND\":{\"name\":\"Second\",\"token\":\"xoxc-made-up-2\",\"domain\":\"second-example\",\"enterprise_id\":\"E0ORG\"},"
                       @"\"T0NOTOKEN\":{\"name\":\"No token\",\"url\":\"https://no-token.slack.com/\"}},\"lastActiveTeamId\":\"T0NORTHWND\"}";
    NSArray<SNSessionTeam *> *teams = SNTeamsFromLocalConfig(config);
    SNExpect(teams.count == 2, "teams with tokens, one without left out");
    SNExpect([teams[0].teamID isEqualToString:@"T0NORTHWND"] && [teams[0].userID isEqualToString:@"U01ALEX"], "team and user");
    SNExpect([teams[1].teamID isEqualToString:@"T0SECOND"], "team ID from the key when the entry has none");
    SNExpect([teams[1].url.absoluteString isEqualToString:@"https://second-example.slack.com/"], "URL from the domain");
    SNExpect([teams[1].enterpriseID isEqualToString:@"E0ORG"], "enterprise");
    SNExpect(teams[0].json[@"icon"] == nil, "only the session's fields are kept");
    SNExpect(SNTeamsFromLocalConfig(@"not json").count == 0 && SNTeamsFromLocalConfig(nil).count == 0, "garbage reads as nothing");
    SNExpect([SNTeamIDFromClientURL([NSURL URLWithString:@"https://app.slack.com/client/T0NORTHWND/C01GENERAL"]) isEqualToString:@"T0NORTHWND"], "team of the client URL");
    SNExpect(SNTeamIDFromClientURL([NSURL URLWithString:@"https://slack.com/signin"]) == nil, "no team before the client");
    NSDictionary *auth = @{@"ok" : @YES, @"teams" : @{@"T0NORTHWND" : @{@"token" : @"xoxc-made-up-3"}}};
    SNExpect([SNTokenFromAuthResponse(auth, @"T0NORTHWND") isEqualToString:@"xoxc-made-up-3"], "token from /auth");
    SNExpect(SNTokenFromAuthResponse(auth, @"T0OTHER") == nil, "no token for another team");
}

SN_TEST(AuthReadsMagicTokensFromTheCallback) {
    NSArray *tokens = SNMagicTokensFromCallbackURL([NSURL URLWithString:@"slack://T0NORTHWND/magic-login/z-app-T0NORTHWND-0123456789"]);
    SNExpect([tokens isEqualToArray:@[ @"z-app-T0NORTHWND-0123456789" ]], "token in the path");
    tokens = SNMagicTokensFromCallbackURL([NSURL URLWithString:@"slack://magic-login?magic_tokens=z-app-T1-aa,z-app-T2-bb&x=1"]);
    SNExpect(([tokens isEqualToArray:@[ @"z-app-T1-aa", @"z-app-T2-bb" ]]), "comma-separated tokens in the query");
    SNExpect(SNMagicTokensFromCallbackURL([NSURL URLWithString:@"slack://open?team=T1"]).count == 0, "no token, nothing");
    tokens = SNMagicTokensFromCallbackURL([NSURL URLWithString:@"slack://T0NORTHWND/magic-login/0123456789-abcdef?x=1"]);
    SNExpect([tokens isEqual:@[ @"z-app-T0NORTHWND-0123456789-abcdef" ]], "a bare key becomes z-app-<team>-<key>");
}

SN_TEST(AuthDecodesLoginMagicBulk) {
    NSDictionary *response = @{@"ok" : @YES, @"token_results" : @{
        @"T0NORTHWND" : @{@"ok" : @YES, @"token" : @"xoxc-made-up-1", @"user_id" : @"U01ALEX",
                          @"team" : @{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}},
        @"T0SECOND" : @{@"ok" : @YES, @"token" : @"xoxc-made-up-2", @"user" : @{@"id" : @"U09SECOND"},
                        @"team" : @{@"url" : @"https://second.enterprise.slack.com/", @"enterprise_id" : @"E0ORG"}},
        @"T0FAILED" : @{@"ok" : @NO, @"error" : @"expired_token"}}};
    NSArray<SNSessionTeam *> *teams = SNSessionTeamsFromLoginMagicBulk(response);
    SNExpect(teams.count == 2, "failed results left out");
    SNExpect([teams[0].url.absoluteString isEqualToString:@"https://northwind-studio.slack.com/"] && [teams[0].userID isEqualToString:@"U01ALEX"], "URL from the domain, user");
    SNExpect([teams[1].teamID isEqualToString:@"T0SECOND"] && [teams[1].userID isEqualToString:@"U09SECOND"] && [teams[1].enterpriseID isEqualToString:@"E0ORG"],
             "team from the key, user object, enterprise");
    SNExpect(SNSessionTeamsFromLoginMagicBulk(@{@"ok" : @NO}).count == 0, "nothing signed in");
}

SN_TEST(AuthExchangesMagicTokensForASession) {
    stubAnswer = ^NSDictionary *(NSURLRequest *request) {
        if (![request.URL.path isEqualToString:@"/api/auth.loginMagicBulk"]) return nil;
        NSString *cookies = @"d=xoxd-made%2Fup; Domain=.slack.com; Path=/; Expires=Wed, 01 Jan 2031 00:00:00 GMT; Secure; HttpOnly, "
                            @"d-s=1795000000; Domain=.slack.com; Path=/; Secure; HttpOnly";
        return @{@"headers" : @{@"Set-Cookie" : cookies, @"Content-Type" : @"application/json"},
                 @"body" : @{@"ok" : @YES, @"token_results" : @{@"T0NORTHWND" : @{@"ok" : @YES, @"token" : @"xoxc-made-up-1", @"user_id" : @"U01ALEX",
                                                                                   @"team" : @{@"id" : @"T0NORTHWND", @"domain" : @"northwind-studio"}}}}};
    };
    __block SNSession *session = nil;
    __block BOOL done = NO;
    SNExchangeMagicTokens(@[ @"z-app-T0NORTHWND-0123456789" ], SNSafariUserAgent(), StubbedSession(), ^(SNSession *result) {
        session = result;
        done = YES;
    });
    WaitFor(&done);
    NSURLComponents *sent = [NSURLComponents componentsWithURL:stubRequest.URL resolvingAgainstBaseURL:NO];
    SNExpect([sent.host isEqualToString:@"slack.com"] && [sent.percentEncodedQuery containsString:@"magic_tokens=z-app-T0NORTHWND-0123456789"] &&
                 [sent.percentEncodedQuery containsString:@"ssb=1"], "auth.loginMagicBulk with the tokens and ssb=1");
    SNExpect([[stubRequest valueForHTTPHeaderField:@"User-Agent"] isEqualToString:SNSafariUserAgent()], "sign-in's user agent");
    SNExpect([[session teamWithID:@"T0NORTHWND"].token isEqualToString:@"xoxc-made-up-1"], "token per team");
    NSString *header = [session cookieHeaderForURL:[NSURL URLWithString:@"https://northwind-studio.slack.com/api/auth.test"]];
    SNExpect([header containsString:@"d=xoxd-made%2Fup"] && [header containsString:@"d-s=1795000000"], "the answer's cookies are the jar");

    stubAnswer = ^NSDictionary *(NSURLRequest *request) { return @{@"body" : @{@"ok" : @NO, @"error" : @"invalid_magic_token"}}; };
    done = NO;
    session = MadeUpSession();
    SNExchangeMagicTokens(@[ @"z-app-T0-x" ], SNSafariUserAgent(), StubbedSession(), ^(SNSession *result) {
        session = result;
        done = YES;
    });
    WaitFor(&done);
    SNExpect(done && session == nil, "a refused token signs nothing in");
    stubAnswer = nil;
}

SN_TEST(AuthRefreshesATokenFromTheCookie) {
    SNSession *session = MadeUpSession();
    __block NSInteger changes = 0;
    session.onChange = ^(SNSession *changed) { changes++; };
    stubAnswer = ^NSDictionary *(NSURLRequest *request) {
        if (![request.URL.host isEqualToString:@"app.slack.com"] || ![request.URL.path isEqualToString:@"/auth"]) return nil;
        return @{@"headers" : @{@"Set-Cookie" : @"d-s=1795000999; Domain=.slack.com; Path=/; Secure; HttpOnly"},
                 @"body" : @{@"ok" : @YES, @"teams" : @{@"T0NORTHWND" : @{@"token" : @"xoxc-made-up-fresh"}}}};
    };
    __block BOOL done = NO, refreshed = NO;
    SNRefreshToken(session, @"T0NORTHWND", StubbedSession(), ^(BOOL result) {
        refreshed = result;
        done = YES;
    });
    WaitFor(&done);
    NSURLComponents *sent = [NSURLComponents componentsWithURL:stubRequest.URL resolvingAgainstBaseURL:NO];
    SNExpect([sent.percentEncodedQuery containsString:@"app=client"] && [sent.percentEncodedQuery containsString:@"teams=T0NORTHWND"] &&
                 [sent.percentEncodedQuery containsString:@"response_type=json"], "the web client's /auth for the team");
    SNExpect([[stubRequest valueForHTTPHeaderField:@"Cookie"] containsString:@"d=xoxd-made%2Fup%3D"], "sent with the d cookie as stored");
    SNExpect(refreshed && [[session teamWithID:@"T0NORTHWND"].token isEqualToString:@"xoxc-made-up-fresh"], "fresh token stored");
    SNExpect([[session cookieHeaderForURL:[NSURL URLWithString:@"https://app.slack.com/"]] containsString:@"d-s=1795000999"], "rotated cookie taken");
    SNExpect(changes >= 2, "cookie and token changes reach onChange (the Keychain write-back)");

    stubAnswer = ^NSDictionary *(NSURLRequest *request) { return @{@"body" : @{@"ok" : @YES, @"teams" : @{@"T0NORTHWND" : @{@"token" : @"xoxc-made-up-fresh"}}}}; };
    done = NO;
    SNRefreshToken(session, @"T0NORTHWND", StubbedSession(), ^(BOOL result) {
        refreshed = result;
        done = YES;
    });
    WaitFor(&done);
    SNExpect(done && !refreshed, "the token just refused, handed back, is no refresh");

    stubAnswer = ^NSDictionary *(NSURLRequest *request) { return @{@"body" : @{@"ok" : @NO, @"error" : @"not_authed"}}; };
    done = NO;
    SNRefreshToken(session, @"T0NORTHWND", StubbedSession(), ^(BOOL result) {
        refreshed = result;
        done = YES;
    });
    WaitFor(&done);
    SNExpect(done && !refreshed && [[session teamWithID:@"T0NORTHWND"].token isEqualToString:@"xoxc-made-up-fresh"], "no token back: NO, token kept");

    stubAnswer = nil;
    done = NO;
    SNRefreshToken(session, @"T0NORTHWND", StubbedSession(), ^(BOOL result) {
        refreshed = result;
        done = YES;
    });
    WaitFor(&done);
    SNExpect(done && !refreshed, "offline: NO");
}

SN_TEST(AuthUsesSafarisUserAgent) {
    NSString *agent = SNSafariUserAgent();
    SNExpect([agent hasPrefix:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/"], "Safari's frozen prefix");
    SNExpect([agent hasSuffix:@" Safari/605.1.15"], "Safari's suffix");
    NSString *version = [[agent componentsSeparatedByString:@"Version/"].lastObject componentsSeparatedByString:@" "].firstObject;
    SNExpect(version.integerValue >= 17, "a real Safari version");
}

/// Counts writes and where they ran.
@interface SNCountingSecretStore : SNMemorySecretStore
@property (atomic) NSInteger writes, writesOnMain;
@end

@implementation SNCountingSecretStore
- (BOOL)setData:(NSData *)data forAccount:(NSString *)account {
    self.writes++;
    if (NSThread.isMainThread) self.writesOnMain++;
    return [super setData:data forAccount:account];
}
@end

SN_TEST(AuthSavesTheSessionOffTheMainThreadInBursts) {
    SNSession *session = MadeUpSession();
    SNCountingSecretStore *store = [SNCountingSecretStore new];
    SNSessionSaver *saver = [[SNSessionSaver alloc] initWithSession:session store:store delay:0.1];
    for (int i = 0; i < 20; i++) [saver sessionChanged];
    SNSettle(0.05);
    SNExpect(store.writes == 0, "nothing written at once");
    SNExpect(SNWaitUntil(1, ^BOOL { return store.writes == 1; }), "a burst of changes is one write");
    SNSettle(0.2);
    SNExpect(store.writes == 1 && store.writesOnMain == 0, "and it runs off the main thread");
    [session setToken:@"xoxc-made-up-2" forTeam:@"T0NORTHWND"];
    [saver sessionChanged];
    [saver flush];
    SNExpect(store.writes == 2 && [[SNLoadSession(store) teamWithID:@"T0NORTHWND"].token isEqualToString:@"xoxc-made-up-2"], "flush writes what is waiting at once");
    SNSettle(0.2);
    SNExpect(store.writes == 2, "and the write it replaced does not follow");
}

SN_TEST(AuthSessionSaverCancelPreventsResurrection) {
    SNSession *session = MadeUpSession();
    SNCountingSecretStore *store = [SNCountingSecretStore new];
    SNSessionSaver *saver = [[SNSessionSaver alloc] initWithSession:session store:store delay:0.08];
    [saver sessionChanged];
    [saver cancel];
    [store deleteAccount:session.account];
    SNSettle(0.2);
    SNExpect(store.writes == 0 && SNLoadSession(store) == nil, "cancel blocks a pending scheduled write after sign-out");
    [saver sessionChanged];
    [saver flush];
    SNSettle(0.15);
    SNExpect(store.writes == 0 && SNLoadSession(store) == nil, "cancelled saver ignores later changes and flushes");
}
