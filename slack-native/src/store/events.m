// Owns applying websocket events: messages and their changes, reactions, read marks, typing,
// presence, users, conversations, sections, emoji and prefs; huddles go on to store/huddles.m.
// Event shapes per notes/protocol.txt; unknown events are ignored.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

/// How long a typing indicator lasts without another typing event (Slack's client: ~6 s).
static const NSTimeInterval SNTypingTimeout = 6;

@implementation SNStore (Events)

- (void)applyEvent:(NSDictionary *)event {
    NSString *type = SNJSONString(event, @"type");
    if (!type) return;
    [self performChanges:^{
        if ([type isEqualToString:@"message"]) {
            [self applyMessageEvent:event];
            [self applyRoomInMessageEvent:event];
        }
        else if ([type isEqualToString:@"reaction_added"] || [type isEqualToString:@"reaction_removed"]) [self applyReaction:event added:[type isEqualToString:@"reaction_added"]];
        else if ([type hasSuffix:@"_marked"] && ![type isEqualToString:@"thread_marked"]) [self applyMarked:event];
        else if ([type isEqualToString:@"thread_marked"] || [type hasPrefix:@"thread_subscribed"] || [type hasPrefix:@"thread_unsubscribed"]) {
            if (self.countsNeeded) self.countsNeeded();
        } else if ([type isEqualToString:@"user_typing"]) [self applyTyping:event];
        else if ([type isEqualToString:@"presence_change"]) [self applyPresence:event];
        else if ([@[ @"user_change", @"user_profile_changed", @"user_status_changed", @"team_join" ] containsObject:type]) {
            NSDictionary *user = SNJSONObject(event, @"user");
            if (user) [self applyUsers:@[ user ]];
        } else if ([type hasPrefix:@"dnd_updated"]) {
            NSString *userID = SNJSONString(event, @"user");
            NSDictionary *status = SNJSONObject(event, @"dnd_status");
            if (userID && status) [self applyDoNotDisturb:@{userID : status}];
        } else if ([@[ @"channel_joined", @"group_joined", @"channel_created", @"im_created", @"mpim_joined" ] containsObject:type]) {
            NSDictionary *channel = SNJSONObject(event, @"channel");
            if (channel) [self applyConversations:@[ SNJSONMerge(channel, @{@"is_member" : @YES}) ]];
        } else if ([@[ @"channel_left", @"group_left" ] containsObject:type]) [self mergeConversation:event changes:@{@"is_member" : @NO}];
        else if ([@[ @"channel_archive", @"group_archive" ] containsObject:type]) [self mergeConversation:event changes:@{@"is_archived" : @YES}];
        else if ([@[ @"channel_unarchive", @"group_unarchive" ] containsObject:type]) [self mergeConversation:event changes:@{@"is_archived" : @NO}];
        else if ([@[ @"channel_rename", @"group_rename" ] containsObject:type]) {
            NSDictionary *channel = SNJSONObject(event, @"channel");
            NSString *name = SNJSONString(channel, @"name");
            if (name) [self mergeConversation:channel changes:@{@"name" : name}];
        } else if ([@[ @"im_open", @"mpim_open", @"group_open" ] containsObject:type]) [self mergeConversation:event changes:@{@"is_open" : @YES}];
        else if ([@[ @"im_close", @"mpim_close", @"group_close" ] containsObject:type]) [self mergeConversation:event changes:@{@"is_open" : @NO}];
        else if ([type isEqualToString:@"member_joined_channel"] || [type isEqualToString:@"member_left_channel"]) [self applyMembership:event joined:[type isEqualToString:@"member_joined_channel"]];
        else if ([type isEqualToString:@"emoji_changed"]) [self applyEmojiChange:event];
        else if ([type isEqualToString:@"subteam_created"] || [type isEqualToString:@"subteam_updated"]) {
            NSDictionary *group = SNJSONObject(event, @"subteam");
            if (group) [self applyUsergroups:@[ group ]];
        }
        else if ([type isEqualToString:@"vip_users_updated"]) [self applyVIPUserIDs:SNJSONArray(event, @"vip_users") ?: @[]];
        else if ([type isEqualToString:@"pref_change"]) {
            NSString *name = SNJSONString(event, @"name");
            id value = event[@"value"];
            if (name && value) [self applyPreferences:@{name : value}];
        } else if ([type hasPrefix:@"channel_section"] || [type hasPrefix:@"channel_sections"]) [self applySectionEvent:event type:type];
        else if ([type isEqualToString:@"file_deleted"]) [self applyFileDeleted:SNJSONString(event, @"file_id")];
        else if ([type isEqualToString:@"file_created"]) [self applyFileCreated:SNJSONString(event, @"file_id")];
        else if ([type isEqualToString:@"commands_changed"]) [self applyCommandsChanged];
        else if ([type isEqualToString:@"activity"]) [self applyActivityEvent:event];
        else if ([type hasPrefix:@"sh_room_"] || [type hasPrefix:@"huddle_invite"] || [type isEqualToString:@"call_block_updated"]) [self applyHuddleEvent:event type:type];
    }];
}

#pragma mark Messages

- (void)applyMessageEvent:(NSDictionary *)event {
    NSString *subtype = SNJSONString(event, @"subtype");
    NSString *conversationID = SNJSONString(event, @"channel");
    if (!conversationID) return;
    if ([subtype isEqualToString:@"message_changed"] || [subtype isEqualToString:@"message_replied"]) {
        NSDictionary *json = SNJSONObject(event, @"message");
        SNMessage *message = json ? [SNMessage messageWithJSON:json conversationID:conversationID] : nil;
        if (!message) return;
        // The event's message is the whole message as it is now, except that it may leave out
        // reactions and the reply bar's fields: those are kept, but what it says is replaced (an
        // edit that drops the blocks, an unfurl taken away, a parent deleted into a tombstone).
        // One without "text" is not a whole message, and only adds what it has.
        NSMutableDictionary *changes = [json mutableCopy];
        if ([subtype isEqualToString:@"message_changed"] && json[@"text"])
            for (NSString *key in @[ @"text", @"blocks", @"attachments", @"files", @"edited" ])
                if (!changes[key]) changes[key] = NSNull.null;
        [self updateMessage:message.ts inConversation:conversationID threadTS:message.threadTS transform:^SNMessage *(SNMessage *held) {
            return [held messageByMergingJSON:changes];
        }];
        return;
    }
    if ([subtype isEqualToString:@"message_deleted"]) {
        NSString *ts = SNJSONString(event, @"deleted_ts");
        NSString *threadTS = SNJSONString(SNJSONObject(event, @"previous_message"), @"thread_ts");
        if (!ts) return;
        [self updateMessage:ts inConversation:conversationID threadTS:threadTS transform:^SNMessage *(SNMessage *held) { return nil; }];
        if (threadTS && ![threadTS isEqualToString:ts]) [self recountReplies:SNThreadKey(conversationID, threadTS)];
        return;
    }
    NSMutableDictionary *json = [event mutableCopy];
    [json removeObjectsForKeys:@[ @"channel", @"event_ts", @"source_team", @"suppress_notification", @"channel_type" ]];
    SNMessage *message = [SNMessage messageWithJSON:json conversationID:conversationID];
    if (!message) return;
    if (message.isEphemeral) return [self putEphemeral:message];
    NSString *typingKey = message.isReply ? SNThreadKey(conversationID, message.threadTS) : conversationID;
    if (message.userID) [self stopTyping:message.userID key:typingKey];
    BOOL mine = [message.userID isEqualToString:self.meID];
    if (mine && message.clientMessageID) {
        [self confirmEcho:message];
        return;
    }
    [self putMessage:message];
    if (message.threadTS && !message.isThreadParent) [self countReply:message];
    SNConversation *conversation = self.conversationsByID[conversationID];
    if (!conversation) return;
    if (message.isReply) {
        if (!mine && self.messageArrived) self.messageArrived(message, conversation);
        return;
    }
    NSMutableDictionary *changes = [NSMutableDictionary new];
    if (!conversation.latest || SNCompareTS(conversation.latest, message.ts) == NSOrderedAscending) changes[@"latest"] = message.ts;
    // Slack's sidebar leaves these out of unreads, and so out of notifications.
    static NSSet *ignored;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ignored = [NSSet setWithArray:@[ @"channel_canvas_updated_unread_ignore", @"tabbed_canvas_updated_unread_ignore", @"channel_join", @"channel_leave", @"group_join",
                                         @"group_leave", @"huddle_message", @"huddle_thread", @"mpim_notify_disabled", @"app_conversation_join", @"app_conversation_leave",
                                         @"app_conversation_created", @"channel_tab_added_unread_ignore", @"folder_item_added_unread_ignore" ]];
    });
    BOOL counted = ![ignored containsObject:subtype ?: @""];
    BOOL unread = counted && (!conversation.lastRead || SNCompareTS(conversation.lastRead, message.ts) == NSOrderedAscending);
    if (mine) {
        [changes addEntriesFromDictionary:@{@"last_read" : message.ts, @"has_unreads" : @NO, @"mention_count" : @0}];
    } else if (unread) {
        changes[@"has_unreads"] = @YES;
        // A DM's badge counts every unread message; a channel's only mentions of the user.
        BOOL mention = conversation.isDirect || (self.meID && [message mentionsUser:self.meID]) || message.mentionsEveryone;
        if (mention) changes[@"mention_count"] = @(conversation.mentionCount + 1);
    }
    if (!conversation.isOpen && conversation.isDirect) changes[@"is_open"] = @YES;
    if (changes.count) [self setConversation:[conversation conversationByMergingJSON:changes]];
    if (!mine && counted && self.messageArrived) self.messageArrived(message, self.conversationsByID[conversationID]);
}

/// The websocket's copy of the user's own message, possibly before chat.postMessage answered;
/// from another device when nothing here holds it.
- (void)confirmEcho:(SNMessage *)message {
    NSString *conversationID = message.conversationID;
    // A run waiting for a send's answer is never evicted, so memory is where it would be.
    BOOL held = [self.histories[conversationID] messageWithIdentifier:message.identifier] ||
                (message.threadTS && [self.threads[SNThreadKey(conversationID, message.threadTS)] messageWithIdentifier:message.identifier]);
    if (!held && message.threadTS && !message.isThreadParent) [self countReply:message];
    [self confirm:message];
}

/// A reply updates its parent's reply bar; message_replied, when Slack sends it, carries the
/// same numbers, so a reply already counted (latest_reply at or past it) is not counted again.
- (void)countReply:(SNMessage *)reply {
    [self updateMessage:reply.threadTS inConversation:reply.conversationID transform:^SNMessage *(SNMessage *parent) {
        if (parent.latestReply && SNCompareTS(parent.latestReply, reply.ts) != NSOrderedAscending) return parent;
        NSMutableArray *users = [parent.replyUserIDs mutableCopy];
        BOOL newUser = reply.userID && ![users containsObject:reply.userID];
        if (newUser) [users addObject:reply.userID];
        return [parent messageByMergingJSON:@{@"thread_ts" : parent.ts, @"reply_count" : @(parent.replyCount + 1), @"latest_reply" : reply.ts,
                                              @"reply_users" : users, @"reply_users_count" : @(parent.replyUsersCount + (newUser ? 1 : 0))}];
    }];
}

/// After a reply is deleted, the parent's reply bar counts what the thread holds, when it holds
/// every reply (fetched in this session, kept up to date since); else Slack's next copy of the
/// parent will say.
- (void)recountReplies:(NSString *)threadKey {
    SNHistory *thread = self.threads[threadKey];
    SNMessage *parent = thread.messages.firstObject;
    if (!thread.fresh || !parent.isThreadParent || parent.replyCount != (NSInteger)thread.messages.count) return;
    NSInteger count = (NSInteger)thread.messages.count - 1;
    NSDictionary *changes = count ? @{@"reply_count" : @(count), @"latest_reply" : thread.messages.lastObject.ts}
                                  : @{@"reply_count" : NSNull.null, @"latest_reply" : NSNull.null, @"reply_users" : NSNull.null, @"reply_users_count" : NSNull.null};
    [self updateMessage:parent.ts inConversation:parent.conversationID transform:^SNMessage *(SNMessage *held) { return [held messageByMergingJSON:changes]; }];
}

- (void)applyReaction:(NSDictionary *)event added:(BOOL)added {
    NSDictionary *item = SNJSONObject(event, @"item");
    NSString *conversationID = SNJSONString(item, @"channel"), *ts = SNJSONString(item, @"ts");
    NSString *name = SNJSONString(event, @"reaction"), *userID = SNJSONString(event, @"user");
    if (!conversationID || !ts || !name || !userID) return;
    [self updateMessage:ts inConversation:conversationID transform:^SNMessage *(SNMessage *message) {
        return SNMessageReacting(message, name, userID, added);
    }];
}

- (void)applyFileDeleted:(NSString *)fileID {
    if (!fileID) return;
    for (NSString *conversationID in self.histories.allKeys)
        for (SNMessage *message in [self.histories[conversationID].messages copy]) {
            if (![[message.files valueForKey:@"fileID"] containsObject:fileID]) continue;
            [self updateMessage:message.ts inConversation:conversationID transform:^SNMessage *(SNMessage *held) {
                NSMutableArray *files = [NSMutableArray new];
                for (NSDictionary *file in SNJSONArray(held.json, @"files"))
                    [files addObject:[SNJSONString(file, @"id") isEqualToString:fileID] ? @{@"id" : fileID, @"mode" : @"tombstone"} : file];
                return [held messageByMergingJSON:@{@"files" : files}];
            }];
        }
}

#pragma mark Conversations

- (void)applyMarked:(NSDictionary *)event {
    NSString *conversationID = SNJSONString(event, @"channel"), *ts = SNJSONString(event, @"ts");
    SNConversation *conversation = conversationID ? self.conversationsByID[conversationID] : nil;
    if (!conversation || !ts) return;
    BOOL readAll = !conversation.latest || SNCompareTS(ts, conversation.latest) != NSOrderedAscending;
    NSMutableDictionary *changes = [@{@"last_read" : ts, @"has_unreads" : @(!readAll)} mutableCopy];
    if (event[@"mention_count"]) changes[@"mention_count"] = @(SNJSONInteger(event, @"mention_count"));
    else if (event[@"num_mentions_display"]) changes[@"mention_count"] = @(SNJSONInteger(event, @"num_mentions_display"));
    else if (readAll) changes[@"mention_count"] = @0;
    [self setConversation:[conversation conversationByMergingJSON:changes]];
    [self.readKnown addObject:conversationID];
}

/// Events name the conversation as "channel": an ID, or the conversation itself.
- (void)mergeConversation:(NSDictionary *)event changes:(NSDictionary *)changes {
    id channel = event[@"channel"] ?: event[@"id"];
    NSString *conversationID = [channel isKindOfClass:NSString.class] ? channel : SNJSONString(channel, @"id");
    SNConversation *conversation = conversationID ? self.conversationsByID[conversationID] : nil;
    if (conversation) [self setConversation:[conversation conversationByMergingJSON:changes]];
}

- (void)applyMembership:(NSDictionary *)event joined:(BOOL)joined {
    NSString *conversationID = SNJSONString(event, @"channel");
    SNConversation *conversation = conversationID ? self.conversationsByID[conversationID] : nil;
    if (!conversation) return;
    NSMutableDictionary *changes = [@{@"num_members" : @(MAX(0, conversation.memberCount + (joined ? 1 : -1)))} mutableCopy];
    if ([SNJSONString(event, @"user") isEqualToString:self.meID]) changes[@"is_member"] = @(joined);
    [self setConversation:[conversation conversationByMergingJSON:changes]];
}

- (void)applySectionEvent:(NSDictionary *)event type:(NSString *)type {
    NSString *sectionID = SNJSONString(event, @"channel_section_id");
    NSUInteger index = [self.sectionJSON indexOfObjectPassingTest:^BOOL(NSDictionary *json, NSUInteger i, BOOL *stop) {
        return sectionID && [SNJSONString(json, @"channel_section_id") isEqualToString:sectionID];
    }];
    if ([type isEqualToString:@"channel_section_upserted"]) {
        NSMutableDictionary *json = [event mutableCopy];
        [json removeObjectsForKeys:@[ @"type", @"event_ts" ]];
        if (index != NSNotFound) {
            // An upsert does not repeat the section's channels.
            if (!json[@"channel_ids_page"] && self.sectionJSON[index][@"channel_ids_page"]) json[@"channel_ids_page"] = self.sectionJSON[index][@"channel_ids_page"];
            self.sectionJSON[index] = json;
        } else if (sectionID) [self.sectionJSON addObject:json];
    } else if ([type isEqualToString:@"channel_section_deleted"]) {
        if (index != NSNotFound) [self.sectionJSON removeObjectAtIndex:index];
    } else if (index != NSNotFound && ([type isEqualToString:@"channel_sections_channels_upserted"] || [type isEqualToString:@"channel_sections_channels_removed"])) {
        BOOL add = [type hasSuffix:@"upserted"];
        NSDictionary *section = self.sectionJSON[index];
        NSDictionary *page = SNJSONObject(section, @"channel_ids_page") ?: @{};
        NSMutableArray *ids = [SNJSONStrings(page, @"channel_ids") mutableCopy];
        for (NSString *conversationID in SNJSONStrings(event, @"channel_ids")) {
            [ids removeObject:conversationID];
            if (add) [ids insertObject:conversationID atIndex:0];
        }
        self.sectionJSON[index] = SNJSONMerge(section, @{@"channel_ids_page" : SNJSONMerge(page, @{@"channel_ids" : ids})});
    } else return;
    [self saveSections];
}

#pragma mark People

- (void)applyPresence:(NSDictionary *)event {
    SNPresence presence = SNPresenceNamed(SNJSONString(event, @"presence"));
    // batch_presence_aware sends one event for many users.
    for (NSString *userID in SNJSONStrings(event, @"users")) [self setPresence:presence ofUser:userID];
    NSString *userID = SNJSONString(event, @"user");
    if (userID) [self setPresence:presence ofUser:userID];
}

- (void)applyTyping:(NSDictionary *)event {
    NSString *conversationID = SNJSONString(event, @"channel"), *userID = SNJSONString(event, @"user");
    if (!conversationID || !userID || [userID isEqualToString:self.meID]) return;
    NSString *threadTS = SNJSONString(event, @"thread_ts");
    NSString *key = threadTS ? SNThreadKey(conversationID, threadTS) : conversationID;
    NSMutableDictionary<NSString *, NSArray<NSDate *> *> *typing = self.typing[key] ?: (self.typing[key] = [NSMutableDictionary new]);
    NSDate *started = typing[userID].firstObject;
    typing[userID] = @[ started ?: NSDate.date, [NSDate dateWithTimeIntervalSinceNow:SNTypingTimeout] ];
    if (!started) [self changed:SNChangeTyping value:key];
    [self noteUser:userID];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((SNTypingTimeout + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDate *expiry = self.typing[key][userID].lastObject;
        if (expiry && expiry.timeIntervalSinceNow <= 0) [self performChanges:^{ [self stopTyping:userID key:key]; }];
    });
}

- (void)stopTyping:(NSString *)userID key:(NSString *)key {
    if (!self.typing[key][userID]) return;
    [self.typing[key] removeObjectForKey:userID];
    if (!self.typing[key].count) [self.typing removeObjectForKey:key];
    [self changed:SNChangeTyping value:key];
}

- (NSArray<NSString *> *)typingUserIDsInConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    // "Display information about who is currently typing a message".
    if (!SNPreferenceBool(self.prefs, @"show_typing", YES)) return @[];
    NSDictionary<NSString *, NSArray<NSDate *> *> *typing = self.typing[threadTS ? SNThreadKey(conversationID, threadTS) : conversationID];
    return [typing keysSortedByValueUsingComparator:^NSComparisonResult(NSArray<NSDate *> *a, NSArray<NSDate *> *b) {
        return [a.firstObject compare:b.firstObject];
    }];
}

#pragma mark Emoji

- (void)applyEmojiChange:(NSDictionary *)event {
    NSString *subtype = SNJSONString(event, @"subtype");
    NSMutableDictionary *emoji = [self.emojiList mutableCopy];
    if ([subtype isEqualToString:@"add"]) {
        NSString *name = SNJSONString(event, @"name"), *value = SNJSONString(event, @"value");
        if (name && value) emoji[name] = value;
    } else if ([subtype isEqualToString:@"remove"]) {
        [emoji removeObjectsForKeys:SNJSONStrings(event, @"names")];
    } else if ([subtype isEqualToString:@"rename"]) {
        NSString *old = SNJSONString(event, @"old_name"), *name = SNJSONString(event, @"new_name"), *value = SNJSONString(event, @"value");
        if (old) [emoji removeObjectForKey:old];
        if (name && value) emoji[name] = value;
    } else return;
    [self applyEmoji:emoji];
}

@end
