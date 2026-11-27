// Single-item Keychain session storage + pluggable in-memory store for tests.
#import "auth/keychain.h"
#import "model/json.h"

#import <Security/Security.h>

static NSString *const kSPKeychainService = @"local.spotify-native.session";

static BOOL HasDataProtectionEntitlement(void) {
    SecCodeRef code = NULL;
    CFDictionaryRef info = NULL;
    BOOL entitled = NO;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) == errSecSuccess && info) {
        NSDictionary *ent = ((__bridge NSDictionary *)info)[(__bridge id)kSecCodeInfoEntitlementsDict];
        id groups = [ent isKindOfClass:NSDictionary.class] ? ent[@"keychain-access-groups"] : nil;
        entitled = [groups isKindOfClass:NSArray.class] && [groups count] > 0;
    }
    if (info) CFRelease(info);
    if (code) CFRelease(code);
    return entitled;
}

@implementation SPKeychain {
    NSString *_service;
    BOOL _fileBased;
    SPSecItemCopyMatchingHook _copyMatching;
}

+ (instancetype)sessionKeychain {
    return [self new];
}

- (instancetype)init {
    return [self initWithService:kSPKeychainService fileBased:!HasDataProtectionEntitlement() copyMatching:nil];
}

- (instancetype)initWithService:(NSString *)service
                      fileBased:(BOOL)fileBased
                   copyMatching:(SPSecItemCopyMatchingHook)copyMatching {
    if (!(self = [super init])) return nil;
    _service = [service.length ? service : kSPKeychainService copy];
    _fileBased = fileBased;
    _copyMatching = [copyMatching copy];
    return self;
}

- (OSStatus)copyMatchingQuery:(CFDictionaryRef)query result:(CFTypeRef *)result {
    if (_copyMatching) {
        return _copyMatching(query, result);
    }
    return SecItemCopyMatching(query, result);
}

- (NSMutableDictionary *)baseQuery {
    NSMutableDictionary *q = [@{
        (id)kSecClass : (id)kSecClassGenericPassword,
        (id)kSecAttrService : _service,
    } mutableCopy];
    if (!_fileBased) {
        q[(id)kSecUseDataProtectionKeychain] = @YES;
        q[(id)kSecAttrSynchronizable] = @NO;
    }
    return q;
}

- (OSStatus)perform:(OSStatus (^)(NSMutableDictionary *query))op {
    @synchronized(self) {
        OSStatus status = op([self baseQuery]);
        if (_fileBased || (status != errSecMissingEntitlement && status != errSecItemNotFound)) return status;
        _fileBased = YES;
        OSStatus fallback = op([self baseQuery]);
        if (status == errSecMissingEntitlement || fallback != errSecItemNotFound) return fallback;
        _fileBased = NO;
        return status;
    }
}

- (NSData *)firstAccountData {
    // Legacy macOS file-based login Keychain rejects kSecReturnData combined with kSecMatchLimitAll (errSecParam -50).
    // SPSaveSessionBlob maintains a single item per service, so kSecMatchLimitOne + kSecReturnData works on both keychains.
    __block CFTypeRef result = NULL;
    OSStatus status = [self perform:^OSStatus(NSMutableDictionary *q) {
        q[(id)kSecReturnData] = @YES;
        q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
        return [self copyMatchingQuery:(__bridge CFDictionaryRef)q result:&result];
    }];
    if (status == errSecSuccess && result != NULL) {
        NSData *data = CFBridgingRelease(result);
        if ([data isKindOfClass:NSData.class]) return data;
    } else if (result != NULL) {
        CFRelease(result);
    }
    // Clean fallback: enumerate attributes only (never with kSecReturnData) and read first account.
    NSString *acct = [self accounts].firstObject;
    return acct.length ? [self dataForAccount:acct] : nil;
}

- (NSData *)dataForAccount:(NSString *)account {
    __block CFTypeRef result = NULL;
    OSStatus status = [self perform:^OSStatus(NSMutableDictionary *q) {
        q[(id)kSecAttrAccount] = account;
        q[(id)kSecReturnData] = @YES;
        q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
        return [self copyMatchingQuery:(__bridge CFDictionaryRef)q result:&result];
    }];
    NSData *data = (status == errSecSuccess && result != NULL) ? CFBridgingRelease(result) : nil;
    if (status != errSecSuccess && result != NULL) CFRelease(result);
    return [data isKindOfClass:NSData.class] ? data : nil;
}

- (BOOL)setData:(NSData *)data forAccount:(NSString *)account {
    OSStatus status = [self perform:^OSStatus(NSMutableDictionary *q) {
        q[(id)kSecAttrAccount] = account;
        OSStatus upd = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef) @{(id)kSecValueData : data});
        if (upd != errSecItemNotFound) return upd;
        q[(id)kSecValueData] = data;
        if (!self->_fileBased) q[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        return SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    }];
    return status == errSecSuccess;
}

- (void)deleteAccount:(NSString *)account {
    [self perform:^OSStatus(NSMutableDictionary *q) {
        q[(id)kSecAttrAccount] = account;
        return SecItemDelete((__bridge CFDictionaryRef)q);
    }];
}

- (NSArray<NSString *> *)accounts {
    __block CFTypeRef result = NULL;
    OSStatus status = [self perform:^OSStatus(NSMutableDictionary *q) {
        q[(id)kSecReturnAttributes] = @YES;
        q[(id)kSecMatchLimit] = (id)kSecMatchLimitAll;
        return [self copyMatchingQuery:(__bridge CFDictionaryRef)q result:&result];
    }];
    NSArray<NSDictionary *> *items = (status == errSecSuccess && result != NULL) ? CFBridgingRelease(result) : nil;
    if (status != errSecSuccess && result != NULL) CFRelease(result);
    if (![items isKindOfClass:NSArray.class]) return @[];
    if (items.count > 1) {
        items = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSDate *da = a[(id)kSecAttrModificationDate] ?: a[(id)kSecAttrCreationDate] ?: NSDate.distantPast;
            NSDate *db = b[(id)kSecAttrModificationDate] ?: b[(id)kSecAttrCreationDate] ?: NSDate.distantPast;
            return [db compare:da];
        }];
    }
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSString *acct = item[(id)kSecAttrAccount];
        if ([acct isKindOfClass:NSString.class]) [out addObject:acct];
    }
    return out;
}

@end

@implementation SPMemorySecretStore {
    NSMutableArray<NSString *> *_accounts;
    NSMutableDictionary<NSString *, NSData *> *_items;
    NSUInteger _readCount;
    NSUInteger _writeCount;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _accounts = [NSMutableArray new];
    _items = [NSMutableDictionary new];
    return self;
}

- (NSUInteger)readCount {
    @synchronized(self) { return _readCount; }
}

- (NSUInteger)writeCount {
    @synchronized(self) { return _writeCount; }
}

- (NSData *)firstAccountData {
    @synchronized(self) {
        _readCount++;
        NSString *first = _accounts.firstObject;
        return first ? _items[first] : nil;
    }
}

- (NSData *)dataForAccount:(NSString *)account {
    @synchronized(self) {
        _readCount++;
        return _items[account];
    }
}

- (BOOL)setData:(NSData *)data forAccount:(NSString *)account {
    @synchronized(self) {
        _writeCount++;
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
    @synchronized(self) { return [_accounts copy]; }
}

@end

@implementation SPSessionBlob

- (instancetype)initWithAccessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken
               accessTokenExpiresAt:(NSTimeInterval)accessTokenExpiresAt
                           username:(NSString *)username
                           deviceID:(NSString *)deviceID
                        clientToken:(NSString *)clientToken
               clientTokenExpiresAt:(NSTimeInterval)clientTokenExpiresAt
                         soloistKey:(NSString *)soloistKey {
    if (!(self = [super init])) return nil;
    _accessToken = [accessToken copy];
    _refreshToken = [refreshToken copy];
    _accessTokenExpiresAt = accessTokenExpiresAt;
    _username = [username ?: @"" copy];
    _deviceID = [deviceID copy];
    _clientToken = [clientToken copy];
    _clientTokenExpiresAt = clientTokenExpiresAt;
    _soloistKey = [soloistKey copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (NSString *)accountKey {
    return _username.length ? _username : @"default";
}

+ (instancetype)blobFromJSONData:(NSData *)data {
    if (!data.length) return nil;
    NSDictionary *d = SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
    if (!d) return nil;
    NSString *deviceID = SPJSONString(d[@"device_id"]);
    if (!deviceID.length) return nil;
    return [[self alloc] initWithAccessToken:SPJSONString(d[@"access_token"])
                                refreshToken:SPJSONString(d[@"refresh_token"])
                        accessTokenExpiresAt:SPJSONDouble(d[@"access_token_expires_at"], 0)
                                    username:SPJSONString(d[@"username"]) ?: @""
                                    deviceID:deviceID
                                 clientToken:SPJSONString(d[@"client_token"])
                        clientTokenExpiresAt:SPJSONDouble(d[@"client_token_expires_at"], 0)
                                  soloistKey:SPJSONString(d[@"soloist_key"])];
}

- (NSData *)toJSONData {
    NSMutableDictionary *d = [NSMutableDictionary new];
    d[@"device_id"] = _deviceID;
    d[@"username"] = _username ?: @"";
    if (_accessToken) d[@"access_token"] = _accessToken;
    if (_refreshToken) d[@"refresh_token"] = _refreshToken;
    d[@"access_token_expires_at"] = @(_accessTokenExpiresAt);
    if (_clientToken) d[@"client_token"] = _clientToken;
    d[@"client_token_expires_at"] = @(_clientTokenExpiresAt);
    if (_soloistKey) d[@"soloist_key"] = _soloistKey;
    return [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
}

- (instancetype)withAccessToken:(NSString *)accessToken
                   refreshToken:(NSString *)refreshToken
                      expiresAt:(NSTimeInterval)expiresAt
                       username:(NSString *)username {
    NSString *resolvedUser = username.length ? username : _username;
    return [[SPSessionBlob alloc] initWithAccessToken:accessToken
                                         refreshToken:refreshToken
                                 accessTokenExpiresAt:expiresAt
                                             username:resolvedUser
                                             deviceID:_deviceID
                                          clientToken:_clientToken
                                 clientTokenExpiresAt:_clientTokenExpiresAt
                                           soloistKey:_soloistKey];
}

- (instancetype)withClientToken:(NSString *)clientToken expiresAt:(NSTimeInterval)expiresAt {
    return [[SPSessionBlob alloc] initWithAccessToken:_accessToken
                                         refreshToken:_refreshToken
                                 accessTokenExpiresAt:_accessTokenExpiresAt
                                             username:_username
                                             deviceID:_deviceID
                                          clientToken:clientToken
                                 clientTokenExpiresAt:expiresAt
                                           soloistKey:_soloistKey];
}

- (instancetype)withSoloistKey:(NSString *)soloistKey {
    return [[SPSessionBlob alloc] initWithAccessToken:_accessToken
                                         refreshToken:_refreshToken
                                 accessTokenExpiresAt:_accessTokenExpiresAt
                                             username:_username
                                             deviceID:_deviceID
                                          clientToken:_clientToken
                                 clientTokenExpiresAt:_clientTokenExpiresAt
                                           soloistKey:soloistKey];
}

@end

static dispatch_queue_t SPKeychainQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("local.spotify-native.keychain", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

SPSessionBlob *SPLoadSessionBlob(id<SPSecretStore> store) {
    if (!store) return nil;
    NSData *data = nil;
    if ([store respondsToSelector:@selector(firstAccountData)]) {
        data = [store firstAccountData];
    }
    if (!data) {
        NSString *acct = store.accounts.firstObject;
        data = acct ? [store dataForAccount:acct] : nil;
    }
    return data ? [SPSessionBlob blobFromJSONData:data] : nil;
}

BOOL SPSaveSessionBlob(SPSessionBlob *blob, id<SPSecretStore> store) {
    if (!blob || !store) return NO;
    NSData *data = [blob toJSONData];
    if (!data) return NO;
    NSString *acct = blob.accountKey;
    if (![store setData:data forAccount:acct]) return NO;
    for (NSString *other in store.accounts) {
        if (![other isEqualToString:acct]) [store deleteAccount:other];
    }
    return YES;
}

void SPDeleteAllSessions(id<SPSecretStore> store) {
    if (!store) return;
    for (NSString *acct in [store.accounts copy]) {
        [store deleteAccount:acct];
    }
}

void SPLoadSessionBlobAsync(id<SPSecretStore> store, void (^completion)(SPSessionBlob *blob)) {
    dispatch_async(SPKeychainQueue(), ^{
        SPSessionBlob *blob = SPLoadSessionBlob(store);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(blob);
        });
    });
}

void SPSaveSessionBlobAsync(SPSessionBlob *blob, id<SPSecretStore> store, void (^completion)(BOOL saved)) {
    dispatch_async(SPKeychainQueue(), ^{
        BOOL ok = SPSaveSessionBlob(blob, store);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok);
            });
        }
    });
}

void SPDeleteAllSessionsAsync(id<SPSecretStore> store, void (^completion)(void)) {
    dispatch_async(SPKeychainQueue(), ^{
        SPDeleteAllSessions(store);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}
