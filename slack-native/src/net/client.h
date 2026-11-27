// Slack's Web API over HTTP for one workspace of a session, as the web client calls it: POST
// https://<workspace host>/api/<method> with the xoxc token in a form body, the session's cookies
// and user agent, the _x_ query params with the web client's version values, retries of reads on
// network failure (never of writes: one may have happened without an answer), the scheduler's
// rate limits, Set-Cookie written back to the session, and a token refresh on invalid_auth.
#import "net/api.h"
#import "net/scheduler.h"
#import "net/session.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNClient : NSObject <SNAPI>
/// `urlSession` is the app's single session (tests hand one with a URLProtocol stub).
- (instancetype)initWithSession:(SNSession *)session teamID:(NSString *)teamID urlSession:(NSURLSession *)urlSession;
@property (nonatomic, readonly) SNSession *session;
@property (nonatomic, readonly) NSString *teamID;
@property (nonatomic, readonly) NSURLSession *urlSession;
@property (nonatomic, readonly) SNScheduler *scheduler;
/// Delays before each retry of a read that got no answer (default 1, 2, 4 s: three retries).
@property (nonatomic, copy) NSArray<NSNumber *> *retryDelays;
/// Asked for a fresh token after invalid_auth, once for all the calls the old token failed;
/// completion(YES) (a different token is in the session) sends them again.
@property (nonatomic, copy, nullable) void (^refreshToken)(NSString *teamID, void (^completion)(BOOL refreshed));
/// The token could not be refreshed, or a fresh one was refused too: from then on every call
/// fails with SNAPIErrorSignedOut without reaching Slack, and the app asks to sign in again.
/// Called once.
@property (nonatomic, copy, nullable) void (^onSignedOut)(void);
@property (nonatomic, readonly, getter=isSignedOut) BOOL signedOut;
/// Refuses every call and fetch from now on (queued ones fail) and invalidates the URLSession.
- (void)invalidate;

/// The request for a call, with its body and query (exposed for tests).
- (NSURLRequest *)requestForMethod:(NSString *)method params:(NSDictionary<NSString *, NSString *> *)params attempt:(NSInteger)attempt;
/// Bytes behind a URL: with the session's cookies on Slack's own hosts (files need them), plain
/// elsewhere. Main thread completion; nil when it failed, traced as "image:<host>" with the status.
/// For SNSetImageFetcher.
- (void)fetchData:(NSURL *)url completion:(void (^)(NSData *_Nullable data))completion;
/// GETs https://app.slack.com/client and keeps its <html> version attributes in the session.
- (void)refreshWebClientVersion:(nullable void (^)(BOOL ok))completion;
@end

/// The body of an upload: one "file" part between `boundary` lines ("----WebKitFormBoundary" and
/// 16 letters or digits, as browsers make them), written to `body` in chunks so a 1 GB file is
/// never in memory. NO when `file` cannot be read.
BOOL SNWriteMultipartBody(NSURL *file, NSString *name, NSString *mimeType, NSString *boundary, NSURL *body);

/// The data-* attributes of the page's <html> tag, keys with '-' turned to '_' ("version_ts").
NSDictionary<NSString *, NSString *> *SNWebClientVersion(NSString *html);
/// The _x_ params every call carries, for this attempt (0 on the first).
NSDictionary<NSString *, NSString *> *SNWebClientParams(NSDictionary<NSString *, NSString *> *version, NSString *route, NSInteger attempt);

NS_ASSUME_NONNULL_END
