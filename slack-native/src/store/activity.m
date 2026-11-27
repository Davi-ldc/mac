// Owns the Activity feed: activity.feed's pages as the web client asks for them, the `activity`
// websocket events that keep them current, the messages its entries point at, the rows' actions
// (read, unread, clear) and the Later state they offer.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

/// The web client's "all" feed (ZLEh's type list for the All filter outside the Activity inbox
/// experiment). Kinds this client does not show are still asked for, so the pages and their
/// cursors are Slack's own.
static NSString *const SNActivityTypes = @"thread_v2,message_reaction,internal_channel_invite,list_record_edited,"
                                         @"prejoin_dm_welcome_party_alert,quietly_added_to_channel,bot_dm_bundle,at_user,"
                                         @"at_user_group,at_channel,at_everyone,keyword,list_record_assigned,list_user_mentioned,"
                                         @"list_todo_notification,list_approval_request,list_approval_reviewed,"
                                         @"unjoined_channel_mention,external_channel_invite,external_dm_invite";
/// The VIP tab's types (ZLEh's list for the VIP filter).
static NSString *const SNActivityVIPTypes = @"thread_v2,internal_channel_invite,at_user,at_user_group,at_channel,at_everyone,keyword,bot_dm_bundle";
/// The web client's page size, and messages.list's channels per call.
static const NSInteger SNActivityPage = 20, SNMessagesListChannels = 10;

/// "<conversation ID>/<ts>": the messages asked for and received.
static NSString *MessageKey(NSString *conversationID, NSString *ts) { return [NSString stringWithFormat:@"%@/%@", conversationID, ts]; }

@implementation SNStore (Activity)

- (NSArray<SNActivityEntry *> *)activityEntries {
    if (self.activityCachePending) [self loadActivityCache];
    return self.activity;
}
- (BOOL)isLoadingActivity { return self.activityRequest != 0; }
- (BOOL)hasMoreActivity { return self.activityCursor.length > 0; }
- (BOOL)activityUnreadsOnly {
    if (self.activityCachePending) [self loadActivityCache];
    return self.activityUnreads;
}
- (BOOL)activityVIPOnly { return self.activityVIP; }

- (void)loadActivityCache {
    if (!self.activityCachePending) return;
    self.activityCachePending = NO;
    NSDictionary *cache = [self.database jsonForKey:@"activity"];
    if (![cache isKindOfClass:NSDictionary.class]) return;
    self.activityUnreads = SNJSONBool(cache, @"unreads_only");
    [self setActivityItems:SNJSONArray(cache, @"items") ?: @[]];
}

- (void)setActivityItems:(NSArray<NSDictionary *> *)items {
    self.activityCachePending = NO;
    self.activityJSON = items;
    self.activity = SNJSONMap(@{@"items" : items}, @"items", ^id(NSDictionary *item) { return [SNActivityEntry entryWithJSON:item]; });
    [self changed:SNChangeActivity value:nil];
}

- (void)saveActivity {
    if (self.activityVIP) return;
    [self.database setJSON:@{@"unreads_only" : @(self.activityUnreads), @"items" : self.activityJSON} forKey:@"activity"];
}

- (void)setActivityUnreadsOnly:(BOOL)unreadsOnly {
    if (self.activityCachePending) [self loadActivityCache];
    if (unreadsOnly == self.activityUnreads) return;
    self.activityUnreads = unreadsOnly;
    [self performChanges:^{
        // The other mode's entries would show until the answer: Slack's client clears the list too.
        self.activityCursor = nil;
        [self setActivityItems:@[]];
        [self saveActivity];
    }];
    [self loadActivity];
}

- (void)setActivityVIPOnly:(BOOL)vipOnly {
    if (vipOnly == self.activityVIP) return;
    self.activityVIP = vipOnly;
    [self performChanges:^{
        self.activityCursor = nil;
        [self setActivityItems:@[]];
    }];
    [self loadActivity];
}

- (void)loadActivity { [self requestActivityPage:nil]; }

- (void)loadMoreActivity {
    if (self.activityRequest || !self.hasMoreActivity) return;
    [self requestActivityPage:self.activityCursor];
}

/// One page of the feed; a first page replaces what is held, a later one adds to it. A newer
/// request supersedes one in flight, whose answer is then dropped (the web client's request id).
- (void)requestActivityPage:(nullable NSString *)cursor {
    static NSInteger requests;
    NSInteger request = ++requests;
    self.activityRequest = request;
    [self performChanges:^{ [self changed:SNChangeActivity value:nil]; }];
    // 3i0U: the VIP tab's priority-only modes, else the chronological ones.
    NSString *mode = self.activityVIP ? (self.activityUnreads ? @"chrono_priority_only_unreads_v1" : @"chrono_priority_only_reads_and_unreads_v1")
                                      : self.activityUnreads ? @"chrono_unreads" : @"chrono_reads_and_unreads";
    NSMutableDictionary *params = [@{@"limit" : @(SNActivityPage).stringValue, @"types" : self.activityVIP ? SNActivityVIPTypes : SNActivityTypes, @"mode" : mode,
                                     @"archive_only" : @"false", @"unread_only" : @"false", @"priority_only" : @"false",
                                     @"only_salesforce_channels" : @"false", @"exclude_automations" : @"false",
                                     @"automations_only" : @"false", @"is_activity_inbox" : @"false", @"_x_reason" : @"fetchActivityFeed"} mutableCopy];
    if (cursor) params[@"cursor"] = cursor;
    [self request:@"activity.feed" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (self.activityRequest != request) return;
        self.activityRequest = 0;
        NSArray *items = SNJSONArray(response, @"items");
        [self performChanges:^{
            if (items) {
                NSMutableArray *all = cursor ? [self.activityJSON mutableCopy] : [NSMutableArray new];
                NSMutableSet *keys = [NSMutableSet setWithArray:[all valueForKey:@"key"]];
                for (id item in items) {
                    NSString *key = SNJSONString(item, @"key");
                    if ([item isKindOfClass:NSDictionary.class] && !(key && [keys containsObject:key])) [all addObject:item];
                    if (key) [keys addObject:key];
                }
                self.activityCursor = SNJSONString(SNJSONObject(response, @"response_metadata"), @"next_cursor");
                [self setActivityItems:all];
                [self saveActivity];
            }
            [self changed:SNChangeActivity value:nil];
        }];
    }];
}

#pragma mark Live

- (void)applyActivityEvent:(NSDictionary *)event {
    if (self.activityCachePending) [self loadActivityCache];
    NSString *subtype = SNJSONString(event, @"subtype");
    if ([subtype isEqualToString:@"activity_invalidated"]) {
        [self loadActivity];
        return;
    }
    NSDictionary *entry = SNJSONObject(event, @"entry");
    NSString *key = [subtype isEqualToString:@"activity_deleted"] ? SNJSONString(event, @"key") : SNJSONString(entry, @"key");
    if (!key || !([subtype isEqualToString:@"activity_deleted"] || (entry && [subtype isEqualToString:@"activity_updated"]))) return;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    BOOL existed = NO;
    for (NSDictionary *item in self.activityJSON) {
        if ([SNJSONString(item, @"key") isEqualToString:key]) existed = YES;
        else [items addObject:item];
    }
    // An update moves the item to its feed_ts (a thread's new reply brings it to the top); with
    // the unreads switch on, one read leaves the list. In VIP mode, never pollute the feed with
    // excluded types or non-VIP actors.
    BOOL keep = entry && !(self.activityUnreads && !SNJSONBool(entry, @"is_unread"));
    if (keep && self.activityVIP) {
        static NSSet<NSString *> *vipTypes;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ vipTypes = [NSSet setWithArray:[SNActivityVIPTypes componentsSeparatedByString:@","]]; });
        NSDictionary *item = SNJSONObject(entry, @"item");
        NSString *type = SNJSONString(item, @"type");
        if (!type || ![vipTypes containsObject:type]) {
            keep = NO;
        } else {
            SNActivityEntry *decoded = [SNActivityEntry entryWithJSON:entry];
            NSString *actor = decoded.actorUserID;
            if (!actor.length) actor = SNJSONString(SNJSONObject(item, @"message"), @"author_user_id");
            if (!actor.length) {
                NSDictionary *thread = SNJSONObject(SNJSONObject(SNJSONObject(item, @"bundle_info"), @"payload"), @"thread_entry");
                actor = SNJSONString(thread, @"latest_reply_user");
            }
            if (!actor.length && decoded)
                actor = [self cachedMessageWithTS:decoded.messageTS inConversation:decoded.conversationID threadTS:decoded.threadTS].userID;
            NSSet<NSString *> *vips = [NSSet setWithArray:self.vipUserIDs];
            if (actor.length) {
                keep = [vips containsObject:actor];
            } else if (!existed) {
                // Unknown actor (e.g. uncached thread_v2): ask Slack's VIP feed rather than inserting blindly.
                keep = NO;
                if (!self.activityRequest) [self loadActivity];
            }
        }
    }
    if (keep) {
        NSString *feedTS = SNJSONString(entry, @"feed_ts") ?: @"0";
        NSUInteger index = 0;
        while (index < items.count && SNCompareTS(SNJSONString(items[index], @"feed_ts") ?: @"0", feedTS) == NSOrderedDescending) index++;
        // Past the last page held, the item belongs to a page not loaded yet.
        if (index < items.count || !self.hasMoreActivity) [items insertObject:entry atIndex:index];
    }
    [self setActivityItems:items];
    [self saveActivity];
}

#pragma mark Actions

/// The item's place in the feed by its key; NSNotFound when it is not held.
- (NSUInteger)indexOfActivityItem:(NSString *)key {
    return [self.activityJSON indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) { return [SNJSONString(item, @"key") isEqualToString:key]; }];
}

- (void)setActivityItem:(NSString *)key unread:(BOOL)unread {
    NSUInteger index = [self indexOfActivityItem:key];
    if (index == NSNotFound) return;
    NSMutableArray *items = [self.activityJSON mutableCopy];
    if (self.activityUnreads && !unread) [items removeObjectAtIndex:index];
    else items[index] = SNJSONMerge(items[index], @{@"is_unread" : @(unread)});
    [self performChanges:^{
        [self setActivityItems:items];
        [self saveActivity];
    }];
}

// The requests name the item by Slack's own key and feed_ts, never the ones made up for an item
// that lacks them.
- (void)markActivityEntry:(SNActivityEntry *)entry read:(BOOL)read {
    NSString *key = SNJSONString(entry.json, @"key"), *feedTS = SNJSONString(entry.json, @"feed_ts");
    if (!key || !feedTS || entry.isUnread != read) return;
    [self setActivityItem:key unread:!read];
    if ([entry.type isEqualToString:@"message_reaction"]) return;
    NSDictionary *params = read ? @{@"type" : entry.type, @"key" : key, @"feed_ts" : feedTS, @"_x_reason" : @"mark-as-read-v2"}
                                : @{@"entries" : SNJSONText(@[ @{@"type" : entry.type, @"key" : key, @"ts" : feedTS, @"feed_ts" : feedTS} ]), @"_x_reason" : @"mark-as-unread"};
    [self request:read ? @"activity.markRead" : @"activity.markUnread" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (!error) return;
        [self setActivityItem:key unread:read];
        [self loadActivity];
    }];
}

// Slack's client only logs a failed clear: the item stays gone.
- (void)clearActivityEntry:(SNActivityEntry *)entry {
    NSString *key = SNJSONString(entry.json, @"key"), *feedTS = SNJSONString(entry.json, @"feed_ts");
    NSUInteger index = key ? [self indexOfActivityItem:key] : NSNotFound;
    if (!feedTS || index == NSNotFound) return;
    NSMutableArray *items = [self.activityJSON mutableCopy];
    [items removeObjectAtIndex:index];
    [self performChanges:^{
        [self setActivityItems:items];
        [self saveActivity];
    }];
    [self request:@"activity.archive" params:@{@"type" : entry.type, @"key" : key, @"ts" : feedTS, @"_x_reason" : @"clear_notification_button"}
         priority:SNCallUserFacing
       completion:nil];
}

#pragma mark Later

/// A message's "saved" object (Slack's Later state) counts while it is neither archived nor done.
- (BOOL)isMessageSavedWithTS:(NSString *)ts inConversation:(NSString *)conversationID {
    NSNumber *changed = self.savedChanges[MessageKey(conversationID, ts)];
    if (changed) return changed.boolValue;
    SNMessage *message = [self cachedMessageWithTS:ts inConversation:conversationID threadTS:nil] ?: self.activityMessages[MessageKey(conversationID, ts)];
    NSDictionary *saved = SNJSONObject(message.json, @"saved");
    return saved && !SNJSONBool(saved, @"is_archived") && ![SNJSONString(saved, @"state") isEqualToString:@"completed"];
}

- (void)setSaved:(BOOL)saved messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID {
    BOOL was = [self isMessageSavedWithTS:ts inConversation:conversationID];
    if (was == saved) return;
    [self noteSaved:saved messageWithTS:ts inConversation:conversationID];
    NSDictionary *params = @{@"item_type" : @"message", @"item_id" : conversationID, @"ts" : ts,
                             @"_x_reason" : saved ? @"saved-api/saveMessage" : @"saved-api/removeSavedMessage"};
    [self request:saved ? @"saved.add" : @"saved.delete" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (error) [self noteSaved:was messageWithTS:ts inConversation:conversationID];
    }];
}

// saveReminder: the description as rich_text JSON and the time in whole seconds; Slack's answer is
// the saved_added event, which only the Later list reads.
- (void)addReminderWithDescription:(NSArray<NSDictionary *> *)description due:(NSDate *)due completion:(void (^)(NSString *))completion {
    NSDictionary *params = @{@"item_type" : @"reminder", @"description" : SNJSONText(description), @"client_id" : NSUUID.UUID.UUIDString.lowercaseString,
                             @"date_due" : @((long long)due.timeIntervalSince1970).stringValue, @"_x_reason" : @"saved-api/saveReminder"};
    [self request:@"saved.add" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (completion) completion(error ? SNAPIErrorName(error) ?: @"" : nil);
    }];
}

static const NSUInteger kActivityMessageLimit = 200;
static const NSUInteger kSavedChangeLimit = 200;

- (void)noteSaved:(BOOL)saved messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID {
    [self performChanges:^{
        NSString *key = MessageKey(conversationID, ts);
        [self.savedChangeOrder removeObject:key];
        [self.savedChangeOrder addObject:key];
        self.savedChanges[key] = @(saved);
        while (self.savedChangeOrder.count > kSavedChangeLimit) {
            NSString *oldest = self.savedChangeOrder.firstObject;
            [self.savedChangeOrder removeObjectAtIndex:0];
            [self.savedChanges removeObjectForKey:oldest];
        }
        [self changed:SNChangeActivity value:nil];
        SNMessage *message = [self cachedMessageWithTS:ts inConversation:conversationID threadTS:nil];
        if (message) [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
    }];
}

#pragma mark Messages

- (SNMessage *)messageForActivityEntry:(SNActivityEntry *)entry {
    SNMessage *message = [self cachedMessageWithTS:entry.messageTS inConversation:entry.conversationID threadTS:entry.threadTS];
    if (message) return message;
    NSString *key = MessageKey(entry.conversationID, entry.messageTS);
    message = self.activityMessages[key];
    if (message || [self.activityMessagesAsked containsObject:key]) return message;
    [self.activityMessagesAsked addObject:key];
    if (!self.activityMessagesWanted.count)
        dispatch_async(dispatch_get_main_queue(), ^{ [self requestActivityMessages]; });
    [self.activityMessagesWanted addObject:key];
    return nil;
}

/// messages.list for what rows asked in this turn, as the web client's message loader does:
/// message_ids [{channel, timestamps}], ten channels a call.
- (void)requestActivityMessages {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byConversation = [NSMutableDictionary new];
    for (NSString *key in self.activityMessagesWanted) {
        NSRange slash = [key rangeOfString:@"/"];
        NSString *conversationID = [key substringToIndex:slash.location], *ts = [key substringFromIndex:NSMaxRange(slash)];
        if (!byConversation[conversationID]) byConversation[conversationID] = [NSMutableArray new];
        [byConversation[conversationID] addObject:ts];
    }
    [self.activityMessagesWanted removeAllObjects];
    NSArray<NSString *> *conversations = [byConversation.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger start = 0; start < conversations.count; start += SNMessagesListChannels) {
        NSMutableArray *ids = [NSMutableArray new];
        for (NSString *conversationID in [conversations subarrayWithRange:NSMakeRange(start, MIN(SNMessagesListChannels, conversations.count - start))])
            [ids addObject:@{@"channel" : conversationID, @"timestamps" : byConversation[conversationID]}];
        NSDictionary *params = @{@"message_ids" : SNJSONText(ids), @"org_wide_aware" : @"true", @"cached_latest_updates" : @"{}", @"_x_reason" : @"messages-ufm"};
        [self request:@"messages.list" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
            // Unanswered, they may be asked again; answered, a message left out is gone for this session.
            if (!response)
                for (NSDictionary *wanted in ids)
                    for (NSString *ts in wanted[@"timestamps"]) [self.activityMessagesAsked removeObject:MessageKey(wanted[@"channel"], ts)];
            [self performChanges:^{
                [self applyListedMessages:response];
                [self changed:SNChangeActivity value:nil];
            }];
        }];
    }
}

/// messages.list answers {messages_data: {<channel>: {messages}}}, or {messages: {<channel>: [...]}}.
- (void)applyListedMessages:(NSDictionary *)response {
    NSDictionary *data = SNJSONObject(response, @"messages_data");
    NSDictionary *legacy = SNJSONObject(response, @"messages");
    for (NSString *conversationID in (data ?: legacy).allKeys) {
        NSArray *messages = data ? SNJSONArray(SNJSONObject(data, conversationID), @"messages") : SNJSONArray(legacy, conversationID);
        for (id json in messages) {
            SNMessage *message = [json isKindOfClass:NSDictionary.class] ? [SNMessage messageWithJSON:json conversationID:conversationID] : nil;
            if (!message) continue;
            NSString *key = MessageKey(conversationID, message.ts);
            [self.activityMessageOrder removeObject:key];
            [self.activityMessageOrder addObject:key];
            self.activityMessages[key] = message;
            while (self.activityMessageOrder.count > kActivityMessageLimit) {
                NSString *oldest = self.activityMessageOrder.firstObject;
                [self.activityMessageOrder removeObjectAtIndex:0];
                [self.activityMessages removeObjectForKey:oldest];
                [self.activityMessagesAsked removeObject:oldest];
            }
            [self noteUser:message.userID];
        }
    }
}

@end
