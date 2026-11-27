// Owns decoding activity.feed items.
#import "model/activity.h"
#import "model/json.h"

@implementation SNActivityEntry

+ (instancetype)entryWithJSON:(NSDictionary *)json {
    NSDictionary *item = SNJSONObject(json, @"item");
    NSString *type = SNJSONString(item, @"type");
    if (!type) return nil;
    SNActivityEntry *entry = [self new];
    entry->_type = type;
    entry->_json = json;
    entry->_isUnread = SNJSONBool(json, @"is_unread");
    NSDictionary *message = SNJSONObject(item, @"message");
    if ([@[ @"at_user", @"at_user_group", @"at_channel", @"at_everyone", @"keyword" ] containsObject:type]) {
        entry->_kind = SNActivityMention;
        entry->_actorUserID = SNJSONString(message, @"author_user_id");
    } else if ([type isEqualToString:@"message_reaction"]) {
        entry->_kind = SNActivityReaction;
        NSDictionary *reaction = SNJSONObject(item, @"reaction");
        entry->_reactionName = SNJSONString(reaction, @"name");
        entry->_actorUserID = SNJSONString(reaction, @"user");
    } else if ([type isEqualToString:@"thread_v2"]) {
        entry->_kind = SNActivityThreadReply;
        NSDictionary *thread = SNJSONObject(SNJSONObject(SNJSONObject(item, @"bundle_info"), @"payload"), @"thread_entry");
        NSString *latest = SNJSONString(thread, @"latest_ts"), *firstUnread = SNJSONString(thread, @"min_unread_ts");
        message = @{@"channel" : SNJSONString(thread, @"channel_id") ?: @"", @"ts" : firstUnread.length ? firstUnread : latest ?: @"",
                    @"thread_ts" : SNJSONString(thread, @"thread_ts") ?: @""};
        entry->_unreadCount = SNJSONInteger(thread, @"unread_msg_count");
    } else {
        return nil;
    }
    entry->_conversationID = SNJSONString(message, @"channel");
    entry->_messageTS = SNJSONString(message, @"ts");
    NSString *threadTS = SNJSONString(message, @"thread_ts");
    entry->_threadTS = threadTS.length ? threadTS : nil;
    entry->_feedTS = SNJSONString(json, @"feed_ts") ?: entry->_messageTS;
    entry->_key = SNJSONString(json, @"key") ?: [@[ type, entry->_conversationID ?: @"", entry->_messageTS ?: @"", entry->_reactionName ?: @"" ] componentsJoinedByString:@"-"];
    return entry->_conversationID.length && entry->_messageTS.length ? entry : nil;
}

@end
