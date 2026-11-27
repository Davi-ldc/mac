// Spotify Keymaster OAuth 2.0 PKCE (loopback 127.0.0.1) + Client-Token protobuf provider.
#import <Foundation/Foundation.h>

#import "auth/keychain.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SPKeymasterClientID;
extern NSTimeInterval const SPKeymasterRefreshBuffer;
extern NSString *const SPAuthErrorDomain;

typedef NS_ENUM(NSInteger, SPAuthErrorCode) {
    SPAuthErrorNotSignedIn = 1,
    SPAuthErrorAuthorizationURLFailed = 2,
    SPAuthErrorBrowserOpenFailed = 3,
    SPAuthErrorLoopbackFailed = 4,
    SPAuthErrorTimedOut = 5,
    SPAuthErrorStateMismatch = 6,
    SPAuthErrorDenied = 7,
    SPAuthErrorNoCode = 8,
    SPAuthErrorTokenExchangeFailed = 9,
    SPAuthErrorMalformedResponse = 10,
    SPAuthErrorGrantRevoked = 11,
    SPAuthErrorClientTokenChallenged = 12,
};

/// PKCE S256 & Spotify installation device-id helpers.
@interface SPPKCE : NSObject
+ (NSString *)generateCodeVerifier;
+ (NSString *)codeChallengeForVerifier:(NSString *)verifier;
+ (NSString *)generateState;
/// 40 lowercase hex characters (20 random bytes).
+ (NSString *)generateDeviceID;
@end

/// One-shot TCP loopback listener on `http://127.0.0.1:<ephemeral-port>/login` for OAuth redirects.
@interface SPLoopbackServer : NSObject
@property (nonatomic, readonly) uint16_t port;

- (BOOL)startWithError:(NSError *_Nullable *_Nullable)error;
- (void)waitForCallbackWithTimeout:(NSTimeInterval)timeout
                        completion:(void (^)(NSURLComponents *_Nullable callback, NSError *_Nullable error))completion;
- (void)stop;

/// Parses `GET /login?code=...&state=... HTTP/1.1` into URLComponents (exposed for unit tests).
+ (nullable NSURLComponents *)parseHTTPRequestLine:(NSString *)request;
@end

/// Protobuf encoder/decoder for `https://clienttoken.spotify.com/v1/clienttoken`.
@interface SPClientToken : NSObject
@property (nonatomic, readonly, copy) NSString *token;
@property (nonatomic, readonly) NSTimeInterval expiresAt;

- (instancetype)initWithToken:(NSString *)token expiresAt:(NSTimeInterval)expiresAt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (NSData *)encodeRequestWithClientID:(NSString *)clientID deviceID:(NSString *)deviceID;
+ (nullable instancetype)decodeResponseData:(NSData *)data now:(NSTimeInterval)now error:(NSError *_Nullable *_Nullable)error;
@end

/// Coordinates OAuth PKCE sign-in, coalesced token refresh with rotation, and persisted Client-Token caching.
@interface SPAuth : NSObject
@property (nonatomic, readonly, nullable) SPSessionBlob *session;
@property (nonatomic, readonly, nullable) id<SPSecretStore> secretStore;
@property (nonatomic, readonly, copy) NSString *deviceID;

/// Configurable endpoints for offline mock-server testing.
@property (nonatomic, copy) NSURL *authorizeEndpoint;
@property (nonatomic, copy) NSURL *tokenEndpoint;
@property (nonatomic, copy) NSURL *clientTokenEndpoint;

/// Desktop scopes matching Spotify's official client.
+ (NSArray<NSString *> *)desktopScopes;
+ (NSString *)redirectURIForPort:(uint16_t)port;
+ (nullable NSURL *)authorizationURLWithEndpoint:(NSURL *)endpoint
                                            port:(uint16_t)port
                                       challenge:(NSString *)challenge
                                           state:(NSString *)state;
+ (nullable NSString *)authorizationCodeFromCallback:(NSURLComponents *)callback
                                       expectedState:(NSString *)expectedState
                                               error:(NSError *_Nullable *_Nullable)error;
+ (NSData *)formURLEncodedBody:(NSDictionary<NSString *, NSString *> *)params;

- (instancetype)initWithSecretStore:(nullable id<SPSecretStore>)secretStore
                            session:(nullable SPSessionBlob *)initialSession
                         urlSession:(nullable NSURLSession *)urlSession NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithSecretStore:(nullable id<SPSecretStore>)secretStore;
- (instancetype)init NS_UNAVAILABLE;

/// Replaces in-memory session (e.g. after off-main-thread Keychain load).
- (void)adoptSession:(nullable SPSessionBlob *)session;

/// Runs browser OAuth PKCE flow on loopback 127.0.0.1.
/// Pass `persist:NO` for ephemeral tools (`fairplay_probe --oauth-login`) so nothing is written to Keychain.
- (void)authorizeWithBrowserOpener:(nullable BOOL (^)(NSURL *url))opener
                           persist:(BOOL)persist
                           timeout:(NSTimeInterval)timeout
                        completion:(void (^)(SPSessionBlob *_Nullable blob, NSError *_Nullable error))completion;

/// Cancels any active loopback OAuth flow, closing and unbinding its listener socket immediately.
- (void)cancelAuthorization;
@property (nonatomic, readonly) BOOL isAuthorizing;

/// Returns a valid Bearer access token, refreshing & rotating the refresh token automatically when within 5 min of expiry.
- (void)accessTokenWithCompletion:(void (^)(NSString *_Nullable accessToken, NSError *_Nullable error))completion;

/// Returns a valid Client-Token, fetching via protobuf when absent or expired and persisting inside the single session blob.
- (void)clientTokenWithCompletion:(void (^)(NSString *_Nullable clientToken, NSError *_Nullable error))completion;

/// Invalidates cached client token ONLY if it still equals `rejectedToken` (prevents concurrent 401s dropping a fresh replacement).
- (void)invalidateClientTokenIfMatching:(NSString *)rejectedToken;

/// Clears in-memory session and removes stored credentials if `secretStore` is configured.
- (void)signOut;
@end

NS_ASSUME_NONNULL_END
