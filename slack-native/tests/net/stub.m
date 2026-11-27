// Owns the URL protocol stub and the run-loop wait.
#import "stub.h"

@implementation SNStubAnswer
+ (instancetype)status:(NSInteger)status headers:(NSDictionary *)headers json:(id)json {
    SNStubAnswer *answer = [self new];
    answer->_status = status;
    answer->_headers = headers ?: @{};
    answer->_body = json ? [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] : [NSData data];
    return answer;
}
@end

static NSDictionary *Fields(NSString *encoded) {
    NSMutableDictionary *fields = [NSMutableDictionary new];
    for (NSString *pair in [encoded componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [[pair substringToIndex:equals.location] stringByRemovingPercentEncoding];
        NSString *value = [[[pair substringFromIndex:NSMaxRange(equals)] stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        if (key && value) fields[key] = value;
    }
    return fields;
}

@implementation SNStubRequest
- (instancetype)initWithRequest:(NSURLRequest *)request body:(NSData *)body {
    if ((self = [super init])) {
        _request = request;
        _body = body;
    }
    return self;
}
- (NSDictionary *)form { return Fields([[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding] ?: @""); }
- (NSDictionary *)query { return Fields(self.request.URL.query ?: @""); }
- (NSString *)method { return self.request.URL.lastPathComponent ?: @""; }
@end

static SNStubHandler currentHandler;
static NSMutableArray<SNStubRequest *> *seen;

@interface SNStubProtocol : NSURLProtocol
@end

@implementation SNStubProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableData *body = [NSMutableData dataWithData:self.request.HTTPBody ?: [NSData data]];
    NSInputStream *stream = self.request.HTTPBodyStream;
    if (stream) {
        [stream open];
        uint8_t buffer[4096];
        NSInteger read;
        while ((read = [stream read:buffer maxLength:sizeof buffer]) > 0) [body appendBytes:buffer length:(NSUInteger)read];
        [stream close];
    }
    SNStubRequest *request = [[SNStubRequest alloc] initWithRequest:self.request body:body];
    SNStubHandler handler;
    @synchronized(SNStubProtocol.class) {
        [seen addObject:request];
        handler = currentHandler;
    }
    SNStubAnswer *answer = handler ? handler(request) : nil;
    if (!answer) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]];
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:answer.status HTTPVersion:@"HTTP/1.1" headerFields:answer.headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:answer.body];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

NSURLSession *SNStubURLSession(SNStubHandler handler) {
    @synchronized(SNStubProtocol.class) {
        currentHandler = [handler copy];
        seen = [NSMutableArray new];
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[ SNStubProtocol.class ];
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.HTTPShouldSetCookies = NO;
    return [NSURLSession sessionWithConfiguration:configuration];
}

NSArray<SNStubRequest *> *SNStubRequests(void) {
    @synchronized(SNStubProtocol.class) {
        return [seen copy] ?: @[];
    }
}

BOOL SNWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

@implementation SNTestAPI

- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableArray new];
        _held = [NSMutableArray new];
    }
    return self;
}

- (void)call:(NSString *)method params:(NSDictionary *)params priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    [self.calls addObject:@[ method, params ]];
    NSDictionary *response = self.answer ? self.answer(method, params) : @{@"ok" : @YES};
    // As SNClient answers: ok:false is Slack's error, its body in the error.
    NSError *error = !response ? SNAPIMakeError(SNAPIErrorNetwork, nil) : [response[@"ok"] isEqual:@NO] ? SNAPISlackError(response) : nil;
    if (error) response = nil;
    dispatch_block_t reply = ^{
        if (completion) completion(response, error);
    };
    if (self.holds) [self.held addObject:reply];
    else dispatch_async(dispatch_get_main_queue(), reply);
}

- (void)callEdge:(NSString *)path body:(NSDictionary *)body priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    [self.calls addObject:@[ path, body ]];
    NSDictionary *response = self.edgeAnswer ? self.edgeAnswer(path, body) : @{@"ok" : @YES, @"results" : @[]};
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(response, response ? nil : SNAPIMakeError(SNAPIErrorNetwork, nil));
    });
}

- (dispatch_block_t)upload:(NSURL *)file name:(NSString *)name mimeType:(NSString *)mimeType to:(NSURL *)url
                  progress:(void (^)(double))progress completion:(void (^)(NSInteger))completion {
    [self.calls addObject:@[ @"upload", @{@"url" : url.absoluteString, @"name" : name, @"mimeType" : mimeType} ]];
    NSInteger status = self.uploadStatus ? self.uploadStatus(url, name) : 200;
    __block BOOL cancelled = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cancelled) return completion(0);
        if (progress) progress(1);
        completion(status);
    });
    return ^{ cancelled = YES; };
}

- (NSArray<NSString *> *)methods {
    NSMutableArray *methods = [NSMutableArray new];
    for (NSArray *call in self.calls) [methods addObject:call[0]];
    return methods;
}

@end
