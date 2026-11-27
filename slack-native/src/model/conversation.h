// A conversation (channel, private channel, DM, group DM) from conversations.info/.list,
// client.userBoot's "channels" and "ims", with the unread state of a client.counts entry; and a
// sidebar section from users.channelSections.list.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNConversationKind) {
    SNConversationChannel,
    SNConversationPrivateChannel,
    SNConversationDirect,
    SNConversationGroupDirect,
};

@interface SNConversation : NSObject <NSCopying>
@property (nonatomic, readonly) NSString *conversationID;
@property (nonatomic, readonly) SNConversationKind kind;
/// Channel name without '#'; "mpdm-a--b--c-1" for group DMs; empty for DMs.
@property (nonatomic, readonly) NSString *name;
/// The other person of a DM.
@property (nonatomic, readonly, nullable) NSString *userID;
@property (nonatomic, readonly, nullable) NSString *topic, *purpose;
@property (nonatomic, readonly) NSInteger memberCount;
@property (nonatomic, readonly) BOOL isMember, isArchived, isGeneral, isShared, isExternallyShared;
@property (nonatomic, readonly) NSTimeInterval created;
/// ts of the newest message the user has read; nil when unknown.
@property (nonatomic, readonly, nullable) NSString *lastRead;
/// ts of the newest message; nil when unknown.
@property (nonatomic, readonly, nullable) NSString *latest;
@property (nonatomic, readonly) BOOL hasUnreads;
@property (nonatomic, readonly) NSInteger mentionCount;
/// DMs and group DMs the user closed are kept but not listed.
@property (nonatomic, readonly) BOOL isOpen;
/// Muted in the user's notification prefs: drawn dimmed, never badged or notified.
@property (nonatomic, readonly) BOOL isMuted;
/// The JSON the conversation was decoded from (reconstructed on demand from decoded fields).
@property (nonatomic, readonly) NSDictionary *json;
/// Whether every decoded field matches `other`.
- (BOOL)isEqualToConversation:(SNConversation *)other;

+ (nullable instancetype)conversationWithJSON:(NSDictionary *)json;
/// The conversation with a client.counts entry's last_read, latest, has_unreads and
/// mention_count applied.
- (instancetype)conversationWithCounts:(NSDictionary *)counts;
/// Decoded again from its JSON with `changes` laid over it; NSNull removes a key.
- (instancetype)conversationByMergingJSON:(NSDictionary *)changes;
- (instancetype)conversationWithMuted:(BOOL)muted;
@property (nonatomic, readonly) BOOL isDirect;
@end

typedef NSString *SNSectionType NS_TYPED_EXTENSIBLE_ENUM;
extern SNSectionType const SNSectionStarred;          // "stars"
extern SNSectionType const SNSectionChannels;         // "channels"
extern SNSectionType const SNSectionDirectMessages;   // "direct_messages"
extern SNSectionType const SNSectionApps;             // "recent_apps"
extern SNSectionType const SNSectionSlackConnect;     // "slack_connect"
extern SNSectionType const SNSectionCustom;           // "standard"

@interface SNSection : NSObject <NSCopying>
@property (nonatomic, readonly) NSString *sectionID;
@property (nonatomic, readonly) SNSectionType type;
/// Empty for built-in sections, which Slack names itself.
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly, nullable) NSString *emoji;
@property (nonatomic, readonly, nullable) NSString *nextSectionID;
@property (nonatomic, readonly) NSArray<NSString *> *conversationIDs;
@property (nonatomic, readonly) BOOL isCollapsed;

+ (nullable instancetype)sectionWithJSON:(NSDictionary *)json;
/// Slack chains sections through next_channel_section_id; this follows the chain from the
/// section nothing points to. Sections outside the chain keep their order at the end.
+ (NSArray<SNSection *> *)orderedSections:(NSArray<SNSection *> *)sections;
@end

NS_ASSUME_NONNULL_END
