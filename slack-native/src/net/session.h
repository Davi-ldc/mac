// The signed-in session: the cookie jar (d, d-s, lc and whatever Slack sets later), the xoxc token
// of each workspace, the user agent the sign-in used and the web client's version values. One
// session is one jar, shared by every HTTP request and the websocket handshake; every Set-Cookie
// from Slack lands here and `onChange` saves it (to the Keychain), since Slack rotates cookies and
// flags sessions that fork. Safe to use from any thread.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A workspace signed in through the session.
@interface SNSessionTeam : NSObject
@property (nonatomic, readonly) NSString *teamID;
/// xoxc-...
@property (nonatomic, readonly) NSString *token;
/// https://<domain>.slack.com/ (or the org's enterprise host), where API calls go.
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly, nullable) NSString *name, *domain, *userID, *enterpriseID;
+ (nullable instancetype)teamWithJSON:(NSDictionary *)json;
@property (nonatomic, readonly) NSDictionary *json;
@end

/// `teams` with the one of `teamID` moved first (unchanged when none is).
NSArray<SNSessionTeam *> *SNTeamsWithFirst(NSArray<SNSessionTeam *> *teams, NSString *_Nullable teamID);

@interface SNSession : NSObject
/// The first of `teams` is the workspace signed in to, the one the app opens.
- (instancetype)initWithCookies:(NSArray<NSHTTPCookie *> *)cookies
                          teams:(NSArray<SNSessionTeam *> *)teams
                      userAgent:(NSString *)userAgent;
/// From the Keychain item's data; nil when it is not a session.
+ (nullable instancetype)sessionWithData:(NSData *)data;
/// What the Keychain item holds: {cookies, teams (xoxc per team), team (the first), user_agent,
/// version}.
@property (nonatomic, readonly) NSData *data;
/// The Keychain item's account: "<enterprise or team ID>:<user ID>" of the first workspace.
@property (nonatomic, readonly) NSString *account;

@property (nonatomic, readonly) NSArray<NSHTTPCookie *> *cookies;
@property (nonatomic, readonly) NSArray<SNSessionTeam *> *teams;
- (nullable SNSessionTeam *)teamWithID:(NSString *)teamID;
@property (nonatomic, readonly) NSString *userAgent;
/// app.slack.com/client's <html> data-* attributes (version_ts, version_hash, ...), for the
/// web client's _x_ params; empty until fetched.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *version;
/// Called on the main thread after cookies, tokens or version changed.
@property (nonatomic, copy, nullable) void (^onChange)(SNSession *session);

/// A request carrying the session's identity: User-Agent, the jar's cookies for `url` (sent as
/// stored, still URL-encoded) and Origin https://app.slack.com, as the web client sends them.
- (NSMutableURLRequest *)requestWithURL:(NSURL *)url;
/// The Cookie header for `url`, nil when no cookie applies.
- (nullable NSString *)cookieHeaderForURL:(NSURL *)url;
/// Takes every Set-Cookie of a response from a Slack host into the jar (expired ones delete); YES
/// when a cookie came, went or changed value. A new expiry alone is kept without a change: Slack
/// sends Max-Age cookies whose date moves on every answer.
- (BOOL)takeCookiesFromResponse:(NSHTTPURLResponse *)response;
/// A workspace's token changed (refreshed after invalid_auth).
- (void)setToken:(NSString *)token forTeam:(NSString *)teamID;
@end

/// slack.com and its subdomains: the hosts whose cookies the jar takes and that get them back.
BOOL SNIsSlackHost(NSString *_Nullable host);

/// The app's URLSession for `session`: cookies are the session's own, never the system jar's. Its
/// delegate takes Set-Cookie from redirects and gives a redirected request the jar's cookies for
/// its new host (none off Slack's hosts). Invalidate it when done with it.
NSURLSession *SNMakeURLSession(SNSession *session);

NS_ASSUME_NONNULL_END
