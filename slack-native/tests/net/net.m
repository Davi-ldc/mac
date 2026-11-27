// The HTTP client and the scheduler against a URLProtocol stub: request shape, cookie write-back
// and which cookies count, redirects, retries (reads only), token refresh and sign-out, rate
// limits, merging (reads only), disabled methods, timers in every run loop mode, the trace and its
// rotation, and read-only mode.
// Made-up tokens and cookies.
#import "net/client.h"
#import "net/switches.h"
#import "stub.h"
#import "test.h"

static NSHTTPCookie *Cookie(NSString *name, NSString *value) {
    return [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : name, NSHTTPCookieValue : value, NSHTTPCookieDomain : @".slack.com",
                                                NSHTTPCookiePath : @"/", NSHTTPCookieSecure : @"TRUE"}];
}

static SNSession *Session(void) {
    SNSessionTeam *team = [SNSessionTeam teamWithJSON:@{@"id" : @"T0NORTHWND", @"token" : @"xoxc-test-token", @"url" : @"https://northwind-studio.slack.com/",
                                                        @"user_id" : @"U01ALEX", @"domain" : @"northwind-studio"}];
    SNSession *session = [[SNSession alloc] initWithCookies:@[ Cookie(@"d", @"xoxd-made%2Bup%3D"), Cookie(@"d-s", @"1700000000") ] teams:@[ team ]
                                                  userAgent:@"Mozilla/5.0 (Macintosh) Test"];
    session.version = @{@"version_ts" : @"1795000000", @"version_hash" : @"0123456789abcdef"};
    return session;
}

static SNClient *Client(SNSession *session, SNStubHandler handler) {
    SNClient *client = [[SNClient alloc] initWithSession:session teamID:@"T0NORTHWND" urlSession:SNStubURLSession(handler)];
    client.retryDelays = @[ @0.01, @0.01 ];
    client.scheduler.backgroundInterval = 0;
    return client;
}

static NSDictionary *Body(NSDictionary *json) {
    NSMutableDictionary *body = [@{@"ok" : @YES} mutableCopy];
    [body addEntriesFromDictionary:json];
    return body;
}

static SNStubAnswer *OK(NSDictionary *json) { return [SNStubAnswer status:200 headers:@{@"Content-Type" : @"application/json"} json:Body(json)]; }

SN_TEST(NetBuildsWebClientRequests) {
    SNClient *client = Client(Session(), nil);
    NSURLRequest *request = [client requestForMethod:@"conversations.history" params:@{@"channel" : @"C01", @"_x_reason" : @"test-reason"} attempt:2];
    SNExpect([request.URL.host isEqualToString:@"northwind-studio.slack.com"] && [request.URL.path isEqualToString:@"/api/conversations.history"], "POST to the workspace host");
    SNExpect([request.HTTPMethod isEqualToString:@"POST"], "POST");
    NSString *query = request.URL.query;
    SNExpect([query containsString:@"_x_id=01234567-"], "_x_id starts with the version hash's first 8");
    SNExpect([query containsString:@"_x_version_ts=1795000000"] && [query containsString:@"_x_reason=test-reason"], "version ts and reason in the query");
    SNExpect([query containsString:@"slack_route=T0NORTHWND"] && [query containsString:@"_x_num_retries=2"] && [query containsString:@"_x_app_name=client"],
             "route, retries and app name");
    NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
    SNExpect([body containsString:@"token=xoxc-test-token"] && [body containsString:@"channel=C01"] && ![body containsString:@"_x_reason"], "token and params in the body");
    SNExpect([[request valueForHTTPHeaderField:@"Cookie"] isEqualToString:@"d=xoxd-made%2Bup%3D; d-s=1700000000"], "d sent exactly as stored");
    SNExpect([[request valueForHTTPHeaderField:@"User-Agent"] isEqualToString:@"Mozilla/5.0 (Macintosh) Test"], "the sign-in user agent");
    SNExpect([[request valueForHTTPHeaderField:@"Origin"] isEqualToString:@"https://app.slack.com"], "web client origin");
    SNExpect([client.session cookieHeaderForURL:[NSURL URLWithString:@"http://northwind-studio.slack.com/"]] == nil, "secure cookies never over http");
    SNExpect([client.session cookieHeaderForURL:[NSURL URLWithString:@"https://example.com/"]] == nil, "no cookies for other hosts");
}

SN_TEST(NetParsesWebClientVersion) {
    NSString *html = @"<!DOCTYPE html><html lang=\"en-US\" data-version-ts=\"1795000123\" data-version-hash=\"abcdef0123456789\" "
                     @"data-build-version-ts=\"1795000000\" class=\"no-js\"><head></head></html>";
    NSDictionary *version = SNWebClientVersion(html);
    SNExpect([version[@"version_ts"] isEqualToString:@"1795000123"] && [version[@"version_hash"] isEqualToString:@"abcdef0123456789"], "html data attributes");
    SNExpect([version[@"build_version_ts"] isEqualToString:@"1795000000"], "dashes become underscores");
    SNExpect(SNWebClientVersion(@"<p>no html tag</p>").count == 0, "nothing without an html tag");
}

SN_TEST(NetWritesBackEveryCookie) {
    SNSession *session = Session();
    __block NSInteger saves = 0;
    session.onChange = ^(SNSession *changed) { saves++; };
    SNClient *client = Client(session, ^SNStubAnswer *(SNStubRequest *request) {
        if ([request.method isEqualToString:@"auth.test"])
            return [SNStubAnswer status:200
                                headers:@{@"Set-Cookie" : @"d=xoxd-rotated; Domain=.slack.com; Path=/; Secure; HttpOnly; Expires=Wed, 01 Jan 2031 00:00:00 GMT, "
                                                          @"d-s=; Domain=.slack.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT, lc=1795000000; Domain=.slack.com; Path=/; Secure"}
                                   json:Body(@{})];
        return OK(@{});
    });
    __block BOOL done = NO;
    [client call:@"auth.test" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { done = YES; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return done; }), "call answered");
    NSString *header = [session cookieHeaderForURL:[NSURL URLWithString:@"https://northwind-studio.slack.com/api/x"]];
    SNExpect([header containsString:@"d=xoxd-rotated"] && [header containsString:@"lc=1795000000"], "new cookies sent from then on");
    SNExpect(![header containsString:@"d-s="], "an expired Set-Cookie deletes the cookie");
    SNExpect(saves >= 1, "the session asked to be saved");
    SNSession *restored = [SNSession sessionWithData:session.data];
    SNExpect([[restored cookieHeaderForURL:[NSURL URLWithString:@"https://app.slack.com/"]] isEqualToString:header], "the saved session keeps the rotated jar");
    NSHTTPCookie *d = nil;
    for (NSHTTPCookie *cookie in restored.cookies)
        if ([cookie.name isEqualToString:@"d"]) d = cookie;
    SNExpect(d.isHTTPOnly && d.isSecure && d.expiresDate, "HttpOnly, Secure and expiry survive the round trip");
    SNExpect([restored.account isEqualToString:@"T0NORTHWND:U01ALEX"], "keychain account");
}

SN_TEST(NetRetriesWithoutAnAnswer) {
    __block NSInteger attempts = 0;
    SNClient *client = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        attempts++;
        if (attempts == 1) return nil;
        if (attempts == 2) return [SNStubAnswer status:503 headers:nil json:nil];
        return OK(@{@"value" : @3});
    });
    __block NSDictionary *result;
    [client call:@"client.counts" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { result = response; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return result != nil; }) && [result[@"value"] isEqual:@3], "answered after a lost connection and a 503");
    SNExpect([SNStubRequests().lastObject.query[@"_x_num_retries"] isEqualToString:@"2"], "_x_num_retries counts the retries");

    attempts = 0;
    SNClient *down = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) { return nil; });
    __block NSError *failure;
    [down call:@"client.counts" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { failure = error; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return failure != nil; }) && failure.code == SNAPIErrorNetwork, "network error after the last retry");
}

SN_TEST(NetRefreshesTheTokenOnInvalidAuth) {
    SNSession *session = Session();
    SNClient *client = Client(session, ^SNStubAnswer *(SNStubRequest *request) {
        BOOL fresh = [request.form[@"token"] isEqualToString:@"xoxc-fresh"];
        return [SNStubAnswer status:200 headers:nil json:fresh ? Body(@{}) : @{@"ok" : @NO, @"error" : @"invalid_auth"}];
    });
    __block NSInteger refreshes = 0;
    client.refreshToken = ^(NSString *teamID, void (^completion)(BOOL)) {
        refreshes++;
        // Answered later, so the other calls refused meanwhile wait for this refresh.
        dispatch_async(dispatch_get_main_queue(), ^{
            [session setToken:@"xoxc-fresh" forTeam:teamID];
            completion(YES);
        });
    };
    __block NSInteger ok = 0;
    for (NSString *method in @[ @"auth.test", @"client.counts", @"users.prefs.get" ])
        [client call:method params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { ok += response != nil; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return ok == 3; }) && refreshes == 1, "three calls refused together: one refresh, each sent again with the fresh token");

    SNClient *gone = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        return [SNStubAnswer status:200 headers:nil json:@{@"ok" : @NO, @"error" : @"invalid_auth"}];
    });
    gone.refreshToken = ^(NSString *teamID, void (^completion)(BOOL)) { completion(NO); };
    __block NSInteger signedOut = 0;
    __block NSError *failure;
    gone.onSignedOut = ^{ signedOut++; };
    [gone call:@"auth.test" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { failure = error; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return failure != nil; }) && failure.code == SNAPIErrorSignedOut && signedOut == 1 && gone.isSignedOut,
             "signed out when no token comes back");
    NSUInteger sent = SNStubRequests().count;
    __block NSError *after;
    [gone call:@"client.counts" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { after = error; }];
    __block NSData *image = [NSData data];
    [gone fetchData:[NSURL URLWithString:@"https://files.slack.com/x.png"] completion:^(NSData *data) { image = data; }];
    SNExpect(SNWaitUntil(1, ^BOOL { return after != nil; }) && after.code == SNAPIErrorSignedOut && !image, "then every call and fetch fails at once");
    SNExpect(SNStubRequests().count == sent && signedOut == 1, "without reaching Slack, and the app is told once");

    // A refresher that says yes but leaves the refused token: one more try, then the end.
    __block NSInteger tries = 0;
    SNClient *stuck = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        tries++;
        return [SNStubAnswer status:200 headers:nil json:@{@"ok" : @NO, @"error" : @"invalid_auth"}];
    });
    stuck.refreshToken = ^(NSString *teamID, void (^completion)(BOOL)) { completion(YES); };
    __block NSError *stuckError;
    [stuck call:@"auth.test" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { stuckError = error; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return stuckError != nil; }) && stuckError.code == SNAPIErrorSignedOut && tries == 2 && stuck.isSignedOut,
             "a token refused again ends the session instead of looping");
}

SN_TEST(NetNeverRetriesOrMergesWrites) {
    __block NSInteger posts = 0, reads = 0;
    NSMutableArray<NSString *> *reactions = [NSMutableArray new];
    SNClient *client = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        if ([request.method isEqualToString:@"chat.postMessage"]) {
            @synchronized(reactions) {
                posts++;
            }
            return nil;
        }
        if ([request.method hasPrefix:@"reactions."]) {
            @synchronized(reactions) {
                [reactions addObject:request.method];
            }
            return OK(@{});
        }
        @synchronized(reactions) {
            reads++;
        }
        return nil;
    });
    __block NSError *postError, *readError;
    [client call:@"chat.postMessage" params:@{@"channel" : @"C01", @"text" : @"once"} priority:SNCallUserFacing
      completion:^(NSDictionary *response, NSError *error) { postError = error; }];
    [client call:@"conversations.history" params:@{@"channel" : @"C01"} priority:SNCallUserFacing
      completion:^(NSDictionary *response, NSError *error) { readError = error; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return postError && readError; }), "both fail without an answer");
    SNExpect(posts == 1 && postError.code == SNAPIErrorNetwork, "a send without an answer is not sent again (it may have arrived): it fails for Retry");
    SNExpect(reads == 3, "a read is tried again");
    __block NSInteger answered = 0;
    NSDictionary *params = @{@"channel" : @"C01", @"timestamp" : @"1795400000.000100", @"name" : @"eyes"};
    for (NSString *method in @[ @"reactions.add", @"reactions.remove", @"reactions.add" ])
        [client call:method params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { answered++; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return answered == 3; }) && reactions.count == 3, "add, remove, add again: three calls, none merged");
}

SN_TEST(NetHonoursRetryAfterAndUnknownMethod) {
    __block NSInteger historyCalls = 0;
    __block NSDate *first, *second;
    SNClient *client = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        if ([request.method isEqualToString:@"saved.list"]) return [SNStubAnswer status:200 headers:nil json:@{@"ok" : @NO, @"error" : @"unknown_method"}];
        historyCalls++;
        if (historyCalls == 1) {
            first = NSDate.date;
            return [SNStubAnswer status:429 headers:@{@"Retry-After" : @"0.3"} json:nil];
        }
        second = NSDate.date;
        return OK(@{});
    });
    __block BOOL answered = NO;
    [client call:@"conversations.history" params:@{@"channel" : @"C01"} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        answered = response != nil;
    }];
    SNExpect(SNWaitUntil(3, ^BOOL { return answered; }), "answered after the 429");
    SNExpect([second timeIntervalSinceDate:first] >= 0.28, "waited for Retry-After");

    __block NSError *disabled;
    [client call:@"saved.list" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { disabled = error; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return disabled != nil; }) && disabled.code == SNAPIErrorDisabled, "unknown_method disables");
    NSUInteger before = SNStubRequests().count;
    __block NSError *again;
    [client call:@"saved.list" params:@{@"x" : @"1"} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { again = error; }];
    SNExpect(SNWaitUntil(1, ^BOOL { return again != nil; }) && SNStubRequests().count == before, "a disabled method is not called again");
}

/// Work that records when it started and finishes after `delay`.
static SNCallWork Work(NSMutableArray *starts, NSString *name, NSTimeInterval delay) {
    return ^(SNCallFinish finish) {
        [starts addObject:@[ name, NSDate.date ]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(SNCallDone, 0, @{@"name" : name}, nil); });
    };
}

SN_TEST(NetSchedulerPutsTheUserFirst) {
    SNScheduler *scheduler = [SNScheduler new];
    scheduler.backgroundInterval = 0.15;
    NSMutableArray *starts = [NSMutableArray new];
    __block NSInteger done = 0;
    SNAPICompletion count = ^(NSDictionary *response, NSError *error) { done++; };
    for (NSString *name in @[ @"b1", @"b2", @"b3" ])
        [scheduler enqueue:@"users.getPresence" mergeKey:name rateKey:@"users.getPresence" priority:SNCallBackground work:Work(starts, name, 0) completion:count];
    [scheduler enqueue:@"conversations.history" mergeKey:@"u1" rateKey:@"conversations.history" priority:SNCallUserFacing work:Work(starts, @"u1", 0) completion:count];
    SNExpect(SNWaitUntil(2, ^BOOL { return done == 4; }), "all ran");
    NSMutableArray *order = [NSMutableArray new];
    for (NSArray *start in starts) [order addObject:start[0]];
    SNExpect([order[0] isEqualToString:@"b1"] && [order[1] isEqualToString:@"u1"], "the user's call does not wait behind the background queue");
    NSTimeInterval gap = [starts[3][1] timeIntervalSinceDate:starts[2][1]];
    SNExpect(gap >= 0.13, "background calls are spaced");
}

SN_TEST(NetSchedulerMergesAndLimits) {
    SNScheduler *scheduler = [SNScheduler new];
    NSMutableArray *starts = [NSMutableArray new];
    __block NSInteger done = 0;
    SNAPICompletion count = ^(NSDictionary *response, NSError *error) {
        if ([response[@"name"] isEqualToString:@"same"]) done++;
    };
    [scheduler enqueue:@"users.info" mergeKey:@"same" rateKey:@"users.info" priority:SNCallBackground work:Work(starts, @"same", 0.05) completion:count];
    [scheduler enqueue:@"users.info" mergeKey:@"same" rateKey:@"users.info" priority:SNCallUserFacing work:Work(starts, @"other", 0.05) completion:count];
    SNExpect(SNWaitUntil(2, ^BOOL { return done == 2; }) && starts.count == 1, "identical calls run once and both get the answer");

    scheduler.rateWindow = 0.6;
    [starts removeAllObjects];
    __block NSInteger searched = 0;
    for (NSString *name in @[ @"s1", @"s2" ])
        [scheduler enqueue:@"search.messages" mergeKey:name rateKey:@"search.messages" priority:SNCallUserFacing work:Work(starts, name, 0)
                completion:^(NSDictionary *response, NSError *error) { searched++; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return searched == 2; }), "both searches ran");
    SNExpect([starts[1][1] timeIntervalSinceDate:starts[0][1]] >= 0.55, "a tier 2 method waits for its window");
    SNExpect(SNRateLimitForKey(@"search.messages") == 20 && SNRateLimitForKey(@"users.info") == 100 && SNRateLimitForKey(@"conversations.history") == 50 &&
                 SNRateLimitForKey(@"chat.postMessage C01") == 60,
             "tiers");
}

/// A trace file of the test's own, removed first.
static NSURL *TraceTo(NSString *name) {
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    SNSetTraceFile(file);
    return file;
}

static NSArray<NSString *> *TraceLines(NSURL *file) {
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
    return [[text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\n"];
}

SN_TEST(NetTracesEveryCallWithoutSecrets) {
    NSURL *previous = SNTraceFile(), *file = TraceTo(@"sn-net-trace.log");
    __block NSInteger calls = 0;
    SNClient *client = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        if (++calls == 1) return [SNStubAnswer status:200 headers:nil json:@{@"ok" : @NO, @"error" : @"channel_not_found"}];
        return OK(@{@"messages" : @[ @{@"text" : @"secret words"} ]});
    });
    __block NSInteger answered = 0;
    for (NSString *channel in @[ @"C0SECRET1", @"C0SECRET2" ])
        [client call:@"conversations.history" params:@{@"channel" : channel} priority:SNCallUserFacing
          completion:^(NSDictionary *response, NSError *error) { answered++; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return answered == 2; }), "both calls answered");
    NSArray<NSString *> *lines = TraceLines(file);
    SNExpect(lines.count == 2, "one line per call");
    // The two calls run side by side, so either may be traced first.
    NSArray<NSString *> *failed = @[], *ok = @[];
    for (NSString *line in lines) {
        if ([line containsString:@"channel_not_found"]) failed = [line componentsSeparatedByString:@"\t"];
        else ok = [line componentsSeparatedByString:@"\t"];
    }
    SNExpect(failed.count == 6 && [failed[1] isEqualToString:@"conversations.history"] && [failed[2] isEqualToString:@"200"] &&
                 [failed[3] isEqualToString:@"channel_not_found"],
             "time, method, status and Slack's error");
    SNExpect(ok.count == 6 && [ok[3] isEqualToString:@"ok"] && ok[4].integerValue >= 0 && ok[5].integerValue > 20, "ok, milliseconds and response bytes");
    NSString *text = [lines componentsJoinedByString:@"\n"];
    SNExpect(![text containsString:@"xoxc"] && ![text containsString:@"xoxd"] && ![text containsString:@"C0SECRET"] && ![text containsString:@"secret words"],
             "no token, cookie, parameter or content");
    SNSetTraceFile(previous);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
}

SN_TEST(NetFetchesAvatarsPlainAndTracesThemByHost) {
    NSURL *previous = SNTraceFile(), *file = TraceTo(@"sn-net-image-trace.log");
    __block NSURLRequest *seen;
    SNClient *client = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        seen = request.request;
        if ([request.request.URL.path hasSuffix:@"-72"]) return [SNStubAnswer status:200 headers:@{@"Content-Type" : @"image/png"} json:@[ @1 ]];
        return [SNStubAnswer status:404 headers:nil json:nil];
    });
    __block NSData *picture, *missing = [NSData data];
    [client fetchData:[NSURL URLWithString:@"https://ca.slack-edge.com/T0FAKE-U0FAKE01-0a1b2c3d4e5f-72"] completion:^(NSData *data) { picture = data; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return picture != nil; }), "the avatar's bytes");
    SNExpect(![seen valueForHTTPHeaderField:@"Cookie"] && ![seen valueForHTTPHeaderField:@"Origin"] && [seen valueForHTTPHeaderField:@"User-Agent"].length,
             "Slack's avatar host gets the user agent, no cookie and no Origin");
    [client fetchData:[NSURL URLWithString:@"https://ca.slack-edge.com/T0FAKE-U0FAKE02-g0a1b2c3d4e5-48"] completion:^(NSData *data) { missing = data; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return missing == nil; }), "a 404 answers nil");
    NSArray<NSString *> *lines = TraceLines(file);
    NSArray<NSString *> *got = [lines.firstObject componentsSeparatedByString:@"\t"], *failed = [lines.lastObject componentsSeparatedByString:@"\t"];
    SNExpect(lines.count == 2 && got.count == 6 && [got[1] isEqualToString:@"image:ca.slack-edge.com"] && [got[3] isEqualToString:@"ok"] && [got[5] integerValue] > 0,
             "a line per picture: host, time and bytes");
    SNExpect(failed.count == 6 && [failed[2] isEqualToString:@"404"], "and the failure's status");
    SNExpect(![[lines componentsJoinedByString:@"\n"] containsString:@"FAKE"], "never the path, which names the person");
    SNSetTraceFile(previous);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
}

SN_TEST(NetFetchesFilesWithTheSessionCookie) {
    __block NSURLRequest *seen;
    SNClient *client = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        seen = request.request;
        return [SNStubAnswer status:200 headers:@{@"Content-Type" : @"image/png"} json:@[ @1 ]];
    });
    __block NSData *thumbnail;
    // A files response's thumb_480 (url_private and the other thumb_<size> are on the same host).
    [client fetchData:[NSURL URLWithString:@"https://files.slack.com/files-tmb/T0NORTHWND-F0FAKE01-0a1b2c3d4e/screenshot_480.png"]
           completion:^(NSData *data) { thumbnail = data; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return thumbnail != nil; }), "the thumbnail's bytes");
    NSString *cookie = [seen valueForHTTPHeaderField:@"Cookie"];
    SNExpect([cookie containsString:@"d=xoxd-made%2Bup%3D"] && [cookie containsString:@"d-s=1700000000"], "files.slack.com gets the session's cookies as stored");
    SNExpect(![seen valueForHTTPHeaderField:@"Origin"] && [[seen valueForHTTPHeaderField:@"User-Agent"] isEqualToString:@"Mozilla/5.0 (Macintosh) Test"],
             "with the session's user agent and no Origin, as an <img> load");
}

SN_TEST(NetReadOnlyRefusesWrites) {
    NSURL *previous = SNTraceFile(), *file = TraceTo(@"sn-net-readonly.log");
    BOOL wasReadOnly = SNReadOnly();
    SNSetReadOnly(YES);
    NSMutableArray<NSString *> *sent = [NSMutableArray new];
    SNClient *client = Client(Session(), ^SNStubAnswer *(SNStubRequest *request) {
        @synchronized(sent) {
            [sent addObject:request.method];
        }
        return OK(@{});
    });
    NSArray<NSString *> *writes = @[ @"chat.postMessage", @"chat.update", @"chat.delete", @"reactions.add", @"conversations.mark", @"conversations.open",
                                     @"subscriptions.thread.mark", @"drafts.update", @"users.prefs.set", @"users.setPresence", @"users.profile.set",
                                     @"users.channelSections.update", @"files.getUploadURLExternal", @"files.completeUploadExternal", @"saved.add" ];
    NSArray<NSString *> *reads = @[ @"conversations.history", @"conversations.replies", @"client.userBoot", @"client.counts", @"users.prefs.get",
                                    @"emoji.list", @"search.messages", @"client.getWebSocketURL", @"dnd.teamInfo", @"files.info" ];
    __block NSInteger refused = 0, answered = 0;
    for (NSString *method in writes)
        [client call:method params:@{@"channel" : @"C01"} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
            if (!response && error.code == SNAPIErrorReadOnly) refused++;
        }];
    SNExpect(refused == 0, "refusals are answered later, like calls");
    for (NSString *method in reads)
        [client call:method params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { answered += response != nil; }];
    SNExpect(SNWaitUntil(3, ^BOOL { return refused == (NSInteger)writes.count && answered == (NSInteger)reads.count; }), "writes refused, reads answered");
    SNExpect([[NSSet setWithArray:sent] isEqualToSet:[NSSet setWithArray:reads]], "only reads reached the network");
    NSInteger refusedLines = 0;
    for (NSString *line in TraceLines(file)) refusedLines += [line hasSuffix:@"\tread_only\t-\t0"];
    SNExpect(refusedLines == (NSInteger)writes.count, "a trace line per refusal");
    SNSetReadOnly(wasReadOnly);
    SNSetTraceFile(previous);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
}

SN_TEST(NetTakesOnlySlacksCookies) {
    SNSession *session = Session();
    __block NSInteger changes = 0;
    session.onChange = ^(SNSession *changed) { changes++; };
    NSHTTPURLResponse *(^response)(NSString *, NSString *) = ^NSHTTPURLResponse *(NSString *url, NSString *cookie) {
        return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:url] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Set-Cookie" : cookie}];
    };
    SNExpect(![session takeCookiesFromResponse:response(@"https://ca.slack-edge.com/avatar.png", @"cdn=1; Domain=.slack-edge.com; Path=/")] &&
                 ![session takeCookiesFromResponse:response(@"https://tracker.example.com/", @"d=evil; Path=/")],
             "a CDN's or another site's cookies are not taken");
    SNExpect(session.cookies.count == 2, "the jar keeps only its own");
    SNExpect([session takeCookiesFromResponse:response(@"https://northwind-studio.slack.com/api/x", @"lc=1795000000; Domain=.slack.com; Path=/; Max-Age=3600")],
             "a new cookie is a change");
    SNExpect(![session takeCookiesFromResponse:response(@"https://northwind-studio.slack.com/api/x", @"lc=1795000000; Domain=.slack.com; Path=/; Max-Age=3600")],
             "the same value again with a later Max-Age is not");
    SNExpect(![session takeCookiesFromResponse:response(@"https://app.slack.com/", @"d-s=1700000000; Domain=.slack.com; Path=/; Secure")],
             "nor a session cookie (no expiry) sent again unchanged");
    SNExpect([session takeCookiesFromResponse:response(@"https://app.slack.com/", @"d-s=1700000999; Domain=.slack.com; Path=/; Secure")], "a new value is");
    SNExpect([session takeCookiesFromResponse:response(@"https://app.slack.com/", @"lc=; Domain=.slack.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT")] &&
                 ![session takeCookiesFromResponse:response(@"https://app.slack.com/", @"lc=; Domain=.slack.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT")],
             "deleting is a change once");
    SNExpect(SNWaitUntil(1, ^BOOL { return changes == 3; }), "onChange for the three changes only");
}

SN_TEST(NetSessionIsSafeAcrossThreads) {
    SNSession *session = Session();
    dispatch_group_t group = dispatch_group_create();
    for (int worker = 0; worker < 4; worker++)
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (int i = 0; i < 300; i++) {
                NSString *cookie = [NSString stringWithFormat:@"c%d=%d; Domain=.slack.com; Path=/", i % 7, i];
                [session takeCookiesFromResponse:[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://app.slack.com/"] statusCode:200
                                                                             HTTPVersion:@"HTTP/1.1" headerFields:@{@"Set-Cookie" : cookie}]];
            }
        });
    NSUInteger reads = 0;
    while (dispatch_group_wait(group, DISPATCH_TIME_NOW)) {
        reads += session.data.length > 0;
        reads += session.cookies.count > 0;
        reads += [session cookieHeaderForURL:[NSURL URLWithString:@"https://app.slack.com/"]] != nil;
    }
    SNExpect(reads > 0 && [SNSession sessionWithData:session.data].cookies.count == 9, "the jar reads whole while other threads rotate cookies");
}

SN_TEST(NetRedirectsCarryCookiesOnlyOnSlack) {
    SNSession *session = Session();
    NSURLSession *urlSession = SNMakeURLSession(session);
    id<NSURLSessionTaskDelegate> delegate = (id<NSURLSessionTaskDelegate>)urlSession.delegate;
    NSHTTPURLResponse *redirect = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://northwind-studio.slack.com/files/x"] statusCode:302
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Set-Cookie" : @"d=xoxd-from-a-redirect; Domain=.slack.com; Path=/; Secure",
                                                                           @"Location" : @"https://files.example.com/x"}];
    NSMutableURLRequest *away = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://files.example.com/x"]];
    [away setValue:@"d=xoxd-made%2Bup%3D" forHTTPHeaderField:@"Cookie"];
    // Never resumed: the delegate is called by hand, nothing is fetched.
    NSURLSessionTask *task = [urlSession dataTaskWithURL:redirect.URL];
    __block NSURLRequest *followed;
    [delegate URLSession:urlSession task:task willPerformHTTPRedirection:redirect newRequest:away completionHandler:^(NSURLRequest *request) { followed = request; }];
    SNExpect(followed && ![followed valueForHTTPHeaderField:@"Cookie"], "the Cookie header never follows a redirect off Slack's hosts");
    SNExpect([[session cookieHeaderForURL:[NSURL URLWithString:@"https://app.slack.com/"]] containsString:@"d=xoxd-from-a-redirect"], "Set-Cookie on the 3xx is taken");
    NSMutableURLRequest *home = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://app.slack.com/client"]];
    [home setValue:@"stale=1" forHTTPHeaderField:@"Cookie"];
    [delegate URLSession:urlSession task:task willPerformHTTPRedirection:redirect newRequest:home completionHandler:^(NSURLRequest *request) { followed = request; }];
    SNExpect([[followed valueForHTTPHeaderField:@"Cookie"] isEqualToString:[session cookieHeaderForURL:home.URL]], "on Slack, the jar's cookies for the new host");
    [urlSession invalidateAndCancel];
}

SN_TEST(NetRotatesTheTrace) {
    NSURL *previous = SNTraceFile(), *file = TraceTo(@"sn-net-rotate.log");
    NSURL *rotated = [NSURL fileURLWithPath:[file.path stringByAppendingString:@".1"]];
    [NSFileManager.defaultManager removeItemAtURL:rotated error:nil];
    for (int i = 0; i < 20000; i++) SNTrace(@"conversations.history", 200, @"ok", 12, 3456);
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] fileSize];
    unsigned long long old = [[NSFileManager.defaultManager attributesOfItemAtPath:rotated.path error:nil] fileSize];
    SNExpect(old >= 1024 * 1024 && old < 1024 * 1024 + 200 && size < 1024 * 1024, "past 1 MB the trace moves to .1 and starts over");
    SNSetTraceFile(previous);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    [NSFileManager.defaultManager removeItemAtURL:rotated error:nil];
}

SN_TEST(NetSchedulerRunsDuringMenusAndResizes) {
    SNScheduler *scheduler = [SNScheduler new];
    scheduler.backgroundInterval = 0.05;
    NSMutableArray *starts = [NSMutableArray new];
    __block NSInteger done = 0;
    for (NSString *name in @[ @"b1", @"b2" ])
        [scheduler enqueue:@"users.getPresence" mergeKey:name rateKey:@"users.getPresence" priority:SNCallBackground work:Work(starts, name, 0)
                completion:^(NSDictionary *response, NSError *error) { done++; }];
    // The run loop in the mode AppKit uses while a menu tracks or a window resizes.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (done < 2 && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSEventTrackingRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    SNExpect(done == 2, "a spaced call starts while the run loop tracks events");
}
