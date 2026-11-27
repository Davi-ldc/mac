// The signed-in workspace's state: in memory for what is shown, in SQLite for the rest, and the
// UI's SNSource. Sync and the live connection feed it what Slack sends (the apply methods); the
// UI's requests go out through `api`. A launch with a cache reads it here before any network.
#import "call/controller.h"
#import "source/source.h"
#import "net/api.h"
#import "store/database.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNStore : NSObject <SNSource>
/// Loads what `database` holds (nil keeps everything in memory, as fixtures do).
- (instancetype)initWithDatabase:(nullable SNDatabase *)database api:(nullable id<SNAPI>)api;
/// `deferred` decodes only what the first frame shows (workspace, self, prefs, sections,
/// conversations, emoji, drafts, thread counts; users read on demand by ID) and skips process
/// globals so it can run off the main thread. Follow with -attachToMainThread before showing the
/// UI, and -finishLoadingCache after the first frame commits.
- (instancetype)initWithDatabase:(nullable SNDatabase *)database api:(nullable id<SNAPI>)api deferred:(BOOL)deferred;
/// Applies process globals (name style, time zone, custom emoji) on the main thread after a
/// deferred off-main init.
- (void)attachToMainThread;
/// Decodes the rest of the cache (remaining users, bots, usergroups, activity, commands).
- (void)finishLoadingCache;
@property (nonatomic, readonly, nullable) SNDatabase *database;
@property (nonatomic, nullable) id<SNAPI> api;
/// The workspace and its user are known (from the cache or from boot): the UI can show.
@property (nonatomic, readonly) BOOL hasState;
@property (nonatomic, readwrite) SNConnectionState connectionState;
/// The Mac's time zone (systemTimeZone at first), which times follow while set_tz_automatically is
/// on; the account sets it as the Mac's changes, tests to move the Mac.
@property (nonatomic) NSTimeZone *macTimeZone;

/// The user's calls (call, joinHuddleInConversation:...); nil keeps the user out of huddles.
@property (nonatomic, nullable) SNCallController *callController;
/// Sends a frame on the websocket (typing); installed by the live connection.
@property (nonatomic, copy, nullable) void (^frameSender)(NSDictionary *frame);
/// Users referenced but not known yet, gathered over a change (reads included); sync fetches
/// them. A user is handed over again only after missingDelay.
@property (nonatomic, copy, nullable) void (^usersMissing)(NSSet<NSString *> *userIDs);
/// An event changed thread read state that only client.counts can recount.
@property (nonatomic, copy, nullable) void (^countsNeeded)(void);
/// A new message from someone else arrived live (for notifications).
@property (nonatomic, copy, nullable) void (^messageArrived)(SNMessage *message, SNConversation *conversation);

/// Seconds a read mark waits before it is sent; later marks replace it. Slack's client waits ~5.
@property (nonatomic) NSTimeInterval markDelay;
/// Conversations and threads kept decoded when a database backs the rest; the conversation and
/// thread last loaded (what the UI shows) are never evicted.
@property (nonatomic) NSUInteger decodedLimit;
/// Top-level messages a conversation keeps on disk once it leaves memory (default 1000); older
/// ones are fetched again when scrolled to.
@property (nonatomic) NSUInteger storedMessageLimit;
/// Seconds before a user or conversation that was asked for and never came is asked for again
/// (default 60, doubling each time).
@property (nonatomic) NSTimeInterval missingDelay;
/// Seconds an invitation rings (0: SNHuddleInviteTimeout).
@property (nonatomic) NSTimeInterval huddleInviteTimeout;
/// Conversations and threads decoded right now, for the memory checks.
@property (nonatomic, readonly) NSUInteger decodedCount;

/// Everything applied inside is one database transaction (its changes reach observers at the end
/// of the turn, as all do).
- (void)performChanges:(void (^)(void))changes;

- (void)applyWorkspace:(NSDictionary *)team;
- (void)applySelfUserID:(NSString *)userID;
/// users.info / users.list / edge users/info members; presence and Do Not Disturb are kept.
- (void)applyUsers:(NSArray<NSDictionary *> *)users;
/// conversations.* / client.userBoot channels and ims; counts and muting are kept.
- (void)applyConversations:(NSArray<NSDictionary *> *)conversations;
/// client.counts' body.
- (void)applyCounts:(NSDictionary *)counts;
/// users.channelSections.list's channel_sections.
- (void)applySections:(NSArray<NSDictionary *> *)sections;
/// users.prefs.get's prefs (muted_channels applies to the conversations).
- (void)applyPreferences:(NSDictionary *)prefs;
/// emoji.list's emoji: name -> URL or "alias:<name>"; also handed to SNSetCustomEmoji.
- (void)applyEmoji:(NSDictionary<NSString *, NSString *> *)emoji;
/// client.dms' newest message of each DM (conversation ID -> message JSON), for
/// latestMessageInConversation: while the DM's history is not decoded.
- (void)applyLatestMessages:(NSDictionary<NSString *, NSDictionary *> *)messages;
/// usergroups.list's usergroups, or a subteam event's subteam; only the handles are kept.
- (void)applyUsergroups:(NSArray<NSDictionary *> *)usergroups;
/// dnd.teamInfo's users: user ID -> dnd status.
- (void)applyDoNotDisturb:(NSDictionary<NSString *, NSDictionary *> *)users;
/// A conversations.history response for the newest page, merged with the cache: overlapping
/// pages replace what they cover, a page that does not reach the cache replaces it.
- (void)applyNewestHistory:(NSDictionary *)response inConversation:(NSString *)conversationID;
/// A conversations.replies response (parent first), replacing the cached thread.
- (void)applyReplies:(NSDictionary *)response thread:(NSString *)threadTS inConversation:(NSString *)conversationID;
/// Fetches the newest page and merges it (gap fill, prefetch).
- (void)refreshConversation:(NSString *)conversationID priority:(SNCallPriority)priority;
/// Fetches a cached thread's replies again (gap fill).
- (void)refreshThread:(NSString *)threadTS inConversation:(NSString *)conversationID;
/// The user if known, without asking for it (userWithID: asks).
- (nullable SNUser *)knownUserWithID:(NSString *)userID;
/// The conversation if known, without asking for it (conversationWithID: asks).
- (nullable SNConversation *)knownConversationWithID:(NSString *)conversationID;
/// The conversation's history is decoded in memory (shown or recently used).
- (BOOL)isDecoded:(NSString *)conversationID;
/// Newest message ts held for the conversation, for comparing with client.counts.
- (nullable NSString *)cachedLatestInConversation:(NSString *)conversationID;
/// Conversations whose history is cached.
@property (nonatomic, readonly) NSArray<NSString *> *cachedConversationIDs;
/// Threads open or recently open, as SNThreadKey()s.
@property (nonatomic, readonly) NSArray<NSString *> *recentThreadKeys;
@end

@interface SNStore (Events)
/// A websocket event.
- (void)applyEvent:(NSDictionary *)event;
@end

@interface SNStore (Writes)
/// Sends the read marks still waiting (before quitting); `completion` once each is answered.
- (void)flushReadMarks:(nullable void (^)(void))completion;
@end

@interface SNStore (VIPs)
/// The VIPs' user IDs: users.priority.list's users.manual_provenance, vip_users_updated's vip_users.
- (void)applyVIPUserIDs:(NSArray *)userIDs;
@end

@interface SNStore (Huddles)
/// After a reconnect Slack did not replay: conversations are asked about their huddles again as
/// they are read.
- (void)forgetHuddleAnswers;
@end

@interface SNStore (Calls)
/// Announces that `callController.call` changed (SNChangeCall): the controller's onChange.
- (void)callChanged;
@end

NS_ASSUME_NONNULL_END
