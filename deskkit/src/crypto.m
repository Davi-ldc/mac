// Owns the clipboard key in the Keychain and the sealing format of stored entries.
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>

#import "crypto.h"

static NSString *const kSealVersion = @"DK1";
static const size_t kKeyBytes = 64;

static NSDictionary *KeychainQuery(NSString *service, NSString *account) {
    return @{
        (id)kSecClass : (id)kSecClassGenericPassword,
        (id)kSecAttrService : service,
        (id)kSecAttrAccount : account,
    };
}

NSData *DKKeychainKey(NSString *service, NSString *account) {
    NSMutableDictionary *query = [KeychainQuery(service, account) mutableCopy];
    query[(id)kSecReturnData] = @YES;
    CFTypeRef found = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &found);
    if (status == errSecSuccess) return CFBridgingRelease(found);
    // A locked Keychain or a refused prompt can pass; a new key now would make everything
    // sealed with the existing one unreadable.
    if (status != errSecItemNotFound) return nil;

    NSMutableData *key = [NSMutableData dataWithLength:kKeyBytes];
    if (SecRandomCopyBytes(kSecRandomDefault, kKeyBytes, key.mutableBytes) != errSecSuccess) return nil;
    NSMutableDictionary *item = [KeychainQuery(service, account) mutableCopy];
    item[(id)kSecValueData] = key;
    item[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    item[(id)kSecAttrLabel] = @"deskkit clipboard history key";
    return SecItemAdd((CFDictionaryRef)item, NULL) == errSecSuccess ? key : nil;
}

void DKKeychainDelete(NSString *service, NSString *account) {
    SecItemDelete((CFDictionaryRef)KeychainQuery(service, account));
}

static NSData *Mac(NSData *key, NSData *covered) {
    NSMutableData *mac = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, (const uint8_t *)key.bytes + 32, 32, covered.bytes, covered.length,
           mac.mutableBytes);
    return mac;
}

NSData *DKEncrypt(NSData *plain, NSData *key) {
    if (key.length != kKeyBytes) return nil;
    NSMutableData *sealed = [[kSealVersion dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    uint8_t iv[kCCBlockSizeAES128];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof iv, iv) != errSecSuccess) return nil;
    [sealed appendBytes:iv length:sizeof iv];
    NSMutableData *cipher = [NSMutableData dataWithLength:plain.length + kCCBlockSizeAES128];
    size_t written = 0;
    if (CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, 32, iv, plain.bytes,
                plain.length, cipher.mutableBytes, cipher.length, &written) != kCCSuccess)
        return nil;
    [sealed appendBytes:cipher.bytes length:written];
    [sealed appendData:Mac(key, sealed)];
    return sealed;
}

NSData *DKDecrypt(NSData *sealed, NSData *key) {
    size_t header = kSealVersion.length, ivLength = kCCBlockSizeAES128, macLength = CC_SHA256_DIGEST_LENGTH;
    if (key.length != kKeyBytes || sealed.length < header + ivLength + macLength) return nil;
    if (![[sealed subdataWithRange:NSMakeRange(0, header)]
            isEqualToData:[kSealVersion dataUsingEncoding:NSASCIIStringEncoding]])
        return nil;
    NSData *covered = [sealed subdataWithRange:NSMakeRange(0, sealed.length - macLength)];
    NSData *mac = [sealed subdataWithRange:NSMakeRange(sealed.length - macLength, macLength)];
    if (timingsafe_bcmp(Mac(key, covered).bytes, mac.bytes, macLength) != 0) return nil;
    const uint8_t *iv = (const uint8_t *)sealed.bytes + header;
    NSData *cipher = [covered subdataWithRange:NSMakeRange(header + ivLength, covered.length - header - ivLength)];
    NSMutableData *plain = [NSMutableData dataWithLength:cipher.length];
    size_t written = 0;
    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, 32, iv, cipher.bytes,
                cipher.length, plain.mutableBytes, plain.length, &written) != kCCSuccess)
        return nil;
    plain.length = written;
    return plain;
}
