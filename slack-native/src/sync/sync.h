// Keeps the store in step with Slack: the boot sequence after launch, client.counts, users the
// store has not met, the prefetch order of the official client, presence subscriptions and the
// gap fill after the websocket comes back.
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNSync : NSObject
- (instancetype)initWithStore:(SNStore *)store api:(id<SNAPI>)api;
@property (nonatomic, readonly) SNStore *store;

/// client.userBoot (incremental when the cache has a previous boot), then counts, prefs,
/// sections, DMs, the users they name, emoji and Do Not Disturb, then prefetch. completion(YES)
/// once userBoot answered and the store has the workspace and the user; NO when it did not
/// answer (the caller boots again later).
- (void)bootWithCompletion:(nullable void (^)(BOOL ok))completion;
/// The websocket said hello: without fast_reconnect, the counts are diffed against the cache and
/// what moved is fetched again (open conversations first), with recent threads.
- (void)connectedWithFastReconnect:(BOOL)fastReconnect;
/// client.counts again soon (several asks within a second are one call).
- (void)refreshCounts;
/// Fetches users by ID through the edge API (batched).
- (void)fetchUsers:(NSSet<NSString *> *)userIDs;

/// Whose presence to follow: the user and the people of open DMs and group DMs (at most 500).
@property (nonatomic, readonly) NSArray<NSString *> *presenceUserIDs;
/// Called when presenceUserIDs changed while connected, to send presence_sub again.
@property (nonatomic, copy, nullable) void (^presenceChanged)(NSArray<NSString *> *userIDs);
/// Conversations to fetch ahead of the user, in the official client's order: DMs, group DMs,
/// channels with mentions, then other unread channels by recent activity.
@property (nonatomic, readonly) NSArray<NSString *> *prefetchOrder;
/// How many of prefetchOrder are fetched after boot and reconnects (default 12).
@property (nonatomic) NSUInteger prefetchLimit;
@end

NS_ASSUME_NONNULL_END
