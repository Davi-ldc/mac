// The store's parts shared by its files (store.m: state and history; writes.m: the UI's
// requests; events.m: websocket events; lookup.m: autocomplete, emoji and search).
//
// SNSource is implemented across those files, but clang checks a protocol against the primary
// @implementation alone; store.m and the category files silence that check, and
// tests/store proves at run time that every SNSource method is implemented.
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

/// The newest page size, as Slack's client.
static const NSInteger SNHistoryPage = 42;
/// The database keys of the expandables: "expandable:<item key>".
static NSString *const SNExpandablePrefix = @"expandable:";

/// A conversation's history or a thread as decoded in memory: a contiguous run of messages,
/// oldest first, the newest end of what the database holds. The run changes only through the
/// methods below, which keep its messages findable by ts and identifier without a scan.
@interface SNHistory : NSObject
@property (nonatomic, readonly) NSArray<SNMessage *> *messages;
/// Sends in the run waiting for Slack's answer.
@property (nonatomic, readonly) NSUInteger pendingCount;
- (nullable SNMessage *)messageWithTS:(NSString *)ts;
- (nullable SNMessage *)messageWithIdentifier:(NSString *)identifier;
/// Inserts `message` where its ts sorts it, in place of the copy held with its identifier (a
/// pending send turning into Slack's) or its ts; returns that copy.
- (nullable SNMessage *)put:(SNMessage *)message;
/// `held`, a message of the run, becomes `message`, or leaves the run (nil).
- (void)replace:(SNMessage *)held with:(nullable SNMessage *)message;
/// The whole run, in any order.
- (void)setMessages:(NSArray<SNMessage *> *)messages;
/// Messages older than the run, oldest first, before it.
- (void)insertOlder:(NSArray<SNMessage *> *)messages;
/// The database holds older messages of the same run.
@property (nonatomic) BOOL olderOnDisk;
/// Slack holds messages older than the run.
@property (nonatomic) BOOL olderOnServer;
/// The run stops before the conversation's newest message.
@property (nonatomic) BOOL newerOnServer;
/// Fetched from Slack in this session (the cache may be stale until then).
@property (nonatomic) BOOL fresh;
@property (nonatomic) NSInteger loads;
@end

@interface SNStore ()
@property (nonatomic) NSString *meID;
@property (nonatomic) NSMutableDictionary<NSString *, SNUser *> *users;
/// SNUser.handle -> user ID, kept with `users` (holdUser:).
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *userIDsByHandle;
/// Presence (SNPresence) by user ID, and the users in Do Not Disturb: Slack streams both, so they
/// live in memory only and a change touches nothing else.
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *presences;
@property (nonatomic) NSMutableSet<NSString *> *doNotDisturbIDs;
@property (nonatomic) NSMutableDictionary<NSString *, SNConversation *> *conversationsByID;
/// users.channelSections.list's sections as Slack sent them (with the websocket's updates), and
/// decoded in display order; saveSections keeps the second with the first.
@property (nonatomic) NSMutableArray<NSDictionary *> *sectionJSON;
@property (nonatomic) NSArray<SNSection *> *sectionList;
/// Open DMs and group DMs, newest activity first, and the ts each is placed by;
/// placeDirectMessage: keeps them.
@property (nonatomic) NSMutableArray<SNConversation *> *dmList;
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *dmOrder;
/// DMs of the list that do not say who is in them (store.m's LacksPeople), asked of Slack again
/// whenever the list is read.
@property (nonatomic) NSMutableSet<NSString *> *peoplelessDMs;
/// Channels the user is in, archived ones left out, by name; setConversation: keeps it.
@property (nonatomic) NSMutableArray<SNConversation *> *channelList;
@property (nonatomic) NSDictionary<NSString *, id> *prefs;
@property (nonatomic) NSDictionary<NSString *, NSString *> *emojiList;
/// User group ID -> handle.
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *usergroupHandles;
@property (nonatomic) NSDictionary *threadCounts;
/// Decoded histories by conversation ID and threads by SNThreadKey().
@property (nonatomic) NSMutableDictionary<NSString *, SNHistory *> *histories, *threads;
/// History and thread keys, most recently used first.
@property (nonatomic) NSMutableArray<NSString *> *recent;
/// Typing users by conversation ID or thread key: user ID -> @[when they started, when it expires].
@property (nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSArray<NSDate *> *> *> *typing;
@property (nonatomic) NSMutableDictionary<NSString *, NSDate *> *typingSent;
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *drafts;
/// client_msg_id of sends in flight.
@property (nonatomic) NSMutableSet<NSString *> *sending;
/// Read marks waiting: conversation ID or thread key -> ts.
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *marks;
/// Conversations whose last_read Slack gave in this session (counts, events, conversation
/// answers, the user's own posts); the cache's may be behind.
@property (nonatomic) NSMutableSet<NSString *> *readKnown;
@property (nonatomic) NSMutableSet<NSString *> *missing;
/// Users asked for that have not arrived: user ID -> @[times asked, when they may be asked again].
@property (nonatomic) NSMutableDictionary<NSString *, NSArray *> *missingAsked;
/// Unknown conversations asked of Slack, as missingAsked (distantFuture while the call is out).
@property (nonatomic) NSMutableDictionary<NSString *, NSArray *> *conversationsAsked;
/// Bots by ID (bots.info), and the ones asked of Slack, as conversationsAsked.
@property (nonatomic) NSMutableDictionary<NSString *, SNBot *> *bots;
@property (nonatomic) NSMutableDictionary<NSString *, NSArray *> *botsAsked;
/// Independent deferred-load flags so reading one small kv entry never decodes the users table.
@property (nonatomic) BOOL usersCachePending, botsCachePending, usergroupsCachePending, activityCachePending, commandsCachePending;
/// Negative cache for handles already checked against SQLite while usersCachePending is YES.
@property (nonatomic) NSMutableSet<NSString *> *missingHandles;
/// Background disk writes per conversation since the last trimStored:.
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *storedWritesSinceTrim;
/// Insertion order for bounded session caches.
@property (nonatomic) NSMutableArray<NSString *> *activityMessageOrder, *savedChangeOrder, *profileOrder;
/// Loads a single user by handle from SQLite while usersCachePending is YES.
- (nullable SNUser *)loadUserByHandleFromDB:(NSString *)handle;
/// Conversations Slack said do not exist or are hidden from the user.
@property (nonatomic) NSMutableSet<NSString *> *unavailableConversations;
/// What the UI shows (the conversation and thread it last loaded): never evicted.
@property (nonatomic, copy, nullable) NSString *shownConversation, *shownThread;
/// Queries already sent to edge users/search.
@property (nonatomic) NSMutableSet<NSString *> *remoteUserQueries;
/// The newest message outside threads of conversations whose history is not decoded, by
/// conversation ID: read from the database or Slack once, then kept by the messages put and
/// updated there. A decoded history answers instead, and its entry goes when it leaves memory.
@property (nonatomic) NSMutableDictionary<NSString *, SNMessage *> *latestMessages;
/// activity.feed's items as Slack sent them (with the websocket's updates), and decoded.
@property (nonatomic) NSArray<NSDictionary *> *activityJSON;
@property (nonatomic) NSArray<SNActivityEntry *> *activity;
/// The feed request in flight (0: none) and the next page's cursor ("" or nil: no more).
@property (nonatomic) NSInteger activityRequest;
@property (nonatomic, copy, nullable) NSString *activityCursor;
@property (nonatomic) BOOL activityUnreads, activityVIP;
/// Messages of entries that Slack sent through messages.list, by "<conversation ID>/<ts>"; the
/// keys asked in this session, and those waiting for the next call.
@property (nonatomic) NSMutableDictionary<NSString *, SNMessage *> *activityMessages;
@property (nonatomic) NSMutableSet<NSString *> *activityMessagesAsked, *activityMessagesWanted;
/// Messages saved for later (@YES) or taken out of Later (@NO) from this device in this session,
/// by "<conversation ID>/<ts>"; they win over the message's own "saved" state.
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *savedChanges;
/// Conversations whose newest message was asked of Slack.
@property (nonatomic) NSMutableSet<NSString *> *latestRequested;
/// Attached files by upload ID, and the IDs on each composer (conversation ID or thread key).
@property (nonatomic) NSMutableDictionary<NSString *, SNUpload *> *uploads;
@property (nonatomic) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *attachedUploads;
/// Upload IDs waiting for their turn; the one on its way (until Slack made the file), its upload
/// key (conversation or thread) and what stops its transfer.
@property (nonatomic) NSMutableArray<NSString *> *uploadQueue;
@property (nonatomic, copy, nullable) NSString *activeUpload;
@property (nonatomic, copy, nullable) dispatch_block_t cancelTransfer;
/// Uploads already sent again once after failing (Slack's queue retries a failure by itself once).
@property (nonatomic) NSMutableSet<NSString *> *retriedUploads;
/// Messages with files waiting for their uploads before files.share, by client_msg_id.
@property (nonatomic) NSMutableDictionary<NSString *, SNMessage *> *waitingShares;
/// The user's collapse or expand choice per message item (Slack's "expandables"), by its key.
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *expandables;
/// client.appCommands' commands, and whether they were asked in this session.
@property (nonatomic) NSArray<SNCommand *> *commands;
@property (nonatomic) BOOL commandsAsked;
/// Huddles, invitations and their timers (store/huddles.m), made at first use.
@property (nonatomic, nullable) id huddleBook;
/// The VIPs (store/vips.m), read from the cache at first use.
@property (nonatomic, copy, nullable) NSArray<NSString *> *vipIDs;
/// The Files tab's recently viewed files, read from the cache on first use.
@property (nonatomic, copy, nullable) NSArray<SNFile *> *recentFileList;
/// Full profiles by user ID (store/profiles.m): {sections, conversations, more}, made at first use.
@property (nonatomic, nullable) NSMutableDictionary<NSString *, NSMutableDictionary *> *profiles;

/// Notes a change for the observers (source/change.h): they hear of it at the end of the turn.
- (void)changed:(SNChangeKind)kind value:(nullable NSString *)value;
/// Memory, else the database (decoded and kept); nil when neither holds it.
- (nullable SNHistory *)historyOf:(NSString *)conversationID;
- (nullable SNHistory *)threadOf:(NSString *)threadKey;
/// Marks the key as just used and evicts the least recently used beyond decodedLimit.
- (void)touch:(NSString *)key;
/// Keeps a conversation's cache on disk within storedMessageLimit (for one not in memory).
- (void)trimStored:(NSString *)conversationID;
/// Puts the message where it belongs: the history (unless a plain reply) and its thread, when
/// cached. Matches an existing copy by identifier (a pending send) or ts. Runs not in memory are
/// written on disk without decoding them.
- (void)putMessage:(SNMessage *)message;
/// Applies `transform` to every copy of the message (history, thread, database); nil removes.
/// Decodes nothing.
- (void)updateMessage:(NSString *)ts inConversation:(NSString *)conversationID transform:(SNMessage *_Nullable (^)(SNMessage *message))transform;
/// The same for a message that may be a reply cached only under its thread `threadTS`.
- (void)updateMessage:(NSString *)ts
       inConversation:(NSString *)conversationID
             threadTS:(nullable NSString *)threadTS
            transform:(SNMessage *_Nullable (^)(SNMessage *message))transform;
/// A copy of the message from memory or the database's row, without decoding a run.
- (nullable SNMessage *)messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID;
/// The same, looking under the thread `threadTS` too.
- (nullable SNMessage *)messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
- (void)setConversation:(SNConversation *)conversation;
/// Moves the conversation where it now belongs in the DM list (out of it unless an open DM);
/// announces the lists when that moved anything.
- (void)placeDirectMessage:(NSString *)conversationID;
/// Saves sectionJSON after a change, decodes it into sectionList and announces the lists.
- (void)saveSections;
- (void)setUser:(SNUser *)user;
- (void)setPresence:(SNPresence)presence ofUser:(NSString *)userID;
/// client.counts' "threads" (the Threads view's badge), saved and announced when it differs.
- (void)setThreadCountsJSON:(NSDictionary *)threads;
- (void)savePreferences;
/// Notes users the UI will ask for that are not known.
- (void)noteUser:(nullable NSString *)userID;
- (void)request:(NSString *)method params:(NSDictionary<NSString *, NSString *> *)params priority:(SNCallPriority)priority completion:(nullable SNAPICompletion)completion;
@end

@interface SNStore (ActivityInternal)
/// The feed and the unreads switch from the database.
- (void)loadActivityCache;
/// An `activity` websocket event (activity_updated, activity_deleted, activity_invalidated).
- (void)applyActivityEvent:(NSDictionary *)event;
@end

@interface SNStore (WritesInternal)
/// Slack's copy of a message sent from here replaces the pending one (matched by identifier).
- (void)confirm:(SNMessage *)sent;
/// Sends a pending message: chat.postMessage, or files.share for one with files.
- (void)post:(SNMessage *)message;
/// The copy of a message sent from here that memory holds now, matched by client_msg_id.
- (nullable SNMessage *)heldSend:(SNMessage *)message;
@end

@interface SNStore (UploadsInternal)
/// Shares a message's files once its uploads are on Slack (now, or when the last one is).
- (void)shareWhenUploaded:(SNMessage *)message;
/// file_created: Slack made a file this client uploaded.
- (void)applyFileCreated:(nullable NSString *)fileID;
@end

@interface SNStore (CommandsInternal)
/// The commands from the database.
- (void)loadCommandsCache;
/// commands_changed: the list is asked again.
- (void)applyCommandsChanged;
/// A message only the user sees (is_ephemeral): shown while its conversation or thread is in
/// memory, never written to the database.
- (void)putEphemeral:(SNMessage *)message;
@end

@interface SNStore (EventsInternal)
/// The parent of `reply` counts it in its reply bar, once.
- (void)countReply:(SNMessage *)reply;
@end

@interface SNStore (HuddlesInternal)
/// sh_room_join/leave/update, huddle_invite, huddle_invite_cancel and call_block_updated.
- (void)applyHuddleEvent:(NSDictionary *)event type:(NSString *)type;
/// A message event (new or message_changed) whose message may carry a room.
- (void)applyRoomInMessageEvent:(NSDictionary *)event;
/// The rooms a page of the conversation's history fetched from Slack carries; only the page's
/// newest huddle_thread, and only when none newer was seen, can name the conversation's huddle.
- (void)noteRoomsIn:(NSArray<SNMessage *> *)page ofConversation:(NSString *)conversationID;
/// Follows when a user's profile says their huddle state expires.
- (void)watchHuddleStateOf:(SNUser *)user;
@end

/// The local ts for a message sent now: after every ts the conversation holds.
NSString *SNLocalTS(NSString *_Nullable after);
NSString *SNJSONText(id object);
/// Whether a dnd.info / dnd_updated status silences the user now.
BOOL SNDoNotDisturbActive(NSDictionary *_Nullable status);
/// The message with `userID`'s reaction `name` added or taken away (no change when already so).
SNMessage *SNMessageReacting(SNMessage *message, NSString *name, NSString *userID, BOOL add);

NS_ASSUME_NONNULL_END
