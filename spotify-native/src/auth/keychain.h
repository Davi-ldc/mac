// Single-item Keychain session storage (one read off the main thread) + pluggable in-memory store for tests.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SPSecretStore <NSObject>
- (nullable NSData *)dataForAccount:(NSString *)account;
- (BOOL)setData:(NSData *)data forAccount:(NSString *)account;
- (void)deleteAccount:(NSString *)account;
- (NSArray<NSString *> *)accounts;
@optional
/// Reads the first stored session blob in a single Keychain call.
- (nullable NSData *)firstAccountData;
@end

/// Optional low-level Keychain query hook for unit tests without touching the user's login Keychain.
typedef OSStatus (^SPSecItemCopyMatchingHook)(CFDictionaryRef query, CFTypeRef _Nullable *_Nullable result);

/// Production Keychain store under service `local.spotify-native.session`.
@interface SPKeychain : NSObject <SPSecretStore>
+ (instancetype)sessionKeychain;
- (instancetype)initWithService:(NSString *)service
                      fileBased:(BOOL)fileBased
                   copyMatching:(nullable SPSecItemCopyMatchingHook)copyMatching;
@end

/// Thread-safe in-memory secret store for headless tests and ephemeral probes.
@interface SPMemorySecretStore : NSObject <SPSecretStore>
@property (nonatomic, readonly) NSUInteger readCount;
@property (nonatomic, readonly) NSUInteger writeCount;
@end

/// Single JSON session blob persisted in one Keychain item: OAuth tokens + Client-Token + device ID + optional Soloist key.
@interface SPSessionBlob : NSObject <NSCopying>
@property (nonatomic, readonly, copy, nullable) NSString *accessToken;
@property (nonatomic, readonly, copy, nullable) NSString *refreshToken;
@property (nonatomic, readonly) NSTimeInterval accessTokenExpiresAt;
@property (nonatomic, readonly, copy) NSString *username;
@property (nonatomic, readonly, copy) NSString *deviceID;
@property (nonatomic, readonly, copy, nullable) NSString *clientToken;
@property (nonatomic, readonly) NSTimeInterval clientTokenExpiresAt;
@property (nonatomic, readonly, copy, nullable) NSString *soloistKey;

@property (nonatomic, readonly, copy) NSString *accountKey;

- (instancetype)initWithAccessToken:(nullable NSString *)accessToken
                       refreshToken:(nullable NSString *)refreshToken
               accessTokenExpiresAt:(NSTimeInterval)accessTokenExpiresAt
                           username:(nullable NSString *)username
                           deviceID:(NSString *)deviceID
                        clientToken:(nullable NSString *)clientToken
               clientTokenExpiresAt:(NSTimeInterval)clientTokenExpiresAt
                         soloistKey:(nullable NSString *)soloistKey NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (nullable instancetype)blobFromJSONData:(NSData *)data;
- (nullable NSData *)toJSONData;

- (instancetype)withAccessToken:(NSString *)accessToken
                   refreshToken:(NSString *)refreshToken
                      expiresAt:(NSTimeInterval)expiresAt
                       username:(nullable NSString *)username;
- (instancetype)withClientToken:(nullable NSString *)clientToken expiresAt:(NSTimeInterval)expiresAt;
- (instancetype)withSoloistKey:(nullable NSString *)soloistKey;
@end

/// Synchronous helpers (call off the main thread).
SPSessionBlob *_Nullable SPLoadSessionBlob(id<SPSecretStore> store);
BOOL SPSaveSessionBlob(SPSessionBlob *blob, id<SPSecretStore> store);
void SPDeleteAllSessions(id<SPSecretStore> store);

/// Single off-main-thread Keychain read/write/delete helpers so startup and sign-out never block the main thread.
void SPLoadSessionBlobAsync(id<SPSecretStore> store, void (^completion)(SPSessionBlob *_Nullable blob));
void SPSaveSessionBlobAsync(SPSessionBlob *blob, id<SPSecretStore> store, void (^_Nullable completion)(BOOL saved));
void SPDeleteAllSessionsAsync(id<SPSecretStore> store, void (^_Nullable completion)(void));

NS_ASSUME_NONNULL_END
