// Where the session lives between launches: one Keychain item (generic password) per signed-in
// session, its data the session's JSON (cookies, xoxc per team, user agent, version values).
#import <Foundation/Foundation.h>

#import "net/session.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNSecretStore <NSObject>
- (nullable NSData *)dataForAccount:(NSString *)account;
- (BOOL)setData:(NSData *)data forAccount:(NSString *)account;
- (void)deleteAccount:(NSString *)account;
/// Accounts stored, oldest first.
- (NSArray<NSString *> *)accounts;
@optional
/// Data of the oldest stored account in one call (avoids two XPC hops on launch).
- (nullable NSData *)firstAccountData;
@end

/// The session's Keychain items (auth/keychainitems.h) as the app reaches them: through the
/// Keychain service in its bundle, or directly when the build has none (signed ad hoc, which the
/// Keychain asks about after every build anyway).
@interface SNKeychain : NSObject <SNSecretStore>
+ (instancetype)sessionKeychain;
/// Non-nil when the last XPC call failed after retrying (distinct from no item stored).
@property (nonatomic, readonly, nullable) NSError *lastError;
@end

/// In memory, for tests.
@interface SNMemorySecretStore : NSObject <SNSecretStore>
@end

/// Writes a session to the store as it changes: off the main thread (a Keychain write can take
/// tens of milliseconds) and at most once per `delay`, however many cookies rotate meanwhile.
@interface SNSessionSaver : NSObject
- (instancetype)initWithSession:(SNSession *)session store:(id<SNSecretStore>)store delay:(NSTimeInterval)delay;
/// The session changed: written within `delay`.
- (void)sessionChanged;
/// Writes the session now and waits for it (at quit, or before another session replaces it);
/// a change still waiting is written with it.
- (void)flush;
/// Cancels any scheduled write and blocks future writes (before deleting the session at sign-out).
- (void)cancel;
@end

/// The stored session (first account), or nil.
SNSession *_Nullable SNLoadSession(id<SNSecretStore> store);
/// Saves session.data under session.account (deleting an older item of another account).
BOOL SNSaveSession(SNSession *session, id<SNSecretStore> store);

NS_ASSUME_NONNULL_END
