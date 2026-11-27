// An entry of the Activity tab: one of activity.feed's "items", or the "entry" of an `activity`
// websocket event (subtype activity_updated), which has the same shape. The method is the web
// client's own and undocumented; the fields read here are the ones its normalizer reads:
//   {key, feed_ts, is_unread, item: {type, message: {channel, ts, thread_ts?, author_user_id?},
//    reaction: {user, name}, bundle_info: {payload: {thread_entry: {channel_id, thread_ts,
//    latest_ts, min_unread_ts?, unread_msg_count}}}}}
// The message itself is not in the item: the client asks messages.list for it.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNActivityKind) {
    /// at_user, at_user_group, at_channel, at_everyone, keyword.
    SNActivityMention,
    /// message_reaction: someone reacted to the user's message.
    SNActivityReaction,
    /// thread_v2: replies in a thread the user follows.
    SNActivityThreadReply,
};

@interface SNActivityEntry : NSObject
/// nil for kinds this client does not show and for items missing what they need.
+ (nullable instancetype)entryWithJSON:(NSDictionary *)json;
/// Slack's key for the item: an update or a deletion names it.
@property (nonatomic, readonly) NSString *key;
@property (nonatomic, readonly) SNActivityKind kind;
/// Slack's item type ("at_user", "message_reaction", "thread_v2").
@property (nonatomic, readonly) NSString *type;
@property (nonatomic, readonly) NSString *conversationID;
/// The message mentioned or reacted to; for a thread its first unread reply, else its latest.
@property (nonatomic, readonly) NSString *messageTS;
@property (nonatomic, readonly, nullable) NSString *threadTS;
/// Who did it when the item says (the author of a mention, the reacting user); else the
/// message's author.
@property (nonatomic, readonly, nullable) NSString *actorUserID;
@property (nonatomic, readonly, nullable) NSString *reactionName;
@property (nonatomic, readonly) BOOL isUnread;
/// A thread's unread replies.
@property (nonatomic, readonly) NSInteger unreadCount;
/// When it happened, which orders the feed (newest first).
@property (nonatomic, readonly) NSString *feedTS;
@property (nonatomic, readonly) NSDictionary *json;
@end

NS_ASSUME_NONNULL_END
