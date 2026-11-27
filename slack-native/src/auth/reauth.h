// Getting a workspace's token again with the session's cookies, when Slack answers invalid_auth.
#import <Foundation/Foundation.h>

#import "net/session.h"

NS_ASSUME_NONNULL_BEGIN

/// https://app.slack.com/auth?app=client&response_type=json&return_to=/client/<T>&teams=<T>: the
/// web client's own way to turn the d cookie into the team's xoxc token.
NSURL *SNClientAuthURL(NSString *teamID);

/// invalid_auth: fetches a fresh xoxc for `teamID` with the session's cookies, stores it with
/// -setToken:forTeam: and takes Set-Cookie; completion(YES) on the main thread when a token other
/// than the session's came back, else NO (the app then asks to sign in again).
void SNRefreshToken(SNSession *session, NSString *teamID, NSURLSession *urlSession, void (^completion)(BOOL refreshed));

NS_ASSUME_NONNULL_END
