// Owns the app's way to the session's Keychain item and the in-memory store tests use instead.
#import "auth/keychain.h"
#import "auth/keychainitems.h"

@implementation SNKeychain {
    NSString *_serviceName;
    NSXPCConnection *_connection;
    /// Without the service.
    SNKeychainItems *_items;
    NSError *_lastError;
}

+ (instancetype)sessionKeychain {
    SNKeychain *keychain = [self new];
    NSString *service = @"local.slack-native.keychain";
    NSURL *bundle = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Contents/XPCServices/%@.xpc", service]];
    if (![NSFileManager.defaultManager fileExistsAtPath:bundle.path]) {
        keychain->_items = [SNKeychainItems sessionItems];
        return keychain;
    }
    keychain->_serviceName = service;
    [keychain connection];
    return keychain;
}

- (void)dealloc { [_connection invalidate]; }

- (NSError *)lastError {
    @synchronized(self) {
        return _lastError;
    }
}

- (NSXPCConnection *)connection {
    @synchronized(self) {
        if (!_connection && _serviceName) {
            NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:_serviceName];
            connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SNKeychainService)];
            __weak SNKeychain *weakSelf = self;
            connection.invalidationHandler = ^{
                SNKeychain *strong = weakSelf;
                if (!strong) return;
                @synchronized(strong) {
                    if (strong->_connection == connection) strong->_connection = nil;
                }
            };
            [connection resume];
            _connection = connection;
        }
        return _connection;
    }
}

- (void)resetConnection {
    @synchronized(self) {
        [_connection invalidate];
        _connection = nil;
    }
}

/// Calls the XPC service synchronously; retries once after an interruption or invalidation so a
/// transient XPC restart is not mistaken for a signed-out session.
- (void)callService:(void (^)(id<SNKeychainService> service))block {
    NSError *lastError = nil;
    for (int attempt = 0; attempt < 2; attempt++) {
        NSXPCConnection *connection = [self connection];
        if (!connection) break;
        __block NSError *callError = nil;
        id<SNKeychainService> proxy = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError *error) { callError = error; }];
        block(proxy);
        if (!callError) {
            @synchronized(self) { _lastError = nil; }
            return;
        }
        lastError = callError;
        if (callError.code == NSXPCConnectionInvalid) [self resetConnection];
    }
    @synchronized(self) { _lastError = lastError; }
    if (lastError) NSLog(@"slack-native: keychain xpc failed: %@", lastError);
}

// Remember the non-secret account ID so launch reads the session in one XPC hop without changing
// the Keychain XPC binary (whose cdhash must stay byte-identical across rebuilds to keep ACL trust).
static NSString *const kLastAccountKey = @"SNLastSessionAccount";

- (NSData *)firstAccountData {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *remembered = [defaults stringForKey:kLastAccountKey];
    if (remembered.length) {
        NSData *data = [self dataForAccount:remembered];
        if (data || self.lastError) return data;
    }
    NSString *account = [self accounts].firstObject;
    if (!account) {
        if (!self.lastError && remembered) [defaults removeObjectForKey:kLastAccountKey];
        return nil;
    }
    NSData *data = [self dataForAccount:account];
    if (data && ![account isEqualToString:remembered]) [defaults setObject:account forKey:kLastAccountKey];
    return data;
}

- (NSData *)dataForAccount:(NSString *)account {
    if (_items) return [_items dataForAccount:account];
    __block NSData *data = nil;
    [self callService:^(id<SNKeychainService> service) {
        [service dataForAccount:account reply:^(NSData *stored) { data = stored; }];
    }];
    return data;
}

- (BOOL)setData:(NSData *)data forAccount:(NSString *)account {
    BOOL saved = NO;
    if (_items) saved = [_items setData:data forAccount:account];
    else {
        __block BOOL ok = NO;
        [self callService:^(id<SNKeychainService> service) {
            [service setData:data forAccount:account reply:^(BOOL done) { ok = done; }];
        }];
        saved = ok;
    }
    if (saved) [NSUserDefaults.standardUserDefaults setObject:account forKey:kLastAccountKey];
    return saved;
}

- (void)deleteAccount:(NSString *)account {
    if (_items) [_items deleteAccount:account];
    else {
        [self callService:^(id<SNKeychainService> service) {
            [service deleteAccount:account reply:^{}];
        }];
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:kLastAccountKey] isEqualToString:account]) [defaults removeObjectForKey:kLastAccountKey];
}

- (NSArray<NSString *> *)accounts {
    if (_items) return [_items accounts];
    __block NSArray<NSString *> *accounts = @[];
    [self callService:^(id<SNKeychainService> service) {
        [service accountsWithReply:^(NSArray<NSString *> *stored) { accounts = stored; }];
    }];
    return accounts;
}

@end

@implementation SNMemorySecretStore {
    NSMutableArray<NSString *> *_accounts;
    NSMutableDictionary<NSString *, NSData *> *_items;
}

- (instancetype)init {
    if ((self = [super init])) {
        _accounts = [NSMutableArray new];
        _items = [NSMutableDictionary new];
    }
    return self;
}

// Locked like the Keychain is: the session saver writes from its own queue.
- (NSData *)dataForAccount:(NSString *)account {
    @synchronized(self) {
        return _items[account];
    }
}

- (BOOL)setData:(NSData *)data forAccount:(NSString *)account {
    @synchronized(self) {
        if (!_items[account]) [_accounts addObject:account];
        _items[account] = [data copy];
        return YES;
    }
}

- (void)deleteAccount:(NSString *)account {
    @synchronized(self) {
        [_accounts removeObject:account];
        [_items removeObjectForKey:account];
    }
}

- (NSArray<NSString *> *)accounts {
    @synchronized(self) {
        return [_accounts copy];
    }
}

@end

@implementation SNSessionSaver {
    SNSession *_session;
    id<SNSecretStore> _store;
    NSTimeInterval _delay;
    dispatch_queue_t _queue;
    /// A write is scheduled, or the saver was cancelled at sign-out (touched on _queue only).
    BOOL _pending, _cancelled;
}

- (instancetype)initWithSession:(SNSession *)session store:(id<SNSecretStore>)store delay:(NSTimeInterval)delay {
    if (!(self = [super init])) return nil;
    _session = session;
    _store = store;
    _delay = delay;
    _queue = dispatch_queue_create("slack-native.session-saver", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)sessionChanged {
    dispatch_async(_queue, ^{
        if (self->_cancelled || self->_pending) return;
        self->_pending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self->_delay * NSEC_PER_SEC)), self->_queue, ^{
            if (self->_cancelled || !self->_pending) return;
            self->_pending = NO;
            SNSaveSession(self->_session, self->_store);
        });
    });
}

- (void)flush {
    // Written even without a change: a cookie whose expiry alone moved is not a change, and the
    // last state of the jar is what the next launch starts from.
    dispatch_sync(_queue, ^{
        if (self->_cancelled) return;
        self->_pending = NO;
        SNSaveSession(self->_session, self->_store);
    });
}

- (void)cancel {
    dispatch_sync(_queue, ^{
        self->_cancelled = YES;
        self->_pending = NO;
    });
}

@end

SNSession *SNLoadSession(id<SNSecretStore> store) {
    NSData *data = nil;
    if ([store respondsToSelector:@selector(firstAccountData)]) data = [store firstAccountData];
    else {
        NSString *account = store.accounts.firstObject;
        data = account ? [store dataForAccount:account] : nil;
    }
    return data ? [SNSession sessionWithData:data] : nil;
}

BOOL SNSaveSession(SNSession *session, id<SNSecretStore> store) {
    NSString *account = session.account;
    if (![store setData:session.data forAccount:account]) return NO;
    // One session at a time: a sign-in as someone else replaces the previous one.
    for (NSString *other in store.accounts)
        if (![other isEqualToString:account]) [store deleteAccount:other];
    return YES;
}
