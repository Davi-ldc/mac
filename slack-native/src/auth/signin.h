// Signing in: the app signs in itself and owns its session (notes/protocol.txt, SESSION
// BINDING). A WKWebView shows Slack's own sign-in pages; Google SSO, which refuses embedded web
// views, goes through ASWebAuthenticationSession and a slack:// callback like the desktop app.
// Nothing here runs until the user opens the window.
#import <AppKit/AppKit.h>

#import "net/session.h"

NS_ASSUME_NONNULL_BEGIN

/// Safari's user agent for this macOS (WKWebView's default is refused by Slack); the session and
/// every API call reuse it.
NSString *SNSafariUserAgent(void);

@interface SNSignInWindowController : NSWindowController
/// Shows the sign-in window: Slack's sign-in pages in a WKWebView with a new persistent data
/// store of its own and Safari's user agent, holding `previous`'s cookies when a session ended.
/// When the web client is reached it takes the workspaces' tokens and the slack.com cookies,
/// closes, deletes its data store and calls `completion` once with the session (nil when the user
/// closed the window).
- (instancetype)initWithSession:(nullable SNSession *)previous completion:(void (^)(SNSession *_Nullable session))completion;
@end

/// Deletes the sign-in data stores left on disk but `keep`'s (a sign-in quit or crashed before
/// its end, a store that would not go), whose cookies belong in the Keychain only. Asks WebKit
/// only when a store was noted as not deleted.
void SNRemoveSignInDataStores(NSUUID *_Nullable keep);

/// The workspaces in the web client's localStorage.localConfig_v2 (its "teams" object), with
/// their tokens; empty when there are none.
NSArray<SNSessionTeam *> *SNTeamsFromLocalConfig(NSString *_Nullable json);
/// The team of a web client URL (https://app.slack.com/client/T123/C456 -> T123).
NSString *_Nullable SNTeamIDFromClientURL(NSURL *url);
/// The token for `teamID` in app.slack.com/auth?app=client's answer ({teams: {T: {token}}}).
NSString *_Nullable SNTokenFromAuthResponse(NSDictionary *_Nullable response, NSString *teamID);
/// The magic login tokens (z-app-<team>-<key>) in a slack:// callback URL.
NSArray<NSString *> *SNMagicTokensFromCallbackURL(NSURL *url);
/// The workspaces auth.loginMagicBulk signed in, with their tokens.
NSArray<SNSessionTeam *> *SNSessionTeamsFromLoginMagicBulk(NSDictionary *_Nullable response);
/// Exchanges magic tokens with auth.loginMagicBulk for a session: the answer's cookies and the
/// teams' tokens. `completion` runs on the main thread, nil when nothing was signed in.
void SNExchangeMagicTokens(NSArray<NSString *> *tokens, NSString *userAgent, NSURLSession *urlSession,
                           void (^completion)(SNSession *_Nullable session));

NS_ASSUME_NONNULL_END
