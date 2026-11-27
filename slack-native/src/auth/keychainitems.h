// The session's Keychain items, read and written directly, and the contract of the Keychain
// service that does it for the app (services/keychain).
//
// Why a service: a build signed with a certificate of its own keeps the item in the login
// keychain (see SNKeychainItems), whose check has two parts. The access list names the app by
// its designated requirement (identifier and certificate), which every build meets; the
// partition list names it by "cdhash:<hash of its code>", the only partition macOS gives code
// that has no Apple team ID, so every new build of the app would have to be allowed again. The
// service is a small executable whose bytes do not change when the app's do: the partition list
// learns its cdhash once, and it answers only a peer signed as it is (the app's identifier and
// certificate). Changing this file's code, keychainitems.m, services/keychain or the compiler
// costs one more prompt.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SNKeychainService
- (void)dataForAccount:(NSString *)account reply:(void (^)(NSData *_Nullable data))reply;
- (void)setData:(NSData *)data forAccount:(NSString *)account reply:(void (^)(BOOL saved))reply;
- (void)deleteAccount:(NSString *)account reply:(void (^)(void))reply;
- (void)accountsWithReply:(void (^)(NSArray<NSString *> *accounts))reply;
@end

/// Generic passwords of service "local.slack-native.session", one per signed-in session, in the
/// data-protection keychain (readable after the first unlock, never leaving this Mac) or, for a
/// build without the entitlement it needs, the login keychain.
@interface SNKeychainItems : NSObject
+ (instancetype)sessionItems;
- (nullable NSData *)dataForAccount:(NSString *)account;
- (BOOL)setData:(NSData *)data forAccount:(NSString *)account;
- (void)deleteAccount:(NSString *)account;
/// Accounts stored, oldest first.
- (NSArray<NSString *> *)accounts;
@end

NS_ASSUME_NONNULL_END
