// Owns building Web API requests, reading their answers, retries and token refresh.
#import "model/json.h"
#import "net/client.h"
#import "net/switches.h"

static NSString *Encode(NSString *value) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"]; });
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *Form(NSDictionary<NSString *, NSString *> *pairs) {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *key in [pairs.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@=%@", Encode(key), Encode(pairs[key])]];
    return [parts componentsJoinedByString:@"&"];
}

NSDictionary<NSString *, NSString *> *SNWebClientVersion(NSString *html) {
    NSRange open = [html rangeOfString:@"<html" options:NSCaseInsensitiveSearch];
    if (open.location == NSNotFound) return @{};
    NSRange close = [html rangeOfString:@">" options:0 range:NSMakeRange(open.location, html.length - open.location)];
    if (close.location == NSNotFound) return @{};
    NSString *tag = [html substringWithRange:NSMakeRange(open.location, close.location - open.location)];
    NSRegularExpression *attribute = [NSRegularExpression regularExpressionWithPattern:@"data-([a-z0-9-]+)\\s*=\\s*\"([^\"]*)\"" options:0 error:nil];
    NSMutableDictionary *version = [NSMutableDictionary new];
    for (NSTextCheckingResult *match in [attribute matchesInString:tag options:0 range:NSMakeRange(0, tag.length)]) {
        NSString *key = [[tag substringWithRange:[match rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        version[key] = [tag substringWithRange:[match rangeAtIndex:2]];
    }
    return version;
}

NSDictionary<NSString *, NSString *> *SNWebClientParams(NSDictionary<NSString *, NSString *> *version, NSString *route, NSInteger attempt) {
    NSString *hash = version[@"version_hash"] ?: @"";
    NSString *prefix = hash.length > 8 ? [hash substringToIndex:8] : hash;
    NSString *now = [NSString stringWithFormat:@"%.3f", NSDate.date.timeIntervalSince1970];
    NSMutableDictionary *params = [@{@"_x_id" : [NSString stringWithFormat:@"%@-%@", prefix.length ? prefix : @"noversion", now],
                                     @"_x_frontend_build_type" : version[@"frontend_build_type"] ?: @"current", @"_x_desktop_ia" : @"4",
                                     @"_x_gantry" : @"true", @"fp" : @"aa", @"_x_num_retries" : @(attempt).stringValue,
                                     @"slack_route" : route, @"_x_mode" : @"online", @"_x_sonic" : @"true", @"_x_app_name" : @"client"} mutableCopy];
    if (version[@"version_ts"]) params[@"_x_version_ts"] = version[@"version_ts"];
    return params;
}

static NSString *SNRandomLetters(NSUInteger count) {
    static const char letters[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    NSMutableString *random = [NSMutableString new];
    for (NSUInteger i = 0; i < count; i++) [random appendFormat:@"%c", letters[arc4random_uniform(sizeof letters - 1)]];
    return random;
}

BOOL SNWriteMultipartBody(NSURL *file, NSString *name, NSString *mimeType, NSString *boundary, NSURL *body) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:file error:nil];
    if (!input || ![NSFileManager.defaultManager createFileAtPath:body.path contents:nil attributes:nil]) return NO;
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:body error:nil];
    if (!output) return NO;
    // Browsers escape the quote and line breaks of a part's file name this way.
    NSString *escaped = [[[name stringByReplacingOccurrencesOfString:@"\"" withString:@"%22"] stringByReplacingOccurrencesOfString:@"\r" withString:@"%0D"]
        stringByReplacingOccurrencesOfString:@"\n" withString:@"%0A"];
    NSString *head = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n", boundary, escaped, mimeType];
    BOOL ok = [output writeData:[head dataUsingEncoding:NSUTF8StringEncoding] error:nil];
    while (ok) {
        @autoreleasepool {
            NSData *chunk = [input readDataUpToLength:4 << 20 error:nil];
            if (!chunk) ok = NO;
            else if (!chunk.length) break;
            else ok = [output writeData:chunk error:nil];
        }
    }
    NSString *tail = [NSString stringWithFormat:@"\r\n--%@--\r\n", boundary];
    ok = ok && [output writeData:[tail dataUsingEncoding:NSUTF8StringEncoding] error:nil];
    [input closeAndReturnError:nil];
    ok = [output closeAndReturnError:nil] && ok;
    if (!ok) [NSFileManager.defaultManager removeItemAtURL:body error:nil];
    return ok;
}

/// Hands an upload's progress to the main thread.
@interface SNUploadTaskDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, copy, nullable) void (^progress)(double fraction);
@end

@implementation SNUploadTaskDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)sent totalBytesSent:(int64_t)total
    totalBytesExpectedToSend:(int64_t)expected {
    void (^progress)(double) = self.progress;
    if (!progress || expected <= 0) return;
    double fraction = (double)total / (double)expected;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(fraction); });
}
@end

/// Errors that mean the token is no longer good.
static BOOL IsAuthError(NSString *error) {
    return [error isEqualToString:@"invalid_auth"] || [error isEqualToString:@"not_authed"] || [error isEqualToString:@"token_expired"];
}

/// "ok", Slack's error string, the transport error's code, or "no_json".
static NSString *TraceOutcome(id json, NSError *error) {
    if (error) return [NSString stringWithFormat:@"%@:%ld", error.domain, (long)error.code];
    if (![json isKindOfClass:NSDictionary.class]) return @"no_json";
    return SNJSONBool(json, @"ok") ? @"ok" : SNJSONString(json, @"error") ?: @"unknown_error";
}

/// One call's way through its attempts.
@interface SNClientCall : NSObject
@property (nonatomic) NSString *method;
@property (nonatomic, copy) NSURLRequest * (^build)(NSInteger attempt);
/// Reads are sent again when no answer came; a write may have happened anyway, so it is not.
@property (nonatomic) BOOL retries;
@property (nonatomic) NSInteger attempt;
/// Already sent again with a refreshed token.
@property (nonatomic) BOOL refreshed;
@property (nonatomic, copy) SNCallFinish finish;
@end

@implementation SNClientCall
@end

@implementation SNClient {
    /// Calls refused with the token being refreshed, waiting for the refresh.
    NSMutableArray<void (^)(BOOL renewed)> *_renewals;
    BOOL _signedOut, _invalidated;
}

- (instancetype)initWithSession:(SNSession *)session teamID:(NSString *)teamID urlSession:(NSURLSession *)urlSession {
    if (!(self = [super init])) return nil;
    _session = session;
    _teamID = [teamID copy];
    _urlSession = urlSession;
    _scheduler = [SNScheduler new];
    _retryDelays = @[ @1, @2, @4 ];
    _renewals = [NSMutableArray new];
    return self;
}

- (SNSessionTeam *)team { return [self.session teamWithID:self.teamID]; }

/// slack_route: the team, or "<enterprise>:<team>" on Grid.
- (NSString *)route {
    SNSessionTeam *team = [self team];
    return team.enterpriseID ? [NSString stringWithFormat:@"%@:%@", team.enterpriseID, self.teamID] : self.teamID;
}

- (NSURLRequest *)requestForMethod:(NSString *)method params:(NSDictionary<NSString *, NSString *> *)params attempt:(NSInteger)attempt {
    SNSessionTeam *team = [self team];
    NSMutableDictionary *query = [SNWebClientParams(self.session.version, [self route], attempt) mutableCopy];
    NSMutableDictionary *body = [NSMutableDictionary new];
    [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if ([key hasPrefix:@"_x_"]) query[key] = value;
        else body[key] = value;
    }];
    body[@"token"] = team.token ?: @"";
    NSURL *base = [NSURL URLWithString:[@"api/" stringByAppendingString:method] relativeToURL:team.url ?: [NSURL URLWithString:@"https://slack.com/"]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", base.absoluteString, Form(query)]];
    NSMutableURLRequest *request = [self.session requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [Form(body) dataUsingEncoding:NSUTF8StringEncoding];
    return request;
}

- (NSURLRequest *)edgeRequest:(NSString *)path body:(NSDictionary *)body {
    SNSessionTeam *team = [self team];
    NSString *owner = team.enterpriseID ?: self.teamID;
    NSString *query = Form(@{@"fp" : @"aa"});
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://edgeapi.slack.com/cache/%@/%@?%@", owner, path, query]];
    NSMutableURLRequest *request = [self.session requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"text/plain;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    NSMutableDictionary *json = [body mutableCopy];
    json[@"token"] = team.token ?: @"";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    return request;
}

#pragma mark Calls

/// Why nothing may go out any more: the session ended, or the client was invalidated.
- (NSError *)refusal {
    if (_signedOut) return SNAPIMakeError(SNAPIErrorSignedOut, @"signed_out");
    if (_invalidated) return SNAPIMakeError(SNAPIErrorNetwork, @"invalidated");
    return nil;
}

- (void)call:(NSString *)method params:(NSDictionary<NSString *, NSString *> *)params priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    BOOL mutating = SNIsMutatingMethod(method);
    NSError *refusal = [self refusal];
    if (!refusal && SNReadOnly() && mutating) {
        SNTrace(method, 0, @"read_only", -1, 0);
        refusal = SNAPIMakeError(SNAPIErrorReadOnly, @"read_only");
    }
    if (refusal) {
        // Answered later, as every call is: callers revert what they applied before calling.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, refusal);
        });
        return;
    }
    NSMutableDictionary *mergeable = [params mutableCopy];
    [mergeable removeObjectForKey:@"_x_reason"];
    // Identical reads are the same question; every write is an act of its own (add, remove, add
    // again within one round trip are three).
    NSString *mergeKey = mutating ? nil : [method stringByAppendingFormat:@" %@", Form(mergeable)];
    NSString *rateKey = [method isEqualToString:@"chat.postMessage"] ? [method stringByAppendingFormat:@" %@", params[@"channel"] ?: @""] : method;
    __weak SNClient *weakSelf = self;
    [self.scheduler enqueue:method mergeKey:mergeKey rateKey:rateKey priority:priority work:^(SNCallFinish finish) {
        SNClientCall *call = [SNClientCall new];
        call.method = method;
        call.build = ^NSURLRequest *(NSInteger attempt) { return [weakSelf requestForMethod:method params:params attempt:attempt]; };
        call.retries = !mutating;
        call.finish = finish;
        [weakSelf perform:call];
    } completion:completion];
}

- (void)callEdge:(NSString *)path body:(NSDictionary *)body priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    NSError *refusal = [self refusal];
    if (refusal) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, refusal);
        });
        return;
    }
    NSString *method = [@"edge:" stringByAppendingString:path];
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:nil];
    NSString *mergeKey = [method stringByAppendingFormat:@" %@", [[NSString alloc] initWithData:bodyData ?: [NSData data] encoding:NSUTF8StringEncoding]];
    __weak SNClient *weakSelf = self;
    [self.scheduler enqueue:method mergeKey:mergeKey rateKey:method priority:priority work:^(SNCallFinish finish) {
        SNClientCall *call = [SNClientCall new];
        call.method = method;
        call.build = ^NSURLRequest *(NSInteger attempt) { return [weakSelf edgeRequest:path body:body]; };
        // The edge API is Slack's read cache.
        call.retries = YES;
        call.finish = finish;
        [weakSelf perform:call];
    } completion:completion];
}

/// Sends the call's request for its attempt. The answer's JSON is parsed on URLSession's queue
/// (userBoot and emoji.list run to megabytes) and handled on the main thread.
- (void)perform:(SNClientCall *)call {
    NSError *refusal = [self refusal];
    if (refusal) return call.finish(SNCallDone, 0, nil, refusal);
    NSString *token = [self team].token;
    NSURLRequest *request = call.build(call.attempt);
    NSDate *start = NSDate.date;
    SNSession *session = self.session;
    __weak SNClient *weakSelf = self;
    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http) [session takeCookiesFromResponse:http];
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        SNTrace(call.method, http.statusCode, TraceOutcome(json, error), -start.timeIntervalSinceNow * 1000, data.length);
        SNTraceLaunch(@"first answer");
        dispatch_async(dispatch_get_main_queue(), ^{
            SNClient *client = weakSelf;
            if (!client) return call.finish(SNCallDone, 0, nil, SNAPIMakeError(SNAPIErrorNetwork, nil));
            [client handle:json response:http call:call token:token];
        });
    }];
    [task resume];
}

/// Holds on 429, retries reads without an answer, and on invalid_auth refreshes the token once
/// (`token` is the one the request carried).
- (void)handle:(id)json response:(NSHTTPURLResponse *)http call:(SNClientCall *)call token:(NSString *)token {
    SNCallFinish finish = call.finish;
    if (http.statusCode == 429) {
        NSTimeInterval retryAfter = [[http valueForHTTPHeaderField:@"Retry-After"] doubleValue];
        return finish(SNCallRateLimited, retryAfter > 0 ? retryAfter : 30, nil, nil);
    }
    BOOL answered = http && http.statusCode < 500 && [json isKindOfClass:NSDictionary.class];
    if (!answered) {
        if (call.retries && call.attempt < (NSInteger)self.retryDelays.count) {
            NSTimeInterval delay = self.retryDelays[(NSUInteger)call.attempt].doubleValue;
            call.attempt++;
            __weak SNClient *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SNClient *client = weakSelf;
                if (client) [client perform:call];
                else finish(SNCallDone, 0, nil, SNAPIMakeError(SNAPIErrorNetwork, nil));
            });
            return;
        }
        return finish(SNCallDone, 0, nil, SNAPIMakeError(SNAPIErrorNetwork, nil));
    }
    if (SNJSONBool(json, @"ok")) return finish(SNCallDone, 0, json, nil);
    NSString *name = SNJSONString(json, @"error") ?: @"unknown_error";
    if ([name isEqualToString:@"unknown_method"]) return finish(SNCallUnknownMethod, 0, nil, nil);
    if ([name isEqualToString:@"ratelimited"] || [name isEqualToString:@"rate_limited"]) return finish(SNCallRateLimited, 30, nil, nil);
    if (IsAuthError(name)) {
        // Refused even with a fresh token: the session is over.
        if (call.refreshed) {
            [self endSession];
            return finish(SNCallDone, 0, nil, SNAPIMakeError(SNAPIErrorSignedOut, name));
        }
        __weak SNClient *weakSelf = self;
        [self renewToken:token completion:^(BOOL renewed) {
            SNClient *client = weakSelf;
            if (!renewed || !client) return finish(SNCallDone, 0, nil, SNAPIMakeError(SNAPIErrorSignedOut, name));
            call.refreshed = YES;
            [client perform:call];
        }];
        return;
    }
    finish(SNCallDone, 0, nil, SNAPISlackError(json));
}

/// One refresh for every call refused with `refused`, however many fail at once. NO ends the
/// session: Slack is not called again and the app asks to sign in.
- (void)renewToken:(NSString *)refused completion:(void (^)(BOOL renewed))completion {
    if (_signedOut) return completion(NO);
    // Another call's refresh replaced the token meanwhile.
    if (refused && ![[self team].token isEqualToString:refused]) return completion(YES);
    [_renewals addObject:completion];
    if (_renewals.count > 1) return;
    __weak SNClient *weakSelf = self;
    void (^done)(BOOL) = ^(BOOL refreshed) {
        SNClient *client = weakSelf;
        if (!client) return;
        if (!refreshed) [client endSession];
        NSArray *waiting = [client->_renewals copy];
        [client->_renewals removeAllObjects];
        for (void (^waiter)(BOOL) in waiting) waiter(refreshed);
    };
    if (self.refreshToken && !_invalidated) self.refreshToken(self.teamID, done);
    else done(NO);
}

- (void)endSession {
    if (_signedOut) return;
    _signedOut = YES;
    if (self.onSignedOut) self.onSignedOut();
}

- (BOOL)isSignedOut { return _signedOut; }

- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;
    [self.urlSession invalidateAndCancel];
}

#pragma mark Uploads

- (dispatch_block_t)upload:(NSURL *)file name:(NSString *)name mimeType:(NSString *)mimeType to:(NSURL *)url
                  progress:(void (^)(double))progress completion:(void (^)(NSInteger))completion {
    __block BOOL cancelled = NO;
    __block NSURLSessionTask *task = nil;
    dispatch_block_t cancel = ^{
        cancelled = YES;
        [task cancel];
    };
    NSError *refusal = [self refusal];
    if (!refusal && SNReadOnly()) {
        SNTrace(@"upload", 0, @"read_only", -1, 0);
        refusal = SNAPIMakeError(SNAPIErrorReadOnly, @"read_only");
    }
    if (refusal || ![url.scheme isEqualToString:@"https"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(0); });
        return cancel;
    }
    NSString *boundary = [@"----WebKitFormBoundary" stringByAppendingString:SNRandomLetters(16)];
    NSURL *body = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[@"sn-upload-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    // A browser's XHR to the upload host carries the page's origin and agent but no cookies: the
    // URL itself is the permission.
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPShouldHandleCookies = NO;
    [request setValue:self.session.userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://app.slack.com" forHTTPHeaderField:@"Origin"];
    [request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
    NSURLSession *urlSession = self.urlSession;
    SNUploadTaskDelegate *delegate = [SNUploadTaskDelegate new];
    delegate.progress = progress;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL written = SNWriteMultipartBody(file, name, mimeType, boundary, body);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cancelled || !written) {
                [NSFileManager.defaultManager removeItemAtURL:body error:nil];
                completion(0);
                return;
            }
            NSDate *start = NSDate.date;
            task = [urlSession uploadTaskWithRequest:request fromFile:body completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                [NSFileManager.defaultManager removeItemAtURL:body error:nil];
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                // The host only: the path is the upload's permission.
                SNTrace([@"upload:" stringByAppendingString:url.host ?: @"-"], status, error ? [NSString stringWithFormat:@"%@:%ld", error.domain, (long)error.code] : @"ok",
                        -start.timeIntervalSinceNow * 1000, data.length);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(error ? 0 : status); });
            }];
            task.delegate = delegate;
            [task resume];
        });
    });
    return cancel;
}

#pragma mark Other fetches

- (void)fetchData:(NSURL *)url completion:(void (^)(NSData *))completion {
    if (![url.scheme isEqualToString:@"https"] || [self refusal]) {
        completion(nil);
        return;
    }
    // The jar's cookies only match Slack's hosts (files need them); elsewhere this is a plain GET
    // with the session's user agent.
    NSMutableURLRequest *request = [self.session requestWithURL:url];
    [request setValue:nil forHTTPHeaderField:@"Origin"];
    SNSession *session = self.session;
    NSDate *start = NSDate.date;
    [[self.urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http) [session takeCookiesFromResponse:http];
        NSData *body = http.statusCode == 200 ? data : nil;
        // The host only: the path names the person or the file.
        SNTrace([@"image:" stringByAppendingString:url.host ?: @"-"], http.statusCode,
                body ? @"ok" : error ? [NSString stringWithFormat:@"error %ld", (long)error.code] : @"failed", body ? -start.timeIntervalSinceNow * 1000 : -1, body.length);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(body); });
    }] resume];
}

- (void)refreshWebClientVersion:(void (^)(BOOL))completion {
    if ([self refusal]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    NSMutableURLRequest *request = [self.session requestWithURL:[NSURL URLWithString:@"https://app.slack.com/client"]];
    [request setValue:nil forHTTPHeaderField:@"Origin"];
    SNSession *session = self.session;
    [[self.urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http) [session takeCookiesFromResponse:http];
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSDictionary *version = html ? SNWebClientVersion(html) : @{};
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = version[@"version_ts"] != nil;
            if (ok) session.version = SNJSONMerge(version, @{@"fetched_at" : @((long long)NSDate.date.timeIntervalSince1970).stringValue});
            if (completion) completion(ok);
        });
    }] resume];
}

@end
