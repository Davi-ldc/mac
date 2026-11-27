// A signed-in workspace put together: the session's one URLSession and cookie jar, the API
// client, the cached store, sync, the websocket and notifications. The window shows the store.
// The app-wide hooks (UI language, image fetcher, notification permission) are the app's to set.
#import <Foundation/Foundation.h>

#import "auth/keychain.h"
#import "call/controller.h"
#import "live/live.h"
#import "net/client.h"
#import "notify/notify.h"
#import "store/store.h"
#import "sync/sync.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNAccount : NSObject
/// The session's first workspace; session changes are saved to `secrets` (SNSessionSaver).
/// `urlSession` (SNMakeURLSession) is the account's to invalidate when it stops. `database` nil
/// opens the workspace's cache file.
- (instancetype)initWithSession:(SNSession *)session
                        secrets:(id<SNSecretStore>)secrets
                     urlSession:(NSURLSession *)urlSession
                       database:(nullable SNDatabase *)database;
/// Like -initWithSession:secrets:urlSession:database:, adopting a store preloaded off the main
/// thread during launch.
- (instancetype)initWithSession:(SNSession *)session
                        secrets:(id<SNSecretStore>)secrets
                     urlSession:(NSURLSession *)urlSession
                       database:(nullable SNDatabase *)database
                          store:(nullable SNStore *)store;
@property (nonatomic, readonly) SNSession *session;
@property (nonatomic, readonly) SNClient *client;
@property (nonatomic, readonly) SNStore *store;
@property (nonatomic, readonly) SNSync *sync;
@property (nonatomic, readonly) SNLiveClient *live;
@property (nonatomic, readonly) SNNotifier *notifier;
/// The user's huddle calls (the store's callController); a call left open by a crash is left once
/// boot answers.
@property (nonatomic, readonly) SNCallController *calls;
/// Seconds before booting again after a boot without an answer (default 2), doubling up to two
/// minutes, with jitter.
@property (nonatomic) NSTimeInterval bootRetryDelay;
/// Calls `ready` once the store can be shown: at once from the cache, else after the first boot
/// that answers. Boot is tried again until it answers; the websocket and the rest follow it.
- (void)startWithReady:(void (^)(void))ready;
/// Before quitting: sends the read marks still waiting and leaves the call, then `completion` once
/// they are answered or `timeout` passed, whichever comes first.
- (void)finishWithin:(NSTimeInterval)timeout completion:(void (^)(void))completion;
/// Ends everything: boot retries, the websocket, a huddle call and every API call (the URLSession
/// is invalidated); the session is saved a last time. Before another account replaces this one, and at quit.
- (void)stop;
/// The session ended (its token could not be refreshed): the account has stopped and the stored
/// session stays where it is; the app asks to sign in again.
@property (nonatomic, copy, nullable) void (^onSignedOut)(void);
/// The user signs out: stops live traffic and notifications immediately, forgets the Keychain item
/// and workspace cache at once, leaves the call (within `timeout`), tells Slack (auth.signout),
/// stops the account and calls `completion` once Slack answered or `timeout` passed.
- (void)signOutWithin:(NSTimeInterval)timeout;
- (void)signOutWithin:(NSTimeInterval)timeout completion:(nullable void (^)(void))completion;
@end

NS_ASSUME_NONNULL_END
