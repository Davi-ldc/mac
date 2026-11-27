// Loopback HTTP/1.1 + RFC 6455 WebSocket mock server on 127.0.0.1:<ephemeral-port>.
#import "mockserver.h"

#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <signal.h>
#import <sys/socket.h>
#import <unistd.h>

@implementation SPMockRequest
- (NSDictionary *)jsonBody {
    if (!self.body.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:self.body options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}
- (NSString *)bodyString {
    if (!self.body.length) return nil;
    return [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
}
@end

@implementation SPMockResponse
+ (instancetype)responseWithStatus:(NSInteger)status json:(id)jsonObject {
    NSData *d = jsonObject ? [NSJSONSerialization dataWithJSONObject:jsonObject options:0 error:nil] : [NSData data];
    return [self responseWithStatus:status contentType:@"application/json" data:d ?: [NSData data]];
}
+ (instancetype)responseWithStatus:(NSInteger)status contentType:(NSString *)contentType data:(NSData *)data {
    SPMockResponse *r = [SPMockResponse new];
    r.status = status;
    r.headers = contentType.length ? @{@"Content-Type" : contentType} : @{};
    r.body = data ?: [NSData data];
    return r;
}
@end

static int OpenLoopbackListener(uint16_t *outPort) {
    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) != 0) {
        close(fd);
        return -1;
    }
    if (outPort) *outPort = ntohs(addr.sin_port);
    return fd;
}

static BOOL SendAll(int fd, const void *bytes, size_t len) {
    const uint8_t *p = (const uint8_t *)bytes;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n <= 0) return NO;
        sent += (size_t)n;
    }
    return YES;
}

static SPMockRequest *ReadHTTPRequest(int fd) {
    NSMutableData *buf = [NSMutableData dataWithCapacity:4096];
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange hdrRange = NSMakeRange(NSNotFound, 0);
    uint8_t tmp[4096];

    while (hdrRange.location == NSNotFound) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n <= 0) return nil;
        [buf appendBytes:tmp length:(size_t)n];
        hdrRange = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
        if (buf.length > 256 * 1024) return nil;
    }

    NSString *headerStr = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrRange.location)]
                                                encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if (!lines.count) return nil;
    NSArray<NSString *> *reqParts = [lines[0] componentsSeparatedByString:@" "];
    if (reqParts.count < 2) return nil;

    SPMockRequest *req = [SPMockRequest new];
    req.method = reqParts[0];
    req.path = reqParts[1];

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary new];
    NSUInteger contentLength = 0;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *k = [[lines[i] substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        NSString *v = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (k.length) headers[k] = v;
        if ([k isEqualToString:@"content-length"]) contentLength = (NSUInteger)MAX(0, v.integerValue);
    }
    req.headers = [headers copy];

    NSUInteger bodyStart = hdrRange.location + hdrRange.length;
    NSMutableData *body = [NSMutableData dataWithCapacity:contentLength];
    if (buf.length > bodyStart) {
        [body appendData:[buf subdataWithRange:NSMakeRange(bodyStart, buf.length - bodyStart)]];
    }
    while (body.length < contentLength) {
        size_t need = MIN(sizeof(tmp), contentLength - body.length);
        ssize_t n = recv(fd, tmp, need, 0);
        if (n <= 0) break;
        [body appendBytes:tmp length:(size_t)n];
    }
    if (body.length > contentLength && contentLength > 0) {
        req.body = [body subdataWithRange:NSMakeRange(0, contentLength)];
    } else {
        req.body = [body copy];
    }
    return req;
}

#pragma mark - SPMockHTTPServer

@implementation SPMockHTTPServer {
    int _listenFD;
    BOOL _running;
    NSMutableArray<SPMockRequest *> *_recorded;
    dispatch_queue_t _acceptQueue;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _listenFD = -1;
    _recorded = [NSMutableArray new];
    _acceptQueue = dispatch_queue_create("local.spotify-native.test.http", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc { [self stop]; }

- (NSURL *)baseURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u", (unsigned)_port]];
}

- (NSURL *)urlForPath:(NSString *)path {
    NSString *p = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path];
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u%@", (unsigned)_port, p]];
}

- (NSArray<SPMockRequest *> *)recordedRequests {
    @synchronized(_recorded) { return [_recorded copy]; }
}

- (BOOL)start {
    uint16_t p = 0;
    _listenFD = OpenLoopbackListener(&p);
    if (_listenFD < 0) return NO;
    _port = p;
    _running = YES;

    dispatch_async(_acceptQueue, ^{
        while (self->_running) {
            int client = accept(self->_listenFD, NULL, NULL);
            if (client < 0) break;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                struct timeval tv = {.tv_sec = 5, .tv_usec = 0};
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                SPMockRequest *req = ReadHTTPRequest(client);
                if (req) {
                    @synchronized(self->_recorded) { [self->_recorded addObject:req]; }
                    SPMockResponse *resp = self.handler ? self.handler(req) : [SPMockResponse responseWithStatus:200 json:@{}];
                    if (resp.delaySeconds > 0) {
                        usleep((useconds_t)(resp.delaySeconds * 1e6));
                    }
                    NSData *body = resp.body ?: [NSData data];
                    NSMutableString *hdr = [NSMutableString stringWithFormat:
                        @"HTTP/1.1 %ld OK\r\nContent-Length: %lu\r\nConnection: close\r\n",
                        (long)(resp ? resp.status : 200), (unsigned long)body.length];
                    for (NSString *k in resp.headers) {
                        [hdr appendFormat:@"%@: %@\r\n", k, resp.headers[k]];
                    }
                    [hdr appendString:@"\r\n"];
                    NSData *hdrData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
                    SendAll(client, hdrData.bytes, hdrData.length);
                    if (body.length) SendAll(client, body.bytes, body.length);
                }
                close(client);
            });
        }
    });
    return YES;
}

- (void)stop {
    _running = NO;
    if (_listenFD >= 0) {
        shutdown(_listenFD, SHUT_RDWR);
        close(_listenFD);
        _listenFD = -1;
    }
}

@end

#pragma mark - SPMockWebSocketServer

@implementation SPMockWebSocketServer {
    int _listenFD;
    int _clientFD;
    BOOL _running;
    NSMutableArray<NSString *> *_received;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _listenFD = -1;
    _clientFD = -1;
    _received = [NSMutableArray new];
    _queue = dispatch_queue_create("local.spotify-native.test.ws", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc { [self stop]; }

- (NSURL *)wsURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%u/", (unsigned)_port]];
}

- (BOOL)hasClient {
    @synchronized(self) { return _clientFD >= 0; }
}

- (NSArray<NSString *> *)receivedTextFrames {
    @synchronized(_received) { return [_received copy]; }
}

static NSString *WebSocketAcceptKey(NSString *clientKey) {
    NSString *concat = [clientKey stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    NSData *inData = [concat dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(inData.bytes, (CC_LONG)inData.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

static BOOL RecvExact(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n <= 0) return NO;
        got += (size_t)n;
    }
    return YES;
}

- (BOOL)sendFrameOpcode:(uint8_t)opcode payload:(NSData *)payload {
    int fd = -1;
    @synchronized(self) { fd = _clientFD; }
    if (fd < 0) return NO;
    NSMutableData *frame = [NSMutableData dataWithCapacity:payload.length + 10];
    uint8_t b0 = (uint8_t)(0x80u | (opcode & 0x0Fu));
    [frame appendBytes:&b0 length:1];
    NSUInteger len = payload.length;
    if (len < 126) {
        uint8_t b1 = (uint8_t)len;
        [frame appendBytes:&b1 length:1];
    } else if (len <= 65535) {
        uint8_t b1 = 126;
        uint8_t ext[2] = {(uint8_t)(len >> 8), (uint8_t)(len & 0xFF)};
        [frame appendBytes:&b1 length:1];
        [frame appendBytes:ext length:2];
    } else {
        uint8_t b1 = 127;
        uint64_t l64 = (uint64_t)len;
        uint8_t ext[8];
        for (int i = 7; i >= 0; i--) { ext[i] = (uint8_t)(l64 & 0xFF); l64 >>= 8; }
        [frame appendBytes:&b1 length:1];
        [frame appendBytes:ext length:8];
    }
    if (payload.length) [frame appendData:payload];
    @synchronized(self) {
        if (_clientFD < 0) return NO;
        return SendAll(_clientFD, frame.bytes, frame.length);
    }
}

- (BOOL)sendTextFrame:(NSString *)text {
    return [self sendFrameOpcode:0x1 payload:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)closeClient {
    @synchronized(self) {
        if (_clientFD >= 0) {
            shutdown(_clientFD, SHUT_RDWR);
            close(_clientFD);
            _clientFD = -1;
        }
    }
}

- (BOOL)start {
    uint16_t p = 0;
    _listenFD = OpenLoopbackListener(&p);
    if (_listenFD < 0) return NO;
    _port = p;
    _running = YES;

    dispatch_async(_queue, ^{
        while (self->_running) {
            int client = accept(self->_listenFD, NULL, NULL);
            if (client < 0) break;
            SPMockRequest *req = ReadHTTPRequest(client);
            NSString *wsKey = req.headers[@"sec-websocket-key"];
            if (!req || !wsKey.length) {
                close(client);
                continue;
            }
            self->_lastRequestPath = [req.path copy];
            NSString *acceptKey = WebSocketAcceptKey(wsKey);
            NSString *resp = [NSString stringWithFormat:
                @"HTTP/1.1 101 Switching Protocols\r\n"
                @"Upgrade: websocket\r\n"
                @"Connection: Upgrade\r\n"
                @"Sec-WebSocket-Accept: %@\r\n\r\n", acceptKey];
            NSData *respData = [resp dataUsingEncoding:NSUTF8StringEncoding];
            if (!SendAll(client, respData.bytes, respData.length)) {
                close(client);
                continue;
            }
            @synchronized(self) {
                if (self->_clientFD >= 0) close(self->_clientFD);
                self->_clientFD = client;
            }
            // Read client frames until close.
            while (self->_running) {
                uint8_t hdr[2];
                if (!RecvExact(client, hdr, 2)) break;
                uint8_t opcode = hdr[0] & 0x0Fu;
                BOOL masked = (hdr[1] & 0x80u) != 0;
                uint64_t plen = hdr[1] & 0x7Fu;
                if (plen == 126) {
                    uint8_t ext[2];
                    if (!RecvExact(client, ext, 2)) break;
                    plen = ((uint64_t)ext[0] << 8) | ext[1];
                } else if (plen == 127) {
                    uint8_t ext[8];
                    if (!RecvExact(client, ext, 8)) break;
                    plen = 0;
                    for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
                }
                uint8_t mask[4] = {0, 0, 0, 0};
                if (masked && !RecvExact(client, mask, 4)) break;
                NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)plen];
                if (plen > 0 && !RecvExact(client, payload.mutableBytes, (size_t)plen)) break;
                if (masked) {
                    uint8_t *b = (uint8_t *)payload.mutableBytes;
                    for (uint64_t i = 0; i < plen; i++) b[i] ^= mask[i & 3];
                }
                if (opcode == 0x8) break; // Close
                if (opcode == 0x9) {      // Ping -> Pong
                    [self sendFrameOpcode:0xA payload:payload];
                } else if (opcode == 0x1) { // Text
                    NSString *s = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
                    if (s) {
                        @synchronized(self->_received) { [self->_received addObject:s]; }
                    }
                }
            }
            @synchronized(self) {
                if (self->_clientFD == client) {
                    close(client);
                    self->_clientFD = -1;
                }
            }
        }
    });
    return YES;
}

- (void)stop {
    _running = NO;
    [self closeClient];
    if (_listenFD >= 0) {
        shutdown(_listenFD, SHUT_RDWR);
        close(_listenFD);
        _listenFD = -1;
    }
}

@end
