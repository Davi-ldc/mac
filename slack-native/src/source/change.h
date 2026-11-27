// What changed in a source, as one typed value per run-loop turn. A source notes each change as
// it makes it; whatever one turn noted reaches the observers once, right before the turn ends
// (before Core Animation commits the frame), so a burst of events is one change and an observer
// never hears of a change while it is still reacting to the last one: what it changes then
// arrives as the next.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SNChangeKind) {
    // Kinds that name what changed (IDs or keys).
    SNChangeUsers,
    SNChangePresence,
    SNChangeUsergroups,
    SNChangeConversations,
    SNChangeMessages,
    SNChangeMessageKeys,
    SNChangeThreads,
    SNChangeCounts,
    SNChangeTyping,
    SNChangeDrafts,
    SNChangeUploads,
    SNChangeHuddles,
    SNChangeProfiles,
    // Kinds that only say something changed.
    SNChangeLists,
    SNChangeCommands,
    SNChangeEmoji,
    SNChangePreferences,
    SNChangeConnection,
    SNChangeTimeZone,
    SNChangeActivity,
    SNChangeHuddleInvites,
    SNChangeCall,
    SNChangeVIPs,
    SNChangeRecentFiles,
};

/// A set is nil when nothing of its kind changed.
@interface SNChange : NSObject
/// Notes `value` under `kind` (nil for kinds without values, or to say only that the kind changed).
- (void)add:(SNChangeKind)kind value:(nullable NSString *)value;
@property (nonatomic, readonly) BOOL isEmpty;
/// User IDs (profile, status), and bot IDs that arrived.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *users;
/// User IDs whose presence or Do Not Disturb changed.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *presence;
/// User group IDs whose handle changed.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *usergroups;
/// Conversation IDs whose conversation (name, topic, unread state, muted, ...) changed.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *conversations;
/// Conversation IDs whose loaded messages changed (new, edited, deleted, reactions, send state,
/// paging, loading state).
@property (nonatomic, readonly, nullable) NSSet<NSString *> *messages;
/// SNMessageKey()s of the messages behind `messages` that were inserted, changed in place or
/// removed, in history or in a thread.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *messageKeys;
/// SNThreadKey()s of threads whose replies or loading state changed.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *threads;
/// Conversation IDs whose unread or mention counts changed; present (maybe empty) when any badge
/// may have changed, the Threads view's included.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *counts;
/// Conversation IDs and SNThreadKey()s whose typing users changed.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *typing;
/// Conversation IDs and SNThreadKey()s whose draft changed.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *drafts;
/// Conversation IDs and SNThreadKey()s whose attached files changed (added, removed, progress,
/// state).
@property (nonatomic, readonly, nullable) NSSet<NSString *> *uploads;
/// Conversation IDs whose huddle started, changed (people joined or left) or ended.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *huddles;
/// User IDs whose full profile (profileSectionsOfUser:, recentConversationsWithUser:) arrived.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *profiles;
/// The sidebar sections or the DM list.
@property (nonatomic, readonly) BOOL lists;
/// The slash commands (commandsMatching:).
@property (nonatomic, readonly) BOOL commands;
/// Custom emoji (render/emoji.h), the skin tone or frequent emoji.
@property (nonatomic, readonly) BOOL emoji;
@property (nonatomic, readonly) BOOL preferences;
@property (nonatomic, readonly) BOOL connection;
/// The zone every time is shown in: NSTimeZone.defaultTimeZone, which date formatters and
/// NSCalendar.currentCalendar follow. The source keeps it the Mac's while users.prefs
/// set_tz_automatically is on (also as the Mac's changes), else the user's tz.
@property (nonatomic, readonly) BOOL timeZone;
/// The Activity feed or whether it is loading.
@property (nonatomic, readonly) BOOL activity;
@property (nonatomic, readonly) BOOL huddleInvites;
/// The user's call (joined, state, mute, who is speaking, ended).
@property (nonatomic, readonly) BOOL call;
@property (nonatomic, readonly) BOOL vips;
@property (nonatomic, readonly) BOOL recentFiles;
@end

@protocol SNChangeObserver <NSObject>
- (void)sourceChanged:(SNChange *)change;
@end

/// A source's changes on their way: observers in the order they came, held weakly, and what this
/// turn noted so far.
@interface SNChangeQueue : NSObject
- (void)addObserver:(id<SNChangeObserver>)observer;
- (void)note:(SNChangeKind)kind value:(nullable NSString *)value;
@end

/// Delivers every queue's noted changes now rather than at the end of the turn, then what the
/// observers changed meanwhile (tests).
void SNFlushChanges(void);

NS_ASSUME_NONNULL_END
