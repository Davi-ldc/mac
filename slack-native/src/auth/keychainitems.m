// Owns the SecItem calls on the session's items (compiled into the app and the Keychain service).
#import <Security/Security.h>

#import "auth/keychainitems.h"

@implementation SNKeychainItems {
    // The data-protection keychain needs a keychain-access-groups entitlement, which a
    // self-signed build without a provisioning profile cannot carry (errSecMissingEntitlement).
    // Such a build keeps the item in the login keychain instead, where the item's access list
    // trusts the signature; the data-protection-only attributes (accessibility class,
    // synchronizable) do not apply there.
    BOOL _fileBased;
}

+ (instancetype)sessionItems { return [self new]; }

- (NSMutableDictionary *)query {
    NSMutableDictionary *query = [@{(id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"local.slack-native.session"} mutableCopy];
    if (!_fileBased) {
        query[(id)kSecUseDataProtectionKeychain] = @YES;
        query[(id)kSecAttrSynchronizable] = @NO;
    }
    return query;
}

/// Runs `operation` against the data-protection keychain, once more against the file-based one
/// when the build lacks the entitlement. Locked: the app's session saver writes from its own queue.
- (OSStatus)perform:(OSStatus (^)(NSMutableDictionary *query))operation {
    @synchronized(self) {
        OSStatus status = operation([self query]);
        if (_fileBased || (status != errSecMissingEntitlement && status != errSecItemNotFound)) return status;
        // Without the entitlement only writes fail with errSecMissingEntitlement; reads just find
        // nothing, so a read that finds nothing looks in the login keychain too.
        _fileBased = YES;
        OSStatus fileStatus = operation([self query]);
        if (status == errSecMissingEntitlement || fileStatus != errSecItemNotFound) return fileStatus;
        _fileBased = NO;
        return status;
    }
}

- (NSData *)dataForAccount:(NSString *)account {
    __block CFTypeRef result = NULL;
    OSStatus status = [self perform:^OSStatus(NSMutableDictionary *query) {
        query[(id)kSecAttrAccount] = account;
        query[(id)kSecReturnData] = @YES;
        query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
        return SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    }];
    NSData *data = status == errSecSuccess ? CFBridgingRelease(result) : nil;
    return [data isKindOfClass:NSData.class] ? data : nil;
}

- (BOOL)setData:(NSData *)data forAccount:(NSString *)account {
    OSStatus status = [self perform:^OSStatus(NSMutableDictionary *query) {
        query[(id)kSecAttrAccount] = account;
        OSStatus updated = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef) @{(id)kSecValueData : data});
        if (updated != errSecItemNotFound) return updated;
        query[(id)kSecValueData] = data;
        if (!self->_fileBased) query[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        return SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }];
    return status == errSecSuccess;
}

- (void)deleteAccount:(NSString *)account {
    [self perform:^OSStatus(NSMutableDictionary *query) {
        query[(id)kSecAttrAccount] = account;
        return SecItemDelete((__bridge CFDictionaryRef)query);
    }];
}

- (NSArray<NSString *> *)accounts {
    __block CFTypeRef result = NULL;
    OSStatus status = [self perform:^OSStatus(NSMutableDictionary *query) {
        query[(id)kSecReturnAttributes] = @YES;
        query[(id)kSecMatchLimit] = (id)kSecMatchLimitAll;
        return SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    }];
    NSArray<NSDictionary *> *items = status == errSecSuccess ? CFBridgingRelease(result) : nil;
    if (![items isKindOfClass:NSArray.class]) return @[];
    items = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *dateA = a[(id)kSecAttrCreationDate] ?: NSDate.distantPast, *dateB = b[(id)kSecAttrCreationDate] ?: NSDate.distantPast;
        return [dateA compare:dateB];
    }];
    NSMutableArray<NSString *> *accounts = [NSMutableArray new];
    for (NSDictionary *item in items) {
        NSString *account = item[(id)kSecAttrAccount];
        if ([account isKindOfClass:NSString.class]) [accounts addObject:account];
    }
    return accounts;
}

@end
