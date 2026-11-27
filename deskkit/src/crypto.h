// Encryption at rest for the clipboard history.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 64 random bytes in the login Keychain (32 for AES, 32 for HMAC), created only when no
/// such item exists. Returns nil when the Keychain cannot be read now; try again later.
NSData *_Nullable DKKeychainKey(NSString *service, NSString *account);
void DKKeychainDelete(NSString *service, NSString *account);
/// AES-256-CBC, then HMAC-SHA256 over IV and ciphertext.
NSData *_Nullable DKEncrypt(NSData *plain, NSData *key);
/// Returns nil when the data was tampered with or the key is wrong.
NSData *_Nullable DKDecrypt(NSData *sealed, NSData *key);

NS_ASSUME_NONNULL_END
