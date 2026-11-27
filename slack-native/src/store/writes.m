// Owns the UI's requests: optimistic send (reconciled by client_msg_id), edit, delete, reactions,
// read marks (debounced), typing, drafts and the user's own settings.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation SNStore (Writes)

#pragma mark Sending

- (SNMessage *)sendText:(NSString *)text blocks:(NSArray<NSDictionary *> *)blocks inConversation:(NSString *)conversationID
               threadTS:(NSString *)threadTS broadcast:(BOOL)broadcast {
    return [self sendText:text blocks:blocks uploads:@[] inConversation:conversationID threadTS:threadTS broadcast:broadcast];
}

- (SNMessage *)sendText:(NSString *)text blocks:(NSArray<NSDictionary *> *)blocks uploads:(NSArray<SNUpload *> *)uploads inConversation:(NSString *)conversationID
               threadTS:(NSString *)threadTS broadcast:(BOOL)broadcast {
    return [self sendText:text blocks:blocks uploads:uploads attachments:@[] inConversation:conversationID threadTS:threadTS broadcast:broadcast];
}

- (SNMessage *)sendText:(NSString *)text blocks:(NSArray<NSDictionary *> *)blocks attachments:(NSArray<NSDictionary *> *)attachments inConversation:(NSString *)conversationID
               threadTS:(NSString *)threadTS broadcast:(BOOL)broadcast {
    return [self sendText:text blocks:blocks uploads:@[] attachments:attachments inConversation:conversationID threadTS:threadTS broadcast:broadcast];
}

- (SNMessage *)sendText:(NSString *)text blocks:(NSArray<NSDictionary *> *)blocks uploads:(NSArray<SNUpload *> *)uploads attachments:(NSArray<NSDictionary *> *)attachments
         inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS broadcast:(BOOL)broadcast {
    NSString *after = [self cachedLatestInConversation:conversationID];
    if (threadTS) after = [self threadInConversation:conversationID ts:threadTS].lastObject.ts ?: after;
    NSMutableDictionary *json = [@{@"type" : @"message", @"user" : self.meID ?: @"", @"text" : text, @"ts" : SNLocalTS(after),
                                   @"client_msg_id" : NSUUID.UUID.UUIDString.lowercaseString, @"sn_send_state" : @"pending"} mutableCopy];
    if (blocks.count) json[@"blocks"] = blocks;
    if (attachments.count) json[@"attachments"] = attachments;
    if (threadTS) json[@"thread_ts"] = threadTS;
    if (threadTS && broadcast) json[@"subtype"] = @"thread_broadcast";
    // A message with files shows them from this device (sn_local_url) until Slack's copy comes;
    // sn_uploads names the uploads files.share waits for.
    NSMutableArray *files = [NSMutableArray new], *uploadIDs = [NSMutableArray new];
    for (SNUpload *upload in uploads) {
        SNUpload *held = self.uploads[upload.uploadID];
        if (!held) continue;
        [files addObject:held.fileJSON];
        [uploadIDs addObject:held.uploadID];
    }
    if (uploadIDs.count) [json addEntriesFromDictionary:@{@"files" : files, @"upload" : @YES, @"display_as_bot" : @NO, @"sn_uploads" : uploadIDs}];
    SNMessage *message = [SNMessage messageWithJSON:json conversationID:conversationID];
    NSString *key = threadTS ? SNThreadKey(conversationID, threadTS) : conversationID;
    [self performChanges:^{
        [self putMessage:message];
        if (threadTS) [self countReply:message];
        [self setDraft:nil inConversation:conversationID threadTS:threadTS];
        if (uploadIDs.count) {
            [self.attachedUploads[key] removeObjectsInArray:uploadIDs];
            [self changed:SNChangeUploads value:key];
        }
    }];
    [self post:message];
    return message;
}

// The row that offered Retry may hold a copy older than the store's: only a send that is failed
// now, and not on its way, goes out again.
- (void)retrySendingMessage:(SNMessage *)message {
    if (!message.conversationID || [self.sending containsObject:message.identifier]) return;
    __block SNMessage *pending = nil;
    [self performChanges:^{
        [self updateMessage:message.ts inConversation:message.conversationID threadTS:message.threadTS transform:^SNMessage *(SNMessage *held) {
            if (held.sendState != SNMessageFailed) return held;
            return pending = pending ?: [held messageWithSendState:SNMessagePending];
        }];
    }];
    if (pending) [self post:pending];
}

- (void)post:(SNMessage *)message {
    if (SNJSONArray(message.json, @"sn_uploads").count) return [self shareWhenUploaded:message];
    NSString *conversationID = message.conversationID, *identifier = message.identifier;
    [self.sending addObject:identifier];
    NSMutableDictionary *params = [@{@"channel" : conversationID, @"text" : message.text, @"client_msg_id" : identifier,
                                     @"_x_reason" : @"webapp_message_send", @"type" : @"message", @"unfurl" : @"[]"} mutableCopy];
    if (message.blocks.count) params[@"blocks"] = SNJSONText(message.blocks);
    if (message.attachments.count) params[@"attachments"] = SNJSONText(message.attachments);
    if (message.threadTS) params[@"thread_ts"] = message.threadTS;
    if ([message.subtype isEqualToString:@"thread_broadcast"]) params[@"reply_broadcast"] = @"true";
    [self request:@"chat.postMessage" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        [self.sending removeObject:identifier];
        NSDictionary *json = SNJSONObject(response, @"message");
        SNMessage *sent = json ? [SNMessage messageWithJSON:SNJSONMerge(json, @{@"client_msg_id" : identifier}) conversationID:conversationID] : nil;
        [self performChanges:^{
            // The websocket's echo may have confirmed it already, and an unfurl may have changed
            // it since: the answer is the message as it was posted.
            SNMessage *held = [self heldSend:message];
            if (sent && (!held || held.sendState != SNMessageSent)) [self confirm:sent];
            else if (!sent)
                [self updateMessage:message.ts inConversation:conversationID threadTS:message.threadTS transform:^SNMessage *(SNMessage *copy) {
                    return copy.sendState == SNMessagePending ? [copy messageWithSendState:SNMessageFailed] : copy;
                }];
        }];
    }];
}

/// The copy of a message sent from here that memory holds now (a run waiting for a send's answer
/// is never evicted), matched by its client_msg_id.
- (SNMessage *)heldSend:(SNMessage *)message {
    SNHistory *run = message.isReply ? self.threads[SNThreadKey(message.conversationID, message.threadTS)] : self.histories[message.conversationID];
    return [run messageWithIdentifier:message.identifier];
}

/// The server's copy of a message sent from here (the HTTP answer or the websocket echo, which
/// may come first) replaces the pending one.
- (void)confirm:(SNMessage *)sent {
    [self putMessage:sent];
    SNConversation *conversation = self.conversationsByID[sent.conversationID];
    if (conversation && !sent.isReply) {
        // Posting reads the conversation up to the new message, as in Slack.
        NSDictionary *changes = @{@"latest" : sent.ts, @"last_read" : sent.ts, @"has_unreads" : @NO, @"mention_count" : @0};
        if (!conversation.latest || SNCompareTS(conversation.latest, sent.ts) != NSOrderedDescending) {
            [self setConversation:[conversation conversationByMergingJSON:changes]];
            [self.readKnown addObject:sent.conversationID];
        }
    }
}

#pragma mark Edit, delete, reactions

- (void)editMessage:(SNMessage *)message text:(NSString *)text blocks:(NSArray<NSDictionary *> *)blocks {
    if (!message.conversationID || message.sendState != SNMessageSent) return;
    NSString *conversationID = message.conversationID, *ts = message.ts, *threadTS = message.threadTS;
    __block SNMessage *original = nil;
    [self performChanges:^{
        [self updateMessage:ts inConversation:conversationID threadTS:threadTS transform:^SNMessage *(SNMessage *held) {
            original = original ?: held;
            NSDictionary *edited = @{@"user" : self.meID ?: @"", @"ts" : SNLocalTS(nil)};
            return [held messageByMergingJSON:@{@"text" : text, @"blocks" : blocks.count ? blocks : NSNull.null, @"edited" : edited}];
        }];
    }];
    NSMutableDictionary *params = [@{@"channel" : conversationID, @"ts" : ts, @"text" : text, @"_x_reason" : @"webapp_message_edit"} mutableCopy];
    params[@"blocks"] = SNJSONText(blocks ?: @[]);
    [self request:@"chat.update" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (!error || !original) return;
        [self performChanges:^{
            [self updateMessage:ts inConversation:conversationID threadTS:threadTS transform:^SNMessage *(SNMessage *held) {
                return [held messageByMergingJSON:@{@"text" : original.json[@"text"] ?: @"", @"blocks" : original.json[@"blocks"] ?: NSNull.null,
                                                    @"edited" : original.json[@"edited"] ?: NSNull.null}];
            }];
        }];
    }];
}

- (void)deleteMessage:(SNMessage *)message {
    NSString *conversationID = message.conversationID, *ts = message.ts, *threadTS = message.threadTS;
    if (!conversationID) return;
    __block SNMessage *removed = nil;
    [self performChanges:^{
        [self updateMessage:ts inConversation:conversationID threadTS:threadTS transform:^SNMessage *(SNMessage *held) {
            removed = removed ?: held;
            return nil;
        }];
    }];
    // Slack keeps no copy of a message only the user sees.
    if (message.sendState != SNMessageSent || !removed || message.isEphemeral) return;
    [self request:@"chat.delete" params:@{@"channel" : conversationID, @"ts" : ts, @"_x_reason" : @"animateAndDeleteMessageApi"}
        priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
            if (!error || [SNAPIErrorName(error) isEqualToString:@"message_not_found"]) return;
            [self performChanges:^{ [self putMessage:removed]; }];
        }];
}

SNMessage *SNMessageReacting(SNMessage *message, NSString *name, NSString *userID, BOOL add) {
    NSMutableArray<SNReaction *> *reactions = [NSMutableArray new];
    BOOL found = NO;
    for (SNReaction *reaction in message.reactions) {
        if (![reaction.name isEqualToString:name]) {
            [reactions addObject:reaction];
            continue;
        }
        found = YES;
        BOOL mine = [reaction.userIDs containsObject:userID];
        if (mine == add) {
            [reactions addObject:reaction];
            continue;
        }
        NSMutableArray *users = [reaction.userIDs mutableCopy];
        if (add) [users addObject:userID];
        else [users removeObject:userID];
        NSInteger count = reaction.count + (add ? 1 : -1);
        if (count > 0) [reactions addObject:[SNReaction reactionWithName:name userIDs:users count:count]];
    }
    if (!found && add) [reactions addObject:[SNReaction reactionWithName:name userIDs:@[ userID ] count:1]];
    return [message messageWithReactions:reactions];
}

- (void)react:(BOOL)add name:(NSString *)name message:(SNMessage *)message {
    NSString *conversationID = message.conversationID, *ts = message.ts, *threadTS = message.threadTS, *me = self.meID;
    if (!conversationID || !me || message.sendState != SNMessageSent) return;
    SNMessage *held = [self messageWithTS:ts inConversation:conversationID threadTS:threadTS] ?: message;
    BOOL mine = NO;
    for (SNReaction *reaction in held.reactions)
        if ([reaction.name isEqualToString:name]) mine = [reaction.userIDs containsObject:me];
    if (mine == add) return;
    [self performChanges:^{
        [self updateMessage:ts inConversation:conversationID threadTS:threadTS transform:^SNMessage *(SNMessage *copy) { return SNMessageReacting(copy, name, me, add); }];
    }];
    if (add) [self noteEmojiUsed:name];
    NSString *method = add ? @"reactions.add" : @"reactions.remove";
    NSDictionary *params = @{@"channel" : conversationID, @"timestamp" : ts, @"name" : name, @"_x_reason" : @"changeReactionFromUserAction"};
    [self request:method params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSString *reason = SNAPIErrorName(error);
        if (!error || [reason isEqualToString:@"already_reacted"] || [reason isEqualToString:@"no_reaction"]) return;
        [self performChanges:^{
            [self updateMessage:ts inConversation:conversationID threadTS:threadTS transform:^SNMessage *(SNMessage *copy) { return SNMessageReacting(copy, name, me, !add); }];
        }];
    }];
}

- (void)toggleReaction:(NSString *)name onMessage:(SNMessage *)message {
    SNMessage *held = message.conversationID ? [self messageWithTS:message.ts inConversation:message.conversationID threadTS:message.threadTS] ?: message : message;
    BOOL mine = NO;
    for (SNReaction *reaction in held.reactions)
        if ([reaction.name isEqualToString:name]) mine = [reaction.userIDs containsObject:self.meID ?: @""];
    [self react:!mine name:name message:held];
}

#pragma mark Read marks

/// The newest message Slack has (neither pending nor failed: their ts is local) before `ts`, or
/// at it when `inclusive`; `messages` oldest first.
static NSString *SentTS(NSArray<SNMessage *> *messages, NSString *ts, BOOL inclusive) {
    for (SNMessage *message in messages.reverseObjectEnumerator) {
        NSComparisonResult order = SNCompareTS(message.ts, ts);
        if (message.sendState == SNMessageSent && (order == NSOrderedAscending || (inclusive && order == NSOrderedSame))) return message.ts;
    }
    return nil;
}

// Slack takes a mark as the new last_read even when it is older, so a mark that is not a
// message Slack has, or not past Slack's own last_read, would make read messages unread on
// every device. A last_read known only from the cache may be behind Slack's: such a
// conversation is not marked until client.counts (or an event) says where Slack's is.
- (void)markConversation:(NSString *)conversationID readThrough:(NSString *)ts {
    SNConversation *conversation = self.conversationsByID[conversationID];
    if (!ts.length || ![self.readKnown containsObject:conversationID] || !conversation.lastRead) return;
    NSString *mark = SentTS(self.histories[conversationID].messages, ts, YES);
    if (!mark || SNCompareTS(mark, conversation.lastRead) != NSOrderedDescending) return;
    NSString *latest = conversation.latest ?: [self cachedLatestInConversation:conversationID];
    BOOL readAll = !latest || SNCompareTS(mark, latest) != NSOrderedAscending;
    NSMutableDictionary *changes = [@{@"last_read" : mark, @"has_unreads" : @(!readAll)} mutableCopy];
    if (readAll) changes[@"mention_count"] = @0;
    [self performChanges:^{ [self setConversation:[conversation conversationByMergingJSON:changes]]; }];
    [self scheduleMark:conversationID ts:mark];
}

// A thread's last_read comes with its parent from conversations.replies, for threads the user
// follows; it counts once the thread was fetched in this session.
- (void)markThread:(NSString *)threadTS inConversation:(NSString *)conversationID readThrough:(NSString *)ts {
    SNHistory *thread = self.threads[SNThreadKey(conversationID, threadTS)];
    SNMessage *parent = thread.messages.firstObject;
    NSString *lastRead = SNJSONString(parent.json, @"last_read");
    if (!ts.length || !thread.fresh || ![parent.ts isEqualToString:threadTS] || !lastRead) return;
    NSString *mark = SentTS(thread.messages, ts, YES);
    if (!mark || SNCompareTS(mark, lastRead) != NSOrderedDescending) return;
    [self setLastRead:mark ofThread:thread inConversation:conversationID];
    [self scheduleMark:SNThreadKey(conversationID, threadTS) ts:mark];
}

/// A thread's read state is its parent's last_read (the thread's first message). Nothing shows
/// it, so the parent changes without announcing a change. nil removes it.
- (void)setLastRead:(NSString *)ts ofThread:(SNHistory *)thread inConversation:(NSString *)conversationID {
    SNMessage *held = thread.messages.firstObject;
    SNMessage *parent = [held messageByMergingJSON:@{@"last_read" : ts ?: NSNull.null}];
    [thread replace:held with:parent];
    [self.database putMessage:parent.json ts:parent.ts inConversation:conversationID thread:parent.ts];
}

- (void)scheduleMark:(NSString *)key ts:(NSString *)ts {
    BOOL waiting = self.marks[key] != nil;
    if (waiting && SNCompareTS(self.marks[key], ts) == NSOrderedDescending) return;
    self.marks[key] = ts;
    if (waiting) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.markDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendMark:key priority:SNCallBackground completion:nil];
    });
}

- (void)sendMark:(NSString *)key priority:(SNCallPriority)priority completion:(void (^)(void))completion {
    NSString *ts = self.marks[key];
    [self.marks removeObjectForKey:key];
    NSRange slash = [key rangeOfString:@"/"];
    NSString *lastRead = slash.location == NSNotFound ? self.conversationsByID[key].lastRead : nil;
    // Gone, or Slack's mark moved past it meanwhile (read on another device).
    if (!ts || (lastRead && SNCompareTS(lastRead, ts) == NSOrderedDescending)) {
        if (completion) completion();
        return;
    }
    SNAPICompletion answered = ^(NSDictionary *response, NSError *error) {
        if (completion) completion();
    };
    if (slash.location == NSNotFound) {
        [self request:@"conversations.mark" params:@{@"channel" : key, @"ts" : ts, @"_x_reason" : @"viewed"} priority:priority completion:answered];
        return;
    }
    NSDictionary *params = @{@"channel" : [key substringToIndex:slash.location], @"thread_ts" : [key substringFromIndex:NSMaxRange(slash)],
                             @"ts" : ts, @"read" : @"1", @"_x_reason" : @"viewed"};
    [self request:@"subscriptions.thread.mark" params:params priority:priority completion:answered];
}

- (void)flushReadMarks:(void (^)(void))completion {
    NSArray<NSString *> *keys = self.marks.allKeys;
    __block NSUInteger waiting = keys.count;
    if (!waiting) {
        if (completion) completion();
        return;
    }
    // At quit nothing else is waiting on the network: the user's own priority, no spacing.
    for (NSString *key in keys)
        [self sendMark:key priority:SNCallUserFacing completion:^{
            if (--waiting == 0 && completion) completion();
        }];
}

- (void)markConversation:(NSString *)conversationID unreadFrom:(SNMessage *)message {
    SNConversation *conversation = self.conversationsByID[conversationID];
    SNHistory *history = [self historyOf:conversationID];
    if (!conversation || !history) return;
    // The mark goes on the message before it that Slack has: one held, else one cached, else
    // "0000000000.000000" when nothing comes before it at all.
    NSString *before = SentTS(history.messages, message.ts, NO);
    if (!before) {
        NSMutableArray<SNMessage *> *cached = [NSMutableArray new];
        for (NSDictionary *json in [self.database messagesInConversation:conversationID thread:nil before:message.ts limit:10]) {
            SNMessage *row = [SNMessage messageWithJSON:json conversationID:conversationID];
            if (row) [cached addObject:row];
        }
        before = SentTS(cached, message.ts, NO);
    }
    if (!before && !history.olderOnDisk && !history.olderOnServer) before = @"0000000000.000000";
    if (!before) return;
    [self.marks removeObjectForKey:conversationID];
    [self.readKnown addObject:conversationID];
    NSDictionary *was = @{@"last_read" : conversation.lastRead ?: NSNull.null, @"has_unreads" : @(conversation.hasUnreads)};
    [self performChanges:^{ [self setConversation:[conversation conversationByMergingJSON:@{@"last_read" : before, @"has_unreads" : @YES}]]; }];
    [self request:@"conversations.mark" params:@{@"channel" : conversationID, @"ts" : before, @"_x_reason" : @"setLastRead"}
        priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
            SNConversation *now = self.conversationsByID[conversationID];
            // Unless a later mark (here or from another device) moved it meanwhile.
            if (!error || ![now.lastRead isEqualToString:before]) return;
            [self performChanges:^{ [self setConversation:[now conversationByMergingJSON:was]]; }];
        }];
}

// Slack's client marks the thread read through the message before the reply (read=0), so the
// reply and those after it are unread; the parent comes before every reply.
- (void)markThread:(NSString *)threadTS inConversation:(NSString *)conversationID unreadFrom:(SNMessage *)reply {
    if (![reply.threadTS isEqualToString:threadTS] || SNCompareTS(reply.ts, threadTS) != NSOrderedDescending) return;
    NSString *key = SNThreadKey(conversationID, threadTS);
    SNHistory *thread = [self threadOf:key];
    NSString *before = SentTS(thread.messages, reply.ts, NO) ?: threadTS;
    BOOL holdsParent = [thread.messages.firstObject.ts isEqualToString:threadTS];
    NSString *wasRead = holdsParent ? SNJSONString(thread.messages[0].json, @"last_read") : nil;
    NSDictionary *wasCounts = self.threadCounts;
    NSDictionary *unread = SNJSONMerge(wasCounts, @{@"has_unreads" : @YES});
    [self.marks removeObjectForKey:key];
    [self performChanges:^{
        if (holdsParent) [self setLastRead:before ofThread:thread inConversation:conversationID];
        [self setThreadCountsJSON:unread];
    }];
    NSDictionary *params = @{@"channel" : conversationID, @"thread_ts" : threadTS, @"ts" : before, @"read" : @"0", @"_x_reason" : @"setLastRead"};
    [self request:@"subscriptions.thread.mark" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (!error) return;
        // Only what this mark set, not what a later mark or client.counts set.
        SNHistory *now = self.threads[key];
        [self performChanges:^{
            if ([SNJSONString(now.messages.firstObject.json, @"last_read") isEqualToString:before] && [now.messages.firstObject.ts isEqualToString:threadTS])
                [self setLastRead:wasRead ofThread:now inConversation:conversationID];
            if ([self.threadCounts isEqualToDictionary:unread]) [self setThreadCountsJSON:wasCounts];
        }];
    }];
}

#pragma mark Typing and drafts

- (void)userIsTypingInConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    NSString *key = threadTS ? SNThreadKey(conversationID, threadTS) : conversationID;
    NSDate *last = self.typingSent[key];
    // Slack's client repeats the typing frame about every 3 s while keys keep coming.
    if (last && -last.timeIntervalSinceNow < 3) return;
    self.typingSent[key] = NSDate.date;
    NSMutableDictionary *frame = [@{@"type" : @"typing", @"channel" : conversationID} mutableCopy];
    if (threadTS) frame[@"thread_ts"] = threadTS;
    if (self.frameSender) self.frameSender(frame);
}

- (NSString *)draftInConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    return self.drafts[threadTS ? SNThreadKey(conversationID, threadTS) : conversationID];
}

- (void)setDraft:(NSString *)text inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    NSString *key = threadTS ? SNThreadKey(conversationID, threadTS) : conversationID;
    NSString *value = text.length ? [text copy] : nil;
    if ((!value && !self.drafts[key]) || [value isEqualToString:self.drafts[key]]) return;
    [self performChanges:^{
        self.drafts[key] = value;
        [self.database setJSON:value forKey:[@"draft:" stringByAppendingString:key]];
        [self changed:SNChangeDrafts value:key];
    }];
}

#pragma mark The user's settings

- (void)setPreference:(NSString *)name value:(NSString *)value {
    [self performChanges:^{
        self.prefs = SNJSONMerge(self.prefs, @{name : value});
        [self savePreferences];
    }];
    [self request:@"users.prefs.set" params:@{@"name" : name, @"value" : value, @"_x_reason" : @"prefs-api/setUserPrefByApi"} priority:SNCallUserFacing completion:nil];
}

- (void)setPreferences:(NSDictionary<NSString *, NSString *> *)preferences {
    NSDictionary *before = self.prefs;
    [self performChanges:^{
        self.prefs = SNJSONMerge(self.prefs, preferences);
        [self savePreferences];
    }];
    [self request:@"users.prefs.set" params:@{@"prefs" : SNJSONText(preferences), @"_x_reason" : @"prefs-api/setMultipleUserPrefsByApi"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           if (!error) return;
           NSMutableDictionary *undone = [NSMutableDictionary new];
           for (NSString *name in preferences) undone[name] = before[name] ?: NSNull.null;
           [self performChanges:^{
               self.prefs = SNJSONMerge(self.prefs, undone);
               [self savePreferences];
           }];
       }];
}

/// all_notifications_prefs is a JSON object in a string; its "global" holds these.
- (void)setNotificationPreferences:(NSDictionary<NSString *, NSString *> *)preferences reason:(NSString *)reason {
    if (!preferences.count) return;
    id stored = self.prefs[@"all_notifications_prefs"];
    NSData *data = [stored isKindOfClass:NSString.class] ? [stored dataUsingEncoding:NSUTF8StringEncoding] : nil;
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : stored;
    NSDictionary *all = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
    NSMutableDictionary *global = [SNJSONObject(all, @"global") ?: @{} mutableCopy];
    NSMutableArray *list = [NSMutableArray new];
    for (NSString *name in [preferences.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value = preferences[name];
        global[name] = [value isEqualToString:@"true"] ? @YES : [value isEqualToString:@"false"] ? @NO : value;
        [list addObject:@{@"name" : name, @"value" : value}];
    }
    NSString *updated = SNJSONText(SNJSONMerge(all, @{@"global" : global}));
    [self performChanges:^{
        self.prefs = SNJSONMerge(self.prefs, @{@"all_notifications_prefs" : updated});
        [self savePreferences];
    }];
    NSMutableDictionary *params = [@{@"global" : @"true", @"sync" : @"false", @"_x_reason" : reason} mutableCopy];
    if (list.count == 1) [params addEntriesFromDictionary:@{@"name" : list[0][@"name"], @"value" : list[0][@"value"]}];
    else params[@"prefs"] = SNJSONText(list);
    [self request:@"users.prefs.setNotifications" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (!error) return;
        [self performChanges:^{
            self.prefs = SNJSONMerge(self.prefs, @{@"all_notifications_prefs" : stored ?: NSNull.null});
            [self savePreferences];
        }];
    }];
}

- (NSInteger)preferredSkinTone {
    NSInteger tone = SNJSONInteger(self.prefs, @"preferred_skin_tone");
    return tone >= 2 && tone <= 6 ? tone : 0;
}

- (void)setPreferredSkinTone:(NSInteger)tone {
    // Slack's Preferences keep "1" for the default yellow.
    [self setPreference:@"preferred_skin_tone" value:tone >= 2 && tone <= 6 ? @(tone).stringValue : @"1"];
}

/// emoji_use: a JSON object in a string, emoji name -> times used.
- (NSDictionary<NSString *, NSNumber *> *)emojiUse {
    NSData *data = [SNJSONString(self.prefs, @"emoji_use") dataUsingEncoding:NSUTF8StringEncoding];
    id use = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [use isKindOfClass:NSDictionary.class] ? use : @{};
}

- (NSArray<NSString *> *)frequentEmoji {
    NSDictionary<NSString *, NSNumber *> *use = [self emojiUse];
    return [use.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger countA = [use[a] respondsToSelector:@selector(integerValue)] ? [use[a] integerValue] : 0;
        NSInteger countB = [use[b] respondsToSelector:@selector(integerValue)] ? [use[b] integerValue] : 0;
        return countA != countB ? (countA > countB ? NSOrderedAscending : NSOrderedDescending) : [a compare:b];
    }];
}

- (void)noteEmojiUsed:(NSString *)name {
    NSString *base = [name componentsSeparatedByString:@"::"].firstObject;
    NSMutableDictionary *use = [[self emojiUse] mutableCopy];
    use[base] = @([use[base] respondsToSelector:@selector(integerValue)] ? [use[base] integerValue] + 1 : 1);
    [self performChanges:^{
        self.prefs = SNJSONMerge(self.prefs, @{@"emoji_use" : SNJSONText(use)});
        [self savePreferences];
    }];
    // Saved to Slack in one call per burst of picks.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveEmojiUse) object:nil];
    [self performSelector:@selector(saveEmojiUse) withObject:nil afterDelay:10 inModes:@[ NSRunLoopCommonModes ]];
}

- (void)saveEmojiUse {
    NSString *use = SNJSONString(self.prefs, @"emoji_use");
    if (use) [self request:@"users.prefs.set" params:@{@"name" : @"emoji_use", @"value" : use} priority:SNCallBackground completion:nil];
}

- (void)setSection:(NSString *)sectionID collapsed:(BOOL)collapsed {
    NSUInteger index = [self.sectionJSON indexOfObjectPassingTest:^BOOL(NSDictionary *json, NSUInteger i, BOOL *stop) {
        return [SNJSONString(json, @"channel_section_id") isEqualToString:sectionID];
    }];
    if (index == NSNotFound || SNJSONBool(self.sectionJSON[index], @"is_collapsed") == collapsed) return;
    [self performChanges:^{
        self.sectionJSON[index] = SNJSONMerge(self.sectionJSON[index], @{@"is_collapsed" : @(collapsed)});
        [self saveSections];
    }];
    [self request:@"users.channelSections.update" params:@{@"channel_section_id" : sectionID, @"is_collapsed" : collapsed ? @"true" : @"false"}
        priority:SNCallBackground completion:nil];
}

- (void)openDirectMessageWithUsers:(NSArray<NSString *> *)userIDs completion:(void (^)(NSString *))completion {
    if (userIDs.count == 1)
        for (SNConversation *conversation in self.conversationsByID.allValues)
            if (conversation.kind == SNConversationDirect && [conversation.userID isEqualToString:userIDs[0]] && conversation.isOpen) {
                completion(conversation.conversationID);
                return;
            }
    NSDictionary *params = @{@"users" : [userIDs componentsJoinedByString:@","], @"return_im" : @"true", @"_x_reason" : @"openDM"};
    [self request:@"conversations.open" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *channel = SNJSONObject(response, @"channel");
        NSString *conversationID = SNJSONString(channel, @"id");
        if (channel) [self applyConversations:@[ SNJSONMerge(channel, @{@"is_open" : @YES}) ]];
        completion(conversationID);
    }];
}

- (void)closeConversation:(NSString *)conversationID {
    SNConversation *conversation = self.conversationsByID[conversationID];
    if (!conversation.isDirect || !conversation.isOpen) return;
    [self performChanges:^{ [self setConversation:[conversation conversationByMergingJSON:@{@"is_open" : @NO}]]; }];
    [self request:@"conversations.close" params:@{@"channel" : conversationID, @"_x_reason" : @"closeDM"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           SNConversation *now = self.conversationsByID[conversationID];
           if (error && now && !now.isOpen) [self performChanges:^{ [self setConversation:[now conversationByMergingJSON:@{@"is_open" : @YES}]]; }];
       }];
}

/// presence.set, as Slack's client sets it from the user's menu; a refusal puts it back.
- (void)setMyPresence:(SNPresence)presence {
    NSString *meID = self.meID;
    if (!meID || presence == SNPresenceUnknown) return;
    SNPresence before = [self presenceOfUser:meID];
    [self performChanges:^{ [self setPresence:presence ofUser:meID]; }];
    [self request:@"presence.set" params:@{@"presence" : presence == SNPresenceAway ? @"away" : @"active"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           if (error && [self presenceOfUser:meID] == presence) [self performChanges:^{ [self setPresence:before ofUser:meID]; }];
       }];
}

- (void)setMyStatusText:(NSString *)text canonical:(NSString *)canonical emoji:(NSString *)emoji expiration:(NSTimeInterval)expiration {
    SNUser *me = self.me;
    if (!me) return;
    NSDictionary *status = @{@"status_text" : text, @"status_text_canonical" : canonical ?: NSNull.null, @"status_emoji" : emoji,
                             @"status_expiration" : @((long long)expiration)};
    NSDictionary *profile = SNJSONMerge(SNJSONObject(me.json, @"profile") ?: @{}, status);
    [self performChanges:^{ [self setUser:[me userByMergingJSON:@{@"profile" : profile}]]; }];
    [self request:@"users.profile.set" params:@{@"profile" : SNJSONText(status)} priority:SNCallUserFacing completion:nil];
}

@end
