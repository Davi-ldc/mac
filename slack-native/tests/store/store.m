// The store: optimistic writes reconciled with Slack's answers and the websocket's echo, events,
// history merging and paging, read marks (unread ones included, in read-only mode too), unknown
// users and conversations, lookups by handle and of cached messages, the SQLite cache across
// launches (and when it is unusable), and the bounds on decoded memory and on disk. Made-up data.
#import <mach/mach.h>
#import <objc/runtime.h>
#import <sqlite3.h>

#import "../net/stub.h"
#import "app/launch.h"
#import "model/json.h"
#import "net/client.h"
#import "net/switches.h"
#import "render/emoji.h"
#import "store/fixture.h"
#import "store/internal.h"
#import "test.h"

static NSURL *TemporaryDatabase(NSString *name) {
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [folder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"sqlite"]];
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ])
        [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    return url;
}

static NSDictionary *Message(NSString *ts, NSString *user, NSString *text) { return @{@"type" : @"message", @"ts" : ts, @"user" : user, @"text" : text}; }

/// A store with a workspace, two users and a channel and DM, over `database` (nil: memory).
static SNStore *Store(SNDatabase *database, id<SNAPI> api) {
    SNStore *store = [[SNStore alloc] initWithDatabase:database api:api];
    store.markDelay = 0.05;
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"real_name" : @"Alex Rivera", @"display_name" : @"alex"}},
                             @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"real_name" : @"Sam Chen", @"display_name" : @""}} ]];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES},
                                     @{@"id" : @"D05SAM", @"is_im" : @YES, @"user" : @"U02SAM"} ]];
    }];
    return store;
}

/// The changes `block` made, delivered once it returns.
static NSArray<SNChange *> *Changes(SNStore *store, void (^block)(void)) {
    NSMutableArray *changes = [NSMutableArray new];
    SNFlushChanges();
    id observer = SNObserveChanges(store, ^(SNChange *change) { [changes addObject:change]; });
    block();
    SNFlushChanges();
    SNStopObserving(observer);
    return changes;
}

SN_TEST(StoreImplementsEverySourceMethod) {
    unsigned count = 0;
    BOOL all = YES;
    for (int required = 0; required < 2; required++) {
        struct objc_method_description *methods = protocol_copyMethodDescriptionList(@protocol(SNSource), required, YES, &count);
        for (unsigned i = 0; i < count; i++)
            if (![SNStore instancesRespondToSelector:methods[i].name]) {
                printf("     missing -%s\n", sel_getName(methods[i].name));
                all = NO;
            }
        free(methods);
    }
    SNExpect(all, "SNStore implements all of SNSource");
}

SN_TEST(StoreReconcilesSendsWithTheAnswer) {
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (![method isEqualToString:@"chat.postMessage"]) return @{@"ok" : @YES};
        return @{@"ok" : @YES, @"ts" : @"1795500000.000200", @"message" : Message(@"1795500000.000200", @"U01ALEX", params[@"text"])};
    };
    SNStore *store = Store(nil, api);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400000.000100", @"U02SAM", @"hi") ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    __block SNMessage *pending;
    NSArray<SNChange *> *changes = Changes(store, ^{
        pending = [store sendText:@"hello *there*" blocks:@[ @{@"type" : @"rich_text", @"elements" : @[]} ] inConversation:@"C01GENERAL" threadTS:nil broadcast:NO];
    });
    SNExpect(pending.sendState == SNMessagePending && pending.clientMessageID.length == 36, "pending with a client_msg_id");
    SNExpect([store messagesInConversation:@"C01GENERAL"].lastObject == pending, "shown at once at the end");
    SNExpect([changes.firstObject.messageKeys containsObject:SNMessageKey(pending)], "the row's key is announced");
    NSDictionary *params = api.calls.lastObject[1];
    SNExpect([params[@"client_msg_id"] isEqualToString:pending.clientMessageID] && [params[@"blocks"] hasPrefix:@"[{"], "posted with its id and blocks");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].lastObject.sendState == SNMessageSent; }), "confirmed");
    SNMessage *sent = [store messagesInConversation:@"C01GENERAL"].lastObject;
    SNExpect([sent.ts isEqualToString:@"1795500000.000200"] && [sent.identifier isEqualToString:pending.identifier], "server ts, same identifier");
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 2, "replaced, not duplicated");
    [store applyEvent:SNJSONMerge(Message(@"1795500000.000200", @"U01ALEX", @"hello *there*"), @{@"channel" : @"C01GENERAL", @"client_msg_id" : pending.clientMessageID})];
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 2, "the late echo changes nothing");
    SNExpect(![store conversationWithID:@"C01GENERAL"].hasUnreads, "posting reads the conversation");
}

SN_TEST(StoreReconcilesSendsWithAnEarlyEcho) {
    SNTestAPI *api = [SNTestAPI new];
    api.holds = YES;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return @{@"ok" : @YES, @"ts" : @"1795500000.000300", @"message" : Message(@"1795500000.000300", @"U01ALEX", params[@"text"] ?: @"")};
    };
    SNStore *store = Store(nil, api);
    SNMessage *pending = [store sendText:@"echo first" blocks:nil inConversation:@"D05SAM" threadTS:nil broadcast:NO];
    [store applyEvent:SNJSONMerge(Message(@"1795500000.000300", @"U01ALEX", @"echo first"), @{@"channel" : @"D05SAM", @"client_msg_id" : pending.clientMessageID})];
    NSArray<SNMessage *> *messages = [store messagesInConversation:@"D05SAM"];
    SNExpect(messages.count == 1 && messages[0].sendState == SNMessageSent && [messages[0].ts isEqualToString:@"1795500000.000300"], "the echo confirms it");
    for (dispatch_block_t reply in api.held) reply();
    SNExpect([store messagesInConversation:@"D05SAM"].count == 1, "the answer after the echo changes nothing");
}

SN_TEST(StoreFailsAndRetriesSends) {
    SNTestAPI *api = [SNTestAPI new];
    __block BOOL down = YES;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (down) return nil;
        return @{@"ok" : @YES, @"message" : Message(@"1795500000.000400", @"U01ALEX", params[@"text"])};
    };
    SNStore *store = Store(nil, api);
    SNMessage *pending = [store sendText:@"try" blocks:nil inConversation:@"D05SAM" threadTS:nil broadcast:NO];
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"D05SAM"].lastObject.sendState == SNMessageFailed; }), "failed when Slack is unreachable");
    down = NO;
    [store retrySendingMessage:[store messagesInConversation:@"D05SAM"].lastObject];
    SNExpect([store messagesInConversation:@"D05SAM"].lastObject.sendState == SNMessagePending, "pending again at once");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"D05SAM"].lastObject.sendState == SNMessageSent; }), "sent on retry");
    SNExpect([[store messagesInConversation:@"D05SAM"].lastObject.identifier isEqualToString:pending.identifier], "the same message");
    down = YES;
    SNMessage *failed = [store sendText:@"drop me" blocks:nil inConversation:@"D05SAM" threadTS:nil broadcast:NO];
    SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"D05SAM"].lastObject.sendState != SNMessagePending; });
    NSUInteger calls = api.calls.count;
    [store deleteMessage:[store messagesInConversation:@"D05SAM"].lastObject];
    SNExpect(![[[store messagesInConversation:@"D05SAM"] valueForKey:@"identifier"] containsObject:failed.identifier] && api.calls.count == calls,
             "deleting an unsent message never calls Slack");
}

SN_TEST(StoreRevertsFailedEditsAndReactions) {
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return nil; };
    SNStore *store = Store(nil, api);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400000.000100", @"U01ALEX", @"original") ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    SNMessage *message = [store messagesInConversation:@"C01GENERAL"].lastObject;
    [store editMessage:message text:@"edited" blocks:nil];
    SNExpect([[store messagesInConversation:@"C01GENERAL"].lastObject.text isEqualToString:@"edited"] &&
                 [store messagesInConversation:@"C01GENERAL"].lastObject.editedTS,
             "edit shows at once");
    [store toggleReaction:@"+1::skin-tone-3" onMessage:message];
    SNExpect([store messagesInConversation:@"C01GENERAL"].lastObject.reactions.firstObject.count == 1, "reaction shows at once");
    SNExpect(SNWaitUntil(1, ^BOOL {
                 SNMessage *now = [store messagesInConversation:@"C01GENERAL"].lastObject;
                 return [now.text isEqualToString:@"original"] && now.reactions.count == 0;
             }),
             "both reverted when Slack refuses");
    SNExpect([store messagesInConversation:@"C01GENERAL"].lastObject.editedTS == nil, "edited mark reverted");
    SNExpect([store.frequentEmoji containsObject:@"+1"], "a reaction counts toward frequent emoji, without the skin tone");
}

SN_TEST(StoreAppliesEvents) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(nil, api);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400000.000100", @"U02SAM", @"first") ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400000.000100", @"latest" : @"1795400000.000100",
                                            @"has_unreads" : @NO, @"mention_count" : @0} ]}];
    NSArray<SNChange *> *changes = Changes(store, ^{
        [store applyEvent:SNJSONMerge(Message(@"1795400100.000100", @"U02SAM", @"hey <@U01ALEX>"), @{@"channel" : @"C01GENERAL"})];
    });
    SNConversation *general = [store conversationWithID:@"C01GENERAL"];
    SNExpect(general.hasUnreads && general.mentionCount == 1, "a mention counts");
    SNExpect([changes.firstObject.counts containsObject:@"C01GENERAL"], "counts change announced");
    [store applyEvent:@{@"type" : @"reaction_added", @"user" : @"U02SAM", @"reaction" : @"eyes", @"item" : @{@"type" : @"message", @"channel" : @"C01GENERAL", @"ts" : @"1795400000.000100"}}];
    [store applyEvent:@{@"type" : @"reaction_added", @"user" : @"U02SAM", @"reaction" : @"eyes", @"item" : @{@"type" : @"message", @"channel" : @"C01GENERAL", @"ts" : @"1795400000.000100"}}];
    SNExpect([store messagesInConversation:@"C01GENERAL"].firstObject.reactions.firstObject.count == 1, "a repeated reaction event counts once");
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_changed", @"channel" : @"C01GENERAL",
                        @"message" : SNJSONMerge(Message(@"1795400000.000100", @"U02SAM", @"first, edited"), @{@"edited" : @{@"user" : @"U02SAM", @"ts" : @"1795400200.000000"}})}];
    SNMessage *edited = [store messagesInConversation:@"C01GENERAL"].firstObject;
    SNExpect([edited.text isEqualToString:@"first, edited"] && edited.reactions.count == 1, "edits keep reactions the event left out");
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_deleted", @"channel" : @"C01GENERAL", @"deleted_ts" : @"1795400100.000100"}];
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 1, "deleted");
    [store applyEvent:@{@"type" : @"channel_marked", @"channel" : @"C01GENERAL", @"ts" : @"1795400100.000100"}];
    SNExpect(![store conversationWithID:@"C01GENERAL"].hasUnreads && [store conversationWithID:@"C01GENERAL"].mentionCount == 0, "marked read elsewhere");

    [store applyEvent:@{@"type" : @"user_typing", @"channel" : @"D05SAM", @"user" : @"U02SAM"}];
    SNExpect([[store typingUserIDsInConversation:@"D05SAM" threadTS:nil] isEqualToArray:@[ @"U02SAM" ]], "typing");
    [store applyEvent:SNJSONMerge(Message(@"1795400300.000100", @"U02SAM", @"done typing"), @{@"channel" : @"D05SAM"})];
    SNExpect([store typingUserIDsInConversation:@"D05SAM" threadTS:nil].count == 0, "their message ends the typing");
    SNExpect([store conversationWithID:@"D05SAM"].mentionCount == 1, "every DM message counts");

    [store applyEvent:@{@"type" : @"presence_change", @"users" : @[ @"U01ALEX", @"U02SAM" ], @"presence" : @"away"}];
    SNExpect([store presenceOfUser:@"U02SAM"] == SNPresenceAway && [store presenceOfUser:store.me.userID] == SNPresenceAway, "batched presence");
    [store applyEvent:@{@"type" : @"user_change", @"user" : @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"real_name" : @"Sam C.", @"status_emoji" : @":palm_tree:"}}}];
    SNExpect([[store userWithID:@"U02SAM"].statusEmoji isEqualToString:@":palm_tree:"] && [store presenceOfUser:@"U02SAM"] == SNPresenceAway,
             "profile changes keep presence");
    [store applyEvent:@{@"type" : @"pref_change", @"name" : @"muted_channels", @"value" : @"C01GENERAL"}];
    SNExpect([store conversationWithID:@"C01GENERAL"].isMuted, "muting through prefs");
    [store applyEvent:@{@"type" : @"emoji_changed", @"subtype" : @"add", @"name" : @"partyparrot", @"value" : @"https://emoji.example.com/parrot.gif"}];
    [store applyEvent:@{@"type" : @"emoji_changed", @"subtype" : @"add", @"name" : @"parrot", @"value" : @"alias:partyparrot"}];
    [store applyEvent:@{@"type" : @"emoji_changed", @"subtype" : @"add", @"name" : @"thumbs", @"value" : @"alias:+1"}];
    SNExpect([SNCustomEmojiURL(@"parrot").absoluteString hasSuffix:@"parrot.gif"] && [SNEmojiUnicode(@"thumbs") isEqualToString:SNEmojiUnicode(@"+1")],
             "custom emoji and aliases go to render/emoji.h");
    [store applyEvent:@{@"type" : @"emoji_changed", @"subtype" : @"remove", @"names" : @[ @"parrot" ]}];
    SNExpect(!SNCustomEmojiURL(@"parrot") && SNCustomEmojiURL(@"partyparrot"), "removals too");

    NSArray<SNChange *> *groupChanges = Changes(store, ^{
        [store applyUsergroups:@[ @{@"id" : @"S01DESIGN", @"handle" : @"designers"}, @{@"id" : @"S02NOHANDLE"} ]];
    });
    SNExpect([[store usergroupHandleWithID:@"S01DESIGN"] isEqualToString:@"designers"] && ![store usergroupHandleWithID:@"S02NOHANDLE"], "usergroup handles");
    SNExpect(groupChanges.count == 1 && [groupChanges[0].usergroups isEqualToSet:[NSSet setWithObject:@"S01DESIGN"]], "posted by ID");
    [store applyEvent:@{@"type" : @"subteam_updated", @"subteam" : @{@"id" : @"S01DESIGN", @"handle" : @"design-crew"}}];
    SNExpect([[store usergroupHandleWithID:@"S01DESIGN"] isEqualToString:@"design-crew"], "renamed by subteam_updated");
}

SN_TEST(StoreCountsThreadReplies) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(nil, api);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400000.000100", @"U02SAM", @"parent") ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    SNExpect([store threadInConversation:@"C01GENERAL" ts:@"1795400000.000100"].count == 1, "a thread shows its parent before replies load");
    NSDictionary *reply = SNJSONMerge(Message(@"1795400100.000100", @"U02SAM", @"reply"), @{@"channel" : @"C01GENERAL", @"thread_ts" : @"1795400000.000100"});
    [store applyEvent:reply];
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_replied", @"channel" : @"C01GENERAL",
                        @"message" : SNJSONMerge(Message(@"1795400000.000100", @"U02SAM", @"parent"),
                                                 @{@"thread_ts" : @"1795400000.000100", @"reply_count" : @1, @"latest_reply" : @"1795400100.000100", @"reply_users" : @[ @"U02SAM" ]})}];
    SNMessage *parent = [store messagesInConversation:@"C01GENERAL"].firstObject;
    SNExpect(parent.replyCount == 1 && [parent.replyUserIDs isEqualToArray:@[ @"U02SAM" ]], "the reply bar counts the reply once");
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 1, "replies stay out of the channel");
    SNExpect([store threadInConversation:@"C01GENERAL" ts:@"1795400000.000100"].count == 2, "the reply joins the thread");
}

SN_TEST(StoreMergesHistoryPages) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(nil, api);
    NSMutableArray *page = [NSMutableArray new];
    for (int i = 50; i > 8; i--) [page addObject:Message([NSString stringWithFormat:@"17954%05d.000100", i], @"U02SAM", @"m")];
    [store applyNewestHistory:@{@"messages" : page, @"has_more" : @YES} inConversation:@"C01GENERAL"];
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 42 && [store hasOlderMessagesInConversation:@"C01GENERAL"], "a page with more before it");
    NSMutableArray *newer = [NSMutableArray new];
    for (int i = 55; i > 45; i--)
        if (i != 48) [newer addObject:Message([NSString stringWithFormat:@"17954%05d.000100", i], @"U02SAM", i == 47 ? @"edited" : @"m")];
    [store applyNewestHistory:@{@"messages" : newer, @"has_more" : @YES} inConversation:@"C01GENERAL"];
    NSArray<SNMessage *> *messages = [store messagesInConversation:@"C01GENERAL"];
    SNExpect(messages.count == 46, "an overlapping page replaces what it covers");
    SNExpect(![[messages valueForKey:@"ts"] containsObject:@"1795400048.000100"], "a message missing from the page was deleted");
    NSMutableArray *far = [NSMutableArray new];
    for (int i = 99; i > 90; i--) [far addObject:Message([NSString stringWithFormat:@"17954%05d.000100", i], @"U02SAM", @"m")];
    [store applyNewestHistory:@{@"messages" : far, @"has_more" : @YES} inConversation:@"C01GENERAL"];
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 9 && [store hasOlderMessagesInConversation:@"C01GENERAL"], "a page past a gap replaces the cache");
}

SN_TEST(StoreFillsGapsFromTheCachedLatest) {
    SNTestAPI *api = [SNTestAPI new];
    __block BOOL more = NO;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        NSMutableArray *after = [NSMutableArray new];
        for (NSString *ts in @[ @"1795400600.000100", @"1795400500.000100", @"1795400400.000100" ])
            if (params[@"oldest"] && SNCompareTS(ts, params[@"oldest"]) == NSOrderedDescending && (more || ![ts isEqualToString:@"1795400600.000100"]))
                [after addObject:Message(ts, @"U02SAM", @"new")];
        return @{@"ok" : @YES, @"messages" : after, @"has_more" : @(more), @"response_metadata" : @{@"next_cursor" : @""}};
    };
    SNStore *store = Store(nil, api);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400200.000100", @"U02SAM", @"b"), Message(@"1795400100.000100", @"U02SAM", @"a") ], @"has_more" : @YES}
               inConversation:@"C01GENERAL"];
    [store refreshConversation:@"C01GENERAL" priority:SNCallBackground];
    SNExpect([api.calls.lastObject[1][@"oldest"] isEqualToString:@"1795400200.000100"], "asks for what came after the cached latest");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].count == 4; }), "the new messages join the cache");
    SNExpect([store hasOlderMessagesInConversation:@"C01GENERAL"], "older history still known to exist");
    more = YES;
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_deleted", @"channel" : @"C01GENERAL", @"deleted_ts" : @"1795400500.000100"}];
    [store refreshConversation:@"C01GENERAL" priority:SNCallBackground];
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].count == 2; }) &&
                 [[store messagesInConversation:@"C01GENERAL"].firstObject.ts isEqualToString:@"1795400500.000100"],
             "a gap too large to bridge replaces the cache");
}

SN_TEST(StoreDebouncesReadMarks) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(nil, api);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400300.000100", @"U02SAM", @"b"), Message(@"1795400100.000100", @"U02SAM", @"a") ], @"has_more" : @NO}
               inConversation:@"C01GENERAL"];
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400000.000100", @"latest" : @"1795400300.000100",
                                            @"has_unreads" : @YES, @"mention_count" : @2} ]}];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400100.000100"];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400300.000100"];
    SNExpect(![store conversationWithID:@"C01GENERAL"].hasUnreads && [store conversationWithID:@"C01GENERAL"].mentionCount == 0, "read at once");
    SNExpect(![api.methods containsObject:@"conversations.mark"], "not sent yet");
    SNExpect(SNWaitUntil(1, ^BOOL { return [api.methods containsObject:@"conversations.mark"]; }), "sent after the delay");
    NSUInteger marks = 0;
    for (NSArray *call in api.calls)
        if ([call[0] isEqualToString:@"conversations.mark"]) {
            marks++;
            SNExpect([call[1][@"ts"] isEqualToString:@"1795400300.000100"], "the latest mark wins");
        }
    SNExpect(marks == 1, "one call for both marks");
}

/// conversations.mark calls' ts, in order.
static NSArray<NSString *> *MarksSent(SNTestAPI *api, NSString *method) {
    NSMutableArray *marks = [NSMutableArray new];
    for (NSArray *call in api.calls)
        if ([call[0] isEqualToString:method]) [marks addObject:call[1][@"ts"]];
    return marks;
}

SN_TEST(StoreMarksOnlyWhatSlackHas) {
    NSURL *url = TemporaryDatabase(@"marks");
    @autoreleasepool {
        SNStore *earlier = Store([SNDatabase databaseAtURL:url], nil);
        [earlier applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400100.000100", @"latest" : @"1795400200.000100", @"has_unreads" : @YES} ]}];
    }
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return [method isEqualToString:@"chat.postMessage"] ? nil : @{@"ok" : @YES}; };
    SNStore *store = Store([SNDatabase databaseAtURL:url], api);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400200.000100", @"U02SAM", @"b"), Message(@"1795400100.000100", @"U02SAM", @"a") ], @"has_more" : @NO}
               inConversation:@"C01GENERAL"];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400200.000100"];
    SNExpect([[store conversationWithID:@"C01GENERAL"].lastRead isEqualToString:@"1795400100.000100"], "a last_read known only from the cache is not built on");
    [store markConversation:@"D05SAM" readThrough:@"1795400200.000100"];
    SNExpect(![store conversationWithID:@"D05SAM"].lastRead, "nor an unknown one");

    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400100.000100", @"latest" : @"1795400200.000100", @"has_unreads" : @YES} ]}];
    [store markConversation:@"C01GENERAL" readThrough:@"0"];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400100.000100"];
    SNExpect([store conversationWithID:@"C01GENERAL"].hasUnreads, "\"0\" and a ts not past Slack's last_read mark nothing");
    SNMessage *pending = [store sendText:@"not on Slack yet" blocks:nil inConversation:@"C01GENERAL" threadTS:nil broadcast:NO];
    SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].lastObject.sendState == SNMessageFailed; });
    [store markConversation:@"C01GENERAL" readThrough:pending.ts];
    SNExpect([[store conversationWithID:@"C01GENERAL"].lastRead isEqualToString:@"1795400200.000100"], "a local ts reads through the newest message Slack has");
    SNExpect(SNWaitUntil(1, ^BOOL { return MarksSent(api, @"conversations.mark").count == 1; }) &&
                 [MarksSent(api, @"conversations.mark")[0] isEqualToString:@"1795400200.000100"],
             "and that is what Slack is sent");
    [store markConversation:@"C01GENERAL" readThrough:@"1795400100.000100"];
    SNSettle(0.15);
    SNExpect(MarksSent(api, @"conversations.mark").count == 1, "an older mark never goes back");

    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400100.000100", @"latest" : @"1795400200.000100", @"has_unreads" : @YES} ]}];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400200.000100"];
    [store applyEvent:@{@"type" : @"channel_marked", @"channel" : @"C01GENERAL", @"ts" : @"1795400300.000100"}];
    SNSettle(0.15);
    SNExpect(MarksSent(api, @"conversations.mark").count == 1, "a mark overtaken by one from another device is dropped");

    NSDictionary *parent = SNJSONMerge(Message(@"1795400200.000100", @"U02SAM", @"b"), @{@"thread_ts" : @"1795400200.000100", @"reply_count" : @2,
                                                                                        @"subscribed" : @YES, @"last_read" : @"1795400210.000100"});
    [store applyReplies:@{@"messages" : @[ parent, SNJSONMerge(Message(@"1795400210.000100", @"U02SAM", @"r1"), @{@"thread_ts" : @"1795400200.000100"}),
                                           SNJSONMerge(Message(@"1795400220.000100", @"U02SAM", @"r2"), @{@"thread_ts" : @"1795400200.000100"}) ]}
                 thread:@"1795400200.000100" inConversation:@"C01GENERAL"];
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" readThrough:@"1795400210.000100"];
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" readThrough:@"9999999999.000000"];
    SNExpect(SNWaitUntil(1, ^BOOL { return MarksSent(api, @"subscriptions.thread.mark").count == 1; }) &&
                 [MarksSent(api, @"subscriptions.thread.mark")[0] isEqualToString:@"1795400220.000100"],
             "a followed thread is marked through its newest reply, past its last_read");
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" readThrough:@"1795400220.000100"];
    [store applyReplies:@{@"messages" : @[ Message(@"1795400100.000100", @"U02SAM", @"a"),
                                           SNJSONMerge(Message(@"1795400110.000100", @"U02SAM", @"r"), @{@"thread_ts" : @"1795400100.000100"}) ]}
                 thread:@"1795400100.000100" inConversation:@"C01GENERAL"];
    [store markThread:@"1795400100.000100" inConversation:@"C01GENERAL" readThrough:@"1795400110.000100"];
    SNSettle(0.15);
    SNExpect(MarksSent(api, @"subscriptions.thread.mark").count == 1, "once, and never for a thread without a last_read (not followed)");
}

SN_TEST(StoreFlushesReadMarksBeforeQuitting) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(nil, api);
    store.markDelay = 60;
    __block BOOL flushed = NO;
    [store flushReadMarks:^{ flushed = YES; }];
    SNExpect(flushed, "nothing waiting: done at once");
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400300.000100", @"U02SAM", @"b") ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400000.000100", @"latest" : @"1795400300.000100", @"has_unreads" : @YES} ]}];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400300.000100"];
    flushed = NO;
    [store flushReadMarks:^{ flushed = YES; }];
    SNExpect([MarksSent(api, @"conversations.mark") isEqualToArray:@[ @"1795400300.000100" ]], "a waiting mark goes out at once");
    SNExpect(!flushed && SNWaitUntil(1, ^BOOL { return flushed; }), "done when Slack answered it");
}

/// 130 messages in a conversation, served like conversations.history: newest first, after
/// `oldest`, `limit` a page with the offset as the cursor.
static NSDictionary *HistoryPage(NSDictionary *params) {
    NSMutableArray *range = [NSMutableArray new];
    for (int i = 130; i > 0; i--) {
        NSString *ts = [NSString stringWithFormat:@"17954%05d.000100", i];
        if (!params[@"oldest"] || SNCompareTS(ts, params[@"oldest"]) == NSOrderedDescending) [range addObject:Message(ts, @"U02SAM", @"m")];
    }
    NSInteger limit = [params[@"limit"] integerValue], offset = [params[@"cursor"] integerValue];
    NSInteger end = MIN((NSInteger)range.count, offset + limit);
    BOOL more = end < (NSInteger)range.count;
    return @{@"ok" : @YES, @"messages" : [range subarrayWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)(end - offset))], @"has_more" : @(more),
             @"response_metadata" : @{@"next_cursor" : more ? @(end).stringValue : @""}};
}

SN_TEST(StoreFollowsCursorsPastTheFirstPage) {
    SNTestAPI *api = [SNTestAPI new];
    NSString *parentTS = @"1795400005.000100";
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"conversations.history"]) return HistoryPage(params);
        // 250 replies, 200 a page, each page led by the parent as Slack may send it.
        NSDictionary *parent = SNJSONMerge(Message(parentTS, @"U02SAM", @"parent"), @{@"thread_ts" : parentTS, @"reply_count" : @250});
        NSInteger offset = [params[@"cursor"] integerValue], end = MIN(250, offset + 200);
        NSMutableArray *page = [NSMutableArray arrayWithObject:parent];
        for (NSInteger i = offset; i < end; i++)
            [page addObject:SNJSONMerge(Message([NSString stringWithFormat:@"17955%05ld.000100", (long)i], @"U03PRIYA", @"reply"), @{@"thread_ts" : parentTS})];
        return @{@"ok" : @YES, @"messages" : page, @"has_more" : @(end < 250), @"response_metadata" : @{@"next_cursor" : end < 250 ? @(end).stringValue : @""}};
    };
    SNStore *store = Store(nil, api);
    NSMutableArray *cached = [NSMutableArray new];
    for (int i = 10; i > 0; i--) [cached addObject:Message([NSString stringWithFormat:@"17954%05d.000100", i], @"U02SAM", @"m")];
    [store applyNewestHistory:@{@"messages" : cached, @"has_more" : @NO} inConversation:@"C01GENERAL"];
    [store refreshConversation:@"C01GENERAL" priority:SNCallBackground];
    SNExpect(SNWaitUntil(2, ^BOOL { return ![store isLoadingMessagesInConversation:@"C01GENERAL"]; }) &&
                 [store messagesInConversation:@"C01GENERAL"].count == 130,
             "a gap of 120 messages is filled from three pages (42 each) through their cursors");
    NSUInteger pages = 0;
    for (NSArray *call in api.calls) pages += [call[0] isEqualToString:@"conversations.history"];
    SNExpect(pages == 3, "one call per page");
    [store loadThread:parentTS inConversation:@"C01GENERAL"];
    SNExpect(SNWaitUntil(2, ^BOOL { return [store threadInConversation:@"C01GENERAL" ts:parentTS].count == 251; }),
             "a thread of 250 replies comes whole from two pages, its parent once");
}

SN_TEST(StoreAppliesEventsWithoutDecodingTheCache) {
    NSURL *url = TemporaryDatabase(@"events");
    SNStore *store = Store([SNDatabase databaseAtURL:url], nil);
    store.decodedLimit = 2;
    [store applyConversations:@[ @{@"id" : @"C02RANDOM", @"name" : @"random", @"is_member" : @YES}, @{@"id" : @"C03QUIET", @"name" : @"quiet", @"is_member" : @YES} ]];
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400200.000100", @"U02SAM", @"b"), Message(@"1795400100.000100", @"U02SAM", @"a") ], @"has_more" : @NO}
               inConversation:@"C01GENERAL"];
    for (NSString *other in @[ @"C02RANDOM", @"C03QUIET" ])
        [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400100.000100", @"U02SAM", @"x") ], @"has_more" : @NO} inConversation:other];
    SNExpect(![store isDecoded:@"C01GENERAL"], "the conversation left decoded memory");
    NSUInteger decoded = store.decodedCount;
    [store applyEvent:SNJSONMerge(Message(@"1795400300.000100", @"U02SAM", @"live"), @{@"channel" : @"C01GENERAL"})];
    [store applyEvent:@{@"type" : @"reaction_added", @"user" : @"U02SAM", @"reaction" : @"eyes", @"item" : @{@"type" : @"message", @"channel" : @"C01GENERAL", @"ts" : @"1795400200.000100"}}];
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_changed", @"channel" : @"C01GENERAL",
                        @"message" : SNJSONMerge(Message(@"1795400100.000100", @"U02SAM", @"a, edited"), @{@"edited" : @{@"user" : @"U02SAM", @"ts" : @"1795400400.000000"}})}];
    [store applyEvent:SNJSONMerge(Message(@"1795400500.000100", @"U01ALEX", @"a reply"), @{@"channel" : @"C01GENERAL", @"thread_ts" : @"1795400200.000100"})];
    SNExpect(![store isDecoded:@"C01GENERAL"] && store.decodedCount == decoded, "message, reaction, edit and reply events decode nothing");
    SNExpect([[store latestMessageInConversation:@"C01GENERAL"].text isEqualToString:@"live"], "the new message is the latest");
    NSArray<SNMessage *> *messages = [store messagesInConversation:@"C01GENERAL"];
    SNExpect(messages.count == 3 && [messages[0].text isEqualToString:@"a, edited"] && [messages[1].reactions.firstObject.name isEqualToString:@"eyes"] &&
                 messages[1].replyCount == 1,
             "all of it is in the cache when the conversation is read again");
    SNExpect([store threadInConversation:@"C01GENERAL" ts:@"1795400200.000100"].count == 2, "the reply started the thread from its cached parent");
}

/// A page of `count` messages, newest first.
static NSArray *Page(int count) {
    NSMutableArray *page = [NSMutableArray new];
    for (int i = count; i > 0; i--) [page addObject:Message([NSString stringWithFormat:@"17954%05d.000100", i], @"U02SAM", @"x")];
    return page;
}

SN_TEST(StoreKeepsWhatIsShownDecoded) {
    NSURL *url = TemporaryDatabase(@"shown");
    SNStore *store = Store([SNDatabase databaseAtURL:url], nil);
    store.decodedLimit = 2;
    NSMutableArray *others = [NSMutableArray new];
    for (int c = 0; c < 6; c++) [others addObject:@{@"id" : [NSString stringWithFormat:@"C9%d", c], @"name" : @"c", @"is_member" : @YES}];
    [store applyConversations:others];
    [store applyNewestHistory:@{@"messages" : Page(100), @"has_more" : @NO} inConversation:@"C01GENERAL"];
    [store applyNewestHistory:@{@"messages" : Page(1), @"has_more" : @NO} inConversation:@"C90"];
    [store applyNewestHistory:@{@"messages" : Page(1), @"has_more" : @NO} inConversation:@"C91"];
    [store loadConversation:@"C01GENERAL"];
    [store loadOlderMessagesInConversation:@"C01GENERAL"];
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 100, "shown, with its older page loaded");
    for (NSDictionary *other in others) {
        [store applyNewestHistory:@{@"messages" : Page(1), @"has_more" : @NO} inConversation:other[@"id"]];
        [store messagesInConversation:other[@"id"]];
    }
    SNExpect([store isDecoded:@"C01GENERAL"] && [store messagesInConversation:@"C01GENERAL"].count == 100,
             "however many others are used, what is shown stays decoded with every page");
    SNExpect(store.decodedCount <= store.decodedLimit + 1, "the rest keeps the bound");
}

SN_TEST(StoreCapsWhatItKeepsOnDisk) {
    NSURL *url = TemporaryDatabase(@"cap");
    SNStore *store = Store([SNDatabase databaseAtURL:url], nil);
    store.decodedLimit = 1;
    store.storedMessageLimit = 50;
    [store applyNewestHistory:@{@"messages" : Page(120), @"has_more" : @NO} inConversation:@"C01GENERAL"];
    SNExpect([store messagesInConversation:@"C01GENERAL"].count == 120 && ![store hasOlderMessagesInConversation:@"C01GENERAL"], "all of it while in memory");
    [store applyNewestHistory:@{@"messages" : Page(1), @"has_more" : @NO} inConversation:@"D05SAM"];
    SNExpect(![store isDecoded:@"C01GENERAL"], "out of memory");
    NSArray<SNMessage *> *messages = [store messagesInConversation:@"C01GENERAL"];
    SNExpect(messages.count == 50 && [messages.lastObject.ts isEqualToString:@"1795400120.000100"], "the newest 50 are kept on disk");
    SNExpect([store hasOlderMessagesInConversation:@"C01GENERAL"], "the rest is Slack's to page in again");
}

SN_TEST(StoreAsksForUnknownUsersNowAndThen) {
    SNStore *store = Store(nil, [SNTestAPI new]);
    store.missingDelay = 0.2;
    NSMutableArray<NSSet *> *asked = [NSMutableArray new];
    store.usersMissing = ^(NSSet<NSString *> *userIDs) { [asked addObject:userIDs]; };
    for (int i = 0; i < 50; i++) [store userWithID:@"U09GHOST"];
    SNSettle(0.05);
    SNExpect(asked.count == 1 && [asked[0] isEqualToSet:[NSSet setWithObject:@"U09GHOST"]], "fifty reads of an unknown user: one ask, outside any change");
    SNSettle(0.25);
    [store userWithID:@"U09GHOST"];
    SNSettle(0.05);
    SNExpect(asked.count == 2, "asked again once the wait passed");
    SNSettle(0.25);
    [store userWithID:@"U09GHOST"];
    SNSettle(0.05);
    SNExpect(asked.count == 2, "the wait doubles");
    [store applyUsers:@[ @{@"id" : @"U09GHOST", @"name" : @"ghost"} ]];
    [store userWithID:@"U09GHOST"];
    SNSettle(0.05);
    SNExpect(asked.count == 2 && [store userWithID:@"U09GHOST"], "known at last: never asked for again");
}

SN_TEST(StoreStartsFromItsCache) {
    NSURL *url = TemporaryDatabase(@"coldstart");
    @autoreleasepool {
        SNTestAPI *api = [SNTestAPI new];
        SNStore *store = Store([SNDatabase databaseAtURL:url], api);
        [store applySections:@[ @{@"channel_section_id" : @"L01", @"type" : @"channels", @"channel_ids_page" : @{@"channel_ids" : @[ @"C01GENERAL" ]}} ]];
        [store applyPreferences:@{@"preferred_skin_tone" : @"3"}];
        [store applyEmoji:@{@"wave2" : @"https://emoji.example.com/wave2.png"}];
        [store applyUsergroups:@[ @{@"id" : @"S01DESIGN", @"handle" : @"designers"} ]];
        [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400100.000100", @"U02SAM", @"newest"), Message(@"1795400000.000100", @"U02SAM", @"older") ],
                                    @"has_more" : @YES}
                   inConversation:@"C01GENERAL"];
        [store setDraft:@"half a thought" inConversation:@"D05SAM" threadTS:nil];
        api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return nil; };
        [store sendText:@"never answered" blocks:nil inConversation:@"C01GENERAL" threadTS:nil broadcast:NO];
    }
    NSDate *start = NSDate.date;
    SNStore *cold = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:nil];
    NSArray<SNMessage *> *messages = [cold messagesInConversation:@"C01GENERAL"];
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    SNExpect(cold.hasState && [cold.workspace.name isEqualToString:@"Northwind Studio"] && [cold.me.realName isEqualToString:@"Alex Rivera"],
             "workspace and user from disk");
    SNExpect(cold.sections.count == 1 && [cold conversationWithID:@"D05SAM"] && cold.preferredSkinTone == 3 && SNCustomEmojiURL(@"wave2") &&
                 [[cold usergroupHandleWithID:@"S01DESIGN"] isEqualToString:@"designers"],
             "sidebar, prefs, emoji and usergroups from disk");
    SNExpect(messages.count == 3 && [messages[1].text isEqualToString:@"newest"] && [cold hasOlderMessagesInConversation:@"C01GENERAL"], "history from disk");
    SNExpect(messages.lastObject.sendState == SNMessageFailed, "a send that never got its answer comes back failed");
    SNExpect([[cold draftInConversation:@"D05SAM" threadTS:nil] isEqualToString:@"half a thought"], "drafts from disk");
    printf("     cold start from the cache: %.1f ms\n", elapsed * 1000);

    SNStore *deferred = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:nil deferred:YES];
    [deferred attachToMainThread];
    SNExpect(deferred.hasState && [deferred.me.realName isEqualToString:@"Alex Rivera"], "deferred load has workspace and self");
    SNExpect([[deferred userWithID:@"U02SAM"].realName isEqualToString:@"Sam Chen"], "a user needed for the first frame reads on demand from SQLite");
    SNExpect(SNCustomEmojiURL(@"wave2") != nil && [[deferred draftInConversation:@"D05SAM" threadTS:nil] isEqualToString:@"half a thought"], "emoji and drafts ready before finish");
    [deferred finishLoadingCache];
    SNExpect([[deferred usergroupHandleWithID:@"S01DESIGN"] isEqualToString:@"designers"], "deferred tables load when finished");
}

SN_TEST(StoreDeferredCacheMergesWithLiveBoot) {
    NSURL *url = TemporaryDatabase(@"deferred-merge");
    NSDictionary *cachedActivity = @{
        @"key" : @"cached-act",
        @"feed_ts" : @"1795400010.000100",
        @"is_unread" : @YES,
        @"item" : @{@"type" : @"at_user", @"message" : @{@"channel" : @"C01GENERAL", @"ts" : @"1795400010.000100", @"author_user_id" : @"U02SAM"}}
    };
    NSDictionary *liveActivity = @{
        @"key" : @"live-act",
        @"feed_ts" : @"1795400099.000100",
        @"is_unread" : @YES,
        @"item" : @{@"type" : @"at_user", @"message" : @{@"channel" : @"C01GENERAL", @"ts" : @"1795400099.000100", @"author_user_id" : @"U02SAM"}}
    };
    NSDictionary *cachedCommand = @{@"name" : @"/oldcmd", @"type" : @"app", @"autocomplete" : @YES, @"desc" : @"Cached command"};
    NSDictionary *liveCommand = @{@"name" : @"/livecmd", @"type" : @"app", @"autocomplete" : @YES, @"desc" : @"Live command"};
    @autoreleasepool {
        SNDatabase *db = [SNDatabase databaseAtURL:url];
        SNStore *seed = Store(db, nil);
        [seed applyUsers:@[ @{@"id" : @"U03PRIYA", @"name" : @"priya", @"profile" : @{@"real_name" : @"Priya Patel"}} ]];
        [seed applyUsergroups:@[ @{@"id" : @"S01DESIGN", @"handle" : @"designers"} ]];
        [db setJSON:@{@"B01HOOK" : @{@"id" : @"B01HOOK", @"name" : @"Deploy Bot"}} forKey:@"bots"];
        [db setJSON:@{@"unreads_only" : @NO, @"items" : @[ cachedActivity ]} forKey:@"activity"];
        [db setJSON:@[ cachedCommand ] forKey:@"app_commands"];
    }

    // Reading bots, usergroups, handles and activity on frame 1 must not decode the entire users table.
    SNStore *deferred = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:nil deferred:YES];
    [deferred attachToMainThread];
    SNExpect([[deferred botWithID:@"B01HOOK"].name isEqualToString:@"Deploy Bot"], "bot loads on demand");
    SNExpect([[deferred usergroupHandleWithID:@"S01DESIGN"] isEqualToString:@"designers"], "usergroup loads on demand");
    SNExpect([[deferred userWithHandle:@"sam"].userID isEqualToString:@"U02SAM"], "handle loads on demand");
    SNExpect(deferred.usersCachePending && !deferred.users[@"U03PRIYA"], "on-demand lookups do not synchronously decode unrelated users");
    SNExpect(deferred.activityEntries.count == 1 && [deferred.activityEntries[0].key isEqualToString:@"cached-act"],
             "activityEntries flushes cached activity on frame 1");
    NSArray<SNChange *> *commandChanges = Changes(deferred, ^{ [deferred loadCommandsCache]; });
    SNExpect(commandChanges.count == 1 && commandChanges[0].commands && [deferred commandNamed:@"/oldcmd"] != nil,
             "loadCommandsCache emits SNChangeCommands and loads cached commands");

    // Live boot responses arriving before finishLoadingCache must not be overwritten by disk cache.
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"activity.feed"]) return @{@"ok" : @YES, @"items" : @[ liveActivity ]};
        if ([method isEqualToString:@"client.appCommands"]) return @{@"ok" : @YES, @"commands" : @[ liveCommand ]};
        return @{@"ok" : @YES};
    };
    SNStore *live = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:api deferred:YES];
    [live attachToMainThread];
    [live loadActivity];
    [live applyCommandsChanged];
    SNExpect(SNWaitUntil(1, ^BOOL { return live.activity.count == 1 && live.commands.count == 1; }), "live boot activity and commands arrive");
    [live finishLoadingCache];
    SNExpect(live.activityEntries.count == 1 && [live.activityEntries[0].key isEqualToString:@"live-act"],
             "finishLoadingCache does not overwrite live activity from boot");
    SNExpect([live commandNamed:@"/livecmd"] != nil && [live commandNamed:@"/oldcmd"] == nil,
             "finishLoadingCache does not overwrite live commands from boot");
    SNExpect(live.users[@"U03PRIYA"] != nil, "finishLoadingCache loads deferred users");
}

SN_TEST(StoreBoundsDecodedMemory) {
    NSURL *url = TemporaryDatabase(@"memory");
    SNStore *store = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:nil];
    store.decodedLimit = 4;
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio"}];
        NSMutableArray *conversations = [NSMutableArray new];
        for (int c = 0; c < 30; c++) [conversations addObject:@{@"id" : [NSString stringWithFormat:@"C%03d", c], @"name" : @"c", @"is_member" : @YES}];
        [store applyConversations:conversations];
    }];
    for (int c = 0; c < 30; c++) {
        NSMutableArray *page = [NSMutableArray new];
        for (int i = 42; i > 0; i--) [page addObject:Message([NSString stringWithFormat:@"17954%05d.000100", i], @"U02SAM", @"x")];
        [store applyNewestHistory:@{@"messages" : page, @"has_more" : @NO} inConversation:[NSString stringWithFormat:@"C%03d", c]];
    }
    SNExpect(store.decodedCount <= 4, "only the most recently used stay decoded");
    SNExpect([store messagesInConversation:@"C000"].count == 42, "an evicted conversation reads back from disk");
    SNExpect([store isDecoded:@"C000"] && [store isDecoded:@"C029"] && ![store isDecoded:@"C001"], "least recently used evicted first");
}

SN_TEST(StoreLooksUpPeopleAndChannels) {
    SNStore *store = Store(nil, [SNTestAPI new]);
    [store applyUsers:@[ @{@"id" : @"U03PRIYA", @"name" : @"priya", @"profile" : @{@"real_name" : @"Priya Patel", @"display_name" : @"Priyá"}},
                         @{@"id" : @"U07CASEY", @"name" : @"casey", @"deleted" : @YES, @"profile" : @{@"real_name" : @"Casey Park"}} ]];
    [store applyConversations:@[ @{@"id" : @"C09DESIGN", @"name" : @"design-reviews", @"is_channel" : @YES, @"is_member" : @NO},
                                 @{@"id" : @"C10DEV", @"name" : @"dev", @"is_channel" : @YES, @"is_member" : @YES} ]];
    SNExpect([[store usersMatching:@"pri" limit:5].firstObject.userID isEqualToString:@"U03PRIYA"], "display name prefix, accents ignored");
    SNExpect([[store usersMatching:@"chen" limit:5].firstObject.userID isEqualToString:@"U02SAM"], "a later word of the real name");
    SNExpect([store usersMatching:@"casey" limit:5].count == 0, "deleted users left out");
    SNExpect([[store channelsMatching:@"#rev" limit:5].firstObject.conversationID isEqualToString:@"C09DESIGN"], "a later word of the channel name");
    NSArray *ids = [[store channelsMatching:@"" limit:5] valueForKey:@"conversationID"];
    SNExpect([ids indexOfObject:@"C10DEV"] < [ids indexOfObject:@"C09DESIGN"], "the user's channels first");
}

SN_TEST(StoreFixturePagesAndSearches) {
    SNFixtureSource *source = [SNFixtureSource sourceWithFolder:SNPublicFixture()];
    SNExpect(source.calls.count == 0, "loading a fixture calls nothing");
    __block SNSearchResult *found;
    [source searchMessages:@"onboarding" page:1 completion:^(SNSearchResult *result, NSError *error) { found = result; }];
    SNExpect(SNWaitUntil(1, ^BOOL { return found != nil; }) && found.messages.count >= 1 && [found.messages[0].conversationID isEqualToString:@"C01GENERAL"],
             "search over the fixture");
    source.failsRequests = YES;
    [source sendText:@"offline" blocks:nil inConversation:@"D05SAM" threadTS:nil broadcast:NO];
    SNExpect(SNWaitUntil(1, ^BOOL { return [source messagesInConversation:@"D05SAM"].lastObject.sendState == SNMessageFailed; }), "failsRequests fails sends");
    __block NSString *opened;
    source.failsRequests = NO;
    [source openDirectMessageWithUsers:@[ @"U02SAM" ] completion:^(NSString *conversationID) { opened = conversationID; }];
    SNExpect([opened isEqualToString:@"D05SAM"], "an open DM is found without a call");
}

/// What Activity Monitor calls Memory.
static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint / 1048576.0 : -1;
}

/// A cache the size of a busy workspace: 1500 people, 400 conversations, 60 of them with 400
/// messages of history each (rich_text blocks and reactions, as Slack sends them).
static void WriteLargeCache(NSURL *url) {
    SNStore *store = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:nil];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U0000"];
        NSMutableArray *users = [NSMutableArray new];
        for (int u = 0; u < 1500; u++) {
            NSMutableDictionary *profile = [@{@"real_name" : [NSString stringWithFormat:@"Person %d", u], @"display_name" : [NSString stringWithFormat:@"person%d", u],
                                              @"title" : @"Made-up title", @"status_text" : @"", @"status_emoji" : @""} mutableCopy];
            for (NSNumber *size in @[ @24, @32, @48, @72, @192, @512 ])
                profile[[NSString stringWithFormat:@"image_%@", size]] = [NSString stringWithFormat:@"https://avatars.example.com/u%d-%@.png", u, size];
            [users addObject:@{@"id" : [NSString stringWithFormat:@"U%04d", u], @"name" : [NSString stringWithFormat:@"person%d", u], @"tz" : @"America/Sao_Paulo",
                               @"tz_offset" : @-10800, @"profile" : profile}];
        }
        [store applyUsers:users];
        NSMutableArray *conversations = [NSMutableArray new], *ids = [NSMutableArray new];
        for (int c = 0; c < 400; c++) {
            NSString *conversationID = [NSString stringWithFormat:@"C%04d", c];
            [ids addObject:conversationID];
            [conversations addObject:@{@"id" : conversationID, @"name" : [NSString stringWithFormat:@"channel-%d", c], @"is_channel" : @YES, @"is_member" : @YES,
                                       @"topic" : @{@"value" : @"A made-up topic"}, @"num_members" : @40}];
        }
        [store applyConversations:conversations];
        [store applySections:@[ @{@"channel_section_id" : @"L01", @"type" : @"channels", @"channel_ids_page" : @{@"channel_ids" : ids}} ]];
    }];
    for (int c = 0; c < 60; c++) {
        NSMutableArray *page = [NSMutableArray new];
        for (int i = 400; i > 0; i--) {
            NSString *text = [NSString stringWithFormat:@"Message %d with some *bold* text and a link <https://example.com/%d|here>", i, i];
            NSDictionary *block = @{@"type" : @"rich_text", @"block_id" : @"b1", @"elements" : @[ @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : text} ]} ]};
            [page addObject:@{@"type" : @"message", @"ts" : [NSString stringWithFormat:@"17954%05d.000100", i], @"user" : [NSString stringWithFormat:@"U%04d", i % 1500],
                              @"text" : text, @"client_msg_id" : NSUUID.UUID.UUIDString.lowercaseString, @"blocks" : @[ block ],
                              @"reactions" : i % 5 ? @[] : @[ @{@"name" : @"+1", @"users" : @[ @"U0001" ], @"count" : @1} ]}];
        }
        [store applyNewestHistory:@{@"messages" : page, @"has_more" : @YES} inConversation:[NSString stringWithFormat:@"C%04d", c]];
    }
}

SN_TEST(StoreColdStartAtScale) {
    NSURL *url = TemporaryDatabase(@"scale");
    @autoreleasepool {
        WriteLargeCache(url);
    }
    double before = FootprintMB();
    NSDate *start = NSDate.date;
    SNStore *store = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:nil];
    NSArray *sections = store.sections;
    NSArray *messages = [store messagesInConversation:@"C0000"];
    NSTimeInterval launch = -start.timeIntervalSinceNow;
    for (int c = 0; c < 60; c++) [store messagesInConversation:[NSString stringWithFormat:@"C%04d", c]];
    double after = FootprintMB();
    SNExpect(store.hasState && sections.count == 1 && messages.count == 84, "the sidebar and the first conversation come from disk");
    SNExpect(store.decodedCount <= store.decodedLimit, "switching through 60 conversations keeps the bound");
    unsigned long long bytes = [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil] fileSize];
    printf("     cache %.1f MB on disk: store ready with sidebar and first page in %.0f ms; +%.1f MB after visiting 60 conversations\n",
           bytes / 1048576.0, launch * 1000, after - before);
}

SN_TEST(StoreClosesDirectMessages) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(nil, api);
    SNExpect([[store.directMessages valueForKey:@"conversationID"] containsObject:@"D05SAM"], "the DM is listed");
    NSArray<SNChange *> *changes = Changes(store, ^{ [store closeConversation:@"D05SAM"]; });
    SNExpect(![[store.directMessages valueForKey:@"conversationID"] containsObject:@"D05SAM"] && changes.firstObject.lists, "it leaves the list at once");
    SNExpect([api.methods containsObject:@"conversations.close"] && [api.calls.lastObject[1][@"channel"] isEqualToString:@"D05SAM"], "conversations.close");
    [store closeConversation:@"C01GENERAL"];
    SNExpect(api.calls.count == 1, "only DMs close");

    SNTestAPI *down = [SNTestAPI new];
    down.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return nil; };
    SNStore *failing = Store(nil, down);
    [failing closeConversation:@"D05SAM"];
    SNExpect(SNWaitUntil(1, ^BOOL { return [failing conversationWithID:@"D05SAM"].isOpen; }), "a failure reopens it");
}

SN_TEST(StoreListsMemberChannels) {
    SNStore *store = Store(nil, nil);
    [store applyConversations:@[ @{@"id" : @"C02RANDOM", @"name" : @"random", @"is_channel" : @YES, @"is_member" : @YES},
                                 @{@"id" : @"C03ANNOUNCE", @"name" : @"announce", @"is_channel" : @YES, @"is_member" : @YES},
                                 @{@"id" : @"C04OLD", @"name" : @"aaa-old", @"is_channel" : @YES, @"is_member" : @YES, @"is_archived" : @YES},
                                 @{@"id" : @"C05OTHER", @"name" : @"elsewhere", @"is_channel" : @YES, @"is_member" : @NO} ]];
    SNExpect(([[store.memberChannels valueForKey:@"name"] isEqualToArray:@[ @"announce", @"general", @"random" ]]),
             "member channels by name, without DMs, archived or others' channels");
    [store applyEvent:@{@"type" : @"channel_rename", @"channel" : @{@"id" : @"C02RANDOM", @"name" : @"aardvark"}}];
    [store applyEvent:@{@"type" : @"channel_left", @"channel" : @"C03ANNOUNCE"}];
    [store applyEvent:@{@"type" : @"channel_unarchive", @"channel" : @"C04OLD"}];
    SNExpect(([[store.memberChannels valueForKey:@"name"] isEqualToArray:@[ @"aaa-old", @"aardvark", @"general" ]]), "renames, leaves and unarchiving move them");
}

SN_TEST(StoreKeepsTheDMListInOrder) {
    SNStore *store = Store(nil, nil);
    [store applyConversations:@[ @{@"id" : @"D06OLD", @"is_im" : @YES, @"user" : @"U02SAM", @"latest" : @"1795400000.000100"},
                                 @{@"id" : @"D07NEW", @"is_im" : @YES, @"user" : @"U01ALEX", @"latest" : @"1795400100.000100"} ]];
    NSArray<NSString *> * (^order)(void) = ^NSArray<NSString *> * { return [store.directMessages valueForKey:@"conversationID"]; };
    SNExpect([[order() subarrayWithRange:NSMakeRange(0, 2)] isEqualToArray:(@[ @"D07NEW", @"D06OLD" ])], "newest activity first");
    NSArray<SNChange *> *changes = Changes(store, ^{ [store applyEvent:SNJSONMerge(Message(@"1795400200.000100", @"U02SAM", @"hi"), @{@"channel" : @"D06OLD"})]; });
    SNExpect([order().firstObject isEqualToString:@"D06OLD"] && changes.firstObject.lists, "a message moves its DM to the top");
    changes = Changes(store, ^{ [store applyEvent:SNJSONMerge(Message(@"1795400300.000100", @"U02SAM", @"again"), @{@"channel" : @"D06OLD"})]; });
    SNExpect([order().firstObject isEqualToString:@"D06OLD"] && !changes.firstObject.lists, "one already at the top moves nothing");
    SNExpect([store.directMessages.firstObject.latest isEqualToString:@"1795400300.000100"], "the list holds the conversation as it is now");
    [store applyEvent:@{@"type" : @"im_close", @"channel" : @"D06OLD"}];
    SNExpect(![order() containsObject:@"D06OLD"], "a closed DM leaves");
}

SN_TEST(StoreKeepsPresenceInMemory) {
    NSURL *url = TemporaryDatabase(@"presence");
    SNStore *store = Store([SNDatabase databaseAtURL:url], nil);
    NSArray<SNChange *> *changes = Changes(store, ^{
        [store applyEvent:@{@"type" : @"presence_change", @"user" : @"U02SAM", @"presence" : @"active"}];
        [store applyDoNotDisturb:@{@"U02SAM" : @{@"snooze_enabled" : @YES, @"snooze_endtime" : @4102444800}}];
    });
    SNExpect([store presenceOfUser:@"U02SAM"] == SNPresenceActive && [store doNotDisturbOfUser:@"U02SAM"], "presence and Do Not Disturb");
    SNExpect([changes.firstObject.presence containsObject:@"U02SAM"] && !changes.firstObject.users, "announced as presence, not as the user");
    BOOL written = NO;
    for (NSDictionary *json in [[SNDatabase databaseAtURL:url] allObjectsInTable:@"users"]) written = written || json[@"presence"] || json[@"dnd_enabled"];
    SNExpect(!written, "nothing written to the cache");
}

SN_TEST(StoreKnowsEachConversationsLatestMessage) {
    NSURL *url = TemporaryDatabase(@"latest");
    @autoreleasepool {
        SNStore *store = Store([SNDatabase databaseAtURL:url], nil);
        [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400100.000100", @"U02SAM", @"cached newest"), Message(@"1795400000.000100", @"U02SAM", @"older") ]}
                   inConversation:@"D05SAM"];
    }
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return @{@"ok" : @YES, @"messages" : @[ Message(@"1795400200.000100", @"U02SAM", @"from Slack") ]};
    };
    SNStore *store = Store([SNDatabase databaseAtURL:url], api);
    SNExpect([[store latestMessageInConversation:@"D05SAM"].text isEqualToString:@"cached newest"] && ![store isDecoded:@"D05SAM"],
             "from the cache, without decoding the history");
    SNExpect(api.calls.count == 0, "nothing asked of Slack for it");

    __block BOOL changed = NO;
    id observer = SNObserveChanges(store, ^(SNChange *change) {
                                                                  changed = changed || [change.messages containsObject:@"C01GENERAL"];
                                                              });
    SNExpect([store latestMessageInConversation:@"C01GENERAL"] == nil, "unknown: nil");
    SNExpect([api.methods isEqualToArray:@[ @"conversations.history" ]] && [api.calls[0][1][@"limit"] isEqualToString:@"1"], "and one message is asked for");
    SNExpect(SNWaitUntil(1, ^BOOL { return changed; }) && [[store latestMessageInConversation:@"C01GENERAL"].text isEqualToString:@"from Slack"],
             "it arrives as a messages change");
    SNStopObserving(observer);
    [store latestMessageInConversation:@"C01GENERAL"];
    SNExpect(api.calls.count == 1, "asked once");

    [store applyLatestMessages:@{@"D05SAM" : Message(@"1795400300.000100", @"U02SAM", @"client.dms says")}];
    SNExpect([[store latestMessageInConversation:@"D05SAM"].text isEqualToString:@"client.dms says"], "client.dms' latest");
    [store applyEvent:@{@"type" : @"message", @"channel" : @"D05SAM", @"user" : @"U02SAM", @"text" : @"live", @"ts" : @"1795400400.000100"}];
    SNExpect([[store latestMessageInConversation:@"D05SAM"].text isEqualToString:@"live"], "a live message is the latest");
}

/// A file at `url` made by hand with `sql`.
static void WriteSQLite(NSURL *url, const char *sql) {
    sqlite3 *db = NULL;
    sqlite3_open(url.fileSystemRepresentation, &db);
    sqlite3_exec(db, sql, NULL, NULL, NULL);
    sqlite3_close(db);
}

SN_TEST(StoreRebuildsAnUnusableCache) {
    NSURL *url = TemporaryDatabase(@"unusable");
    [@"not a database at all" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SNDatabase *database = [SNDatabase databaseAtURL:url];
    [database setJSON:@"kept" forKey:@"k"];
    SNExpect(database && [[database jsonForKey:@"k"] isEqual:@"kept"], "a file that is not a database becomes a new cache");
    database = nil;
    WriteSQLite(url, "PRAGMA user_version = 99;");
    database = [SNDatabase databaseAtURL:url];
    SNExpect(database && ![database jsonForKey:@"k"], "another schema version is rebuilt, not read");
    database = nil;

    NSURL *legacy = TemporaryDatabase(@"legacy");
    WriteSQLite(legacy, "CREATE TABLE kv (key TEXT PRIMARY KEY, value BLOB NOT NULL); INSERT INTO kv VALUES ('me', '\"U01ALEX\"');");
    SNExpect([[[SNDatabase databaseAtURL:legacy] jsonForKey:@"me"] isEqual:@"U01ALEX"], "a cache from before versions keeps its data");

    NSURL *shared = TemporaryDatabase(@"shared");
    SNDatabase *first = [SNDatabase databaseAtURL:shared];
    [first transaction:^{
        [first setJSON:@1 forKey:@"a"];
        [first transaction:^{ [first setJSON:@2 forKey:@"b"]; }];
    }];
    SNDatabase *second = [SNDatabase databaseAtURL:shared];
    [second setJSON:@3 forKey:@"c"];
    SNExpect([[second jsonForKey:@"b"] isEqual:@2] && [[first jsonForKey:@"c"] isEqual:@3], "a transaction ends committed and leaves the file free to write");
    NSNumber *excluded = nil;
    [shared.URLByDeletingLastPathComponent getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil];
    SNExpect(excluded.boolValue, "the cache's folder stays out of Time Machine");
}

/// The real client over a URL protocol stub (nothing reaches Slack), with a made-up session.
static SNClient *StubClient(SNStubHandler handler) {
    SNSessionTeam *team = [SNSessionTeam teamWithJSON:@{@"id" : @"T0NORTHWND", @"token" : @"xoxc-made-up", @"url" : @"https://northwind-studio.slack.com/",
                                                        @"user_id" : @"U01ALEX"}];
    SNSession *session = [[SNSession alloc] initWithCookies:@[] teams:@[ team ] userAgent:@"SlackNativeTest/1"];
    SNClient *client = [[SNClient alloc] initWithSession:session teamID:@"T0NORTHWND" urlSession:SNStubURLSession(handler)];
    client.retryDelays = @[];
    return client;
}

static SNStubAnswer *StubJSON(NSDictionary *json) { return [SNStubAnswer status:200 headers:@{@"Content-Type" : @"application/json"} json:json]; }

/// Requests the stub saw for `method`, with `channel` when given.
static NSUInteger StubCalls(NSString *method, NSString *channel) {
    NSUInteger count = 0;
    for (SNStubRequest *request in SNStubRequests())
        count += [request.method isEqualToString:method] && (!channel || [request.form[@"channel"] isEqualToString:channel]);
    return count;
}

/// A followed thread in #general: the parent and three replies, read through the second.
static void ApplyThread(SNStore *store) {
    NSDictionary *parent = SNJSONMerge(Message(@"1795400200.000100", @"U02SAM", @"p"), @{@"thread_ts" : @"1795400200.000100", @"reply_count" : @3,
                                                                                        @"subscribed" : @YES, @"last_read" : @"1795400220.000100"});
    NSMutableArray *messages = [NSMutableArray arrayWithObject:parent];
    for (NSString *ts in @[ @"1795400210.000100", @"1795400220.000100", @"1795400230.000100" ])
        [messages addObject:SNJSONMerge(Message(ts, @"U02SAM", @"r"), @{@"thread_ts" : @"1795400200.000100"})];
    [store applyReplies:@{@"messages" : messages} thread:@"1795400200.000100" inConversation:@"C01GENERAL"];
    [store applyCounts:@{@"threads" : @{@"has_unreads" : @NO, @"mention_count" : @0}}];
}

static NSString *ThreadLastRead(SNStore *store) {
    return SNJSONString([store threadInConversation:@"C01GENERAL" ts:@"1795400200.000100"].firstObject.json, @"last_read");
}

SN_TEST(StoreMarksThreadsUnreadFromAReply) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(nil, api);
    ApplyThread(store);
    NSArray<SNMessage *> *thread = [store threadInConversation:@"C01GENERAL" ts:@"1795400200.000100"];
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" readThrough:@"1795400230.000100"];
    NSArray<SNChange *> *changes = Changes(store, ^{
        [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" unreadFrom:thread[2]];
    });
    SNExpect([ThreadLastRead(store) isEqualToString:@"1795400210.000100"] && store.hasUnreadThreads, "unread from the reply at once: read through the one before");
    SNExpect(changes.count == 1 && changes[0].counts && ![store conversationWithID:@"C01GENERAL"].hasUnreads, "the Threads badge moves, not the channel's");
    NSDictionary *params = api.calls.lastObject[1];
    SNExpect([api.calls.lastObject[0] isEqualToString:@"subscriptions.thread.mark"] && [params[@"read"] isEqualToString:@"0"] &&
                 [params[@"ts"] isEqualToString:@"1795400210.000100"] && [params[@"thread_ts"] isEqualToString:@"1795400200.000100"],
             "subscriptions.thread.mark read=0 through the message before the reply");
    SNSettle(0.15);
    SNExpect(MarksSent(api, @"subscriptions.thread.mark").count == 1, "the read mark waiting for the thread is dropped");
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" unreadFrom:thread[1]];
    SNExpect([ThreadLastRead(store) isEqualToString:@"1795400200.000100"], "from the first reply: read through the parent");
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" unreadFrom:thread[0]];
    SNExpect(MarksSent(api, @"subscriptions.thread.mark").count == 2, "the parent is not a reply");
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" readThrough:@"1795400230.000100"];
    SNExpect(SNWaitUntil(1, ^BOOL { return MarksSent(api, @"subscriptions.thread.mark").count == 3; }) && [ThreadLastRead(store) isEqualToString:@"1795400230.000100"],
             "reading it again marks it read");

    SNTestAPI *down = [SNTestAPI new];
    down.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return nil; };
    SNStore *failing = Store(nil, down);
    ApplyThread(failing);
    [failing markThread:@"1795400200.000100" inConversation:@"C01GENERAL" unreadFrom:[failing threadInConversation:@"C01GENERAL" ts:@"1795400200.000100"][2]];
    SNExpect([ThreadLastRead(failing) isEqualToString:@"1795400210.000100"] && failing.hasUnreadThreads, "unread at once");
    SNExpect(SNWaitUntil(1, ^BOOL { return !failing.hasUnreadThreads; }) && [ThreadLastRead(failing) isEqualToString:@"1795400220.000100"],
             "a failure puts the read state back");
}

SN_TEST(StoreRefusesUnreadMarksInReadOnlyMode) {
    BOOL wasReadOnly = SNReadOnly();
    SNSetReadOnly(YES);
    SNClient *client = StubClient(^SNStubAnswer *(SNStubRequest *request) { return StubJSON(@{@"ok" : @YES}); });
    SNStore *store = Store(nil, client);
    ApplyThread(store);
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400200.000100", @"U02SAM", @"p"), Message(@"1795400100.000100", @"U02SAM", @"a") ], @"has_more" : @NO}
               inConversation:@"C01GENERAL"];
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400200.000100", @"latest" : @"1795400200.000100", @"has_unreads" : @NO} ]}];
    NSUInteger sent = SNStubRequests().count;
    [store markThread:@"1795400200.000100" inConversation:@"C01GENERAL" unreadFrom:[store threadInConversation:@"C01GENERAL" ts:@"1795400200.000100"][1]];
    [store markConversation:@"C01GENERAL" unreadFrom:[store messagesInConversation:@"C01GENERAL"].lastObject];
    SNExpect(store.hasUnreadThreads && [store conversationWithID:@"C01GENERAL"].hasUnreads, "both apply at once");
    SNExpect(SNWaitUntil(1, ^BOOL { return !store.hasUnreadThreads && ![store conversationWithID:@"C01GENERAL"].hasUnreads; }), "and are put back when refused");
    SNExpect([ThreadLastRead(store) isEqualToString:@"1795400220.000100"] &&
                 [[store conversationWithID:@"C01GENERAL"].lastRead isEqualToString:@"1795400200.000100"],
             "read where Slack has them");
    SNExpect(SNStubRequests().count == sent, "nothing reached Slack");
    SNExpect(SNIsMutatingMethod(@"subscriptions.thread.mark") && !SNIsMutatingMethod(@"conversations.info"), "a write; asking for a conversation is a read");
    SNSetReadOnly(wasReadOnly);
}

/// Caches written while client.dms was asked without channel objects hold DMs in that shape (made
/// up values): no user, so no name and no picture anywhere.
SN_TEST(StoreAsksWhoseADMIsWhenItDoesNotSay) {
    SNTestAPI *api = [SNTestAPI new];
    __block BOOL down = YES;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (![method isEqualToString:@"conversations.info"]) return @{@"ok" : @YES};
        if (down) return nil;
        return @{@"ok" : @YES, @"channel" : @{@"id" : params[@"channel"], @"created" : @1795000000, @"is_im" : @YES, @"is_org_shared" : @NO,
                                              @"context_team_id" : @"T0NORTHWND", @"user" : @"U02SAM", @"is_open" : @YES, @"last_read" : @"1795400000.000100"}};
    };
    SNStore *store = Store(nil, api);
    store.missingDelay = 0.2;
    [store applyConversations:@[ @{@"id" : @"D09OLD", @"is_im" : @YES, @"is_open" : @YES, @"latest" : @"1795400100.000100", @"has_unreads" : @NO,
                                   @"last_read" : @"1795400100.000100", @"mention_count" : @0,
                                   @"message" : @{@"type" : @"message", @"ts" : @"1795400100.000100", @"user" : @"U02SAM", @"text" : @"x"}} ]];
    NSUInteger (^asked)(void) = ^NSUInteger {
        NSUInteger count = 0;
        for (NSArray *call in api.calls) count += [call[0] isEqualToString:@"conversations.info"] && [call[1][@"channel"] isEqualToString:@"D09OLD"];
        return count;
    };
    for (int i = 0; i < 10; i++) [store directMessages];
    SNSettle(0.05);
    [store conversationWithID:@"D09OLD"];
    SNSettle(0.05);
    SNExpect(asked() == 1, "the sidebar's reads ask conversations.info once");
    SNExpect([[store.directMessages valueForKey:@"conversationID"] containsObject:@"D09OLD"] && ![store isConversationUnavailable:@"D09OLD"],
             "no answer: still listed, not asked again at once");
    down = NO;
    SNSettle(0.25);
    [store directMessages];
    SNExpect(SNWaitUntil(1, ^BOOL { return [[store knownConversationWithID:@"D09OLD"].userID isEqualToString:@"U02SAM"]; }), "asked later, the answer says whose DM it is");
    NSUInteger calls = asked();
    [store directMessages];
    [store conversationWithID:@"D09OLD"];
    SNSettle(0.1);
    SNExpect(asked() == calls, "then nothing more is asked");
}

SN_TEST(StoreAsksForUnknownConversationsOnce) {
    __block BOOL down = YES;
    NSObject *lock = [NSObject new];
    SNClient *client = StubClient(^SNStubAnswer *(SNStubRequest *request) {
        NSString *channel = request.form[@"channel"];
        if (![request.method isEqualToString:@"conversations.info"]) return StubJSON(@{@"ok" : @YES});
        if ([channel isEqualToString:@"C09SECRET"]) return StubJSON(@{@"ok" : @NO, @"error" : @"channel_not_found"});
        @synchronized(lock) {
            if ([channel isEqualToString:@"C10FLAKY"] && down) return nil;
        }
        return StubJSON(@{@"ok" : @YES, @"channel" : @{@"id" : channel, @"name" : channel.lowercaseString, @"is_channel" : @YES, @"is_member" : @NO,
                                                       @"last_read" : @"1795400000.000100"}});
    });
    SNStore *store = Store(nil, client);
    store.missingDelay = 0.2;
    NSMutableSet<NSString *> *named = [NSMutableSet new];
    id observer = SNObserveChanges(store, ^(SNChange *change) { [named unionSet:change.conversations ?: [NSSet set]]; });
    SNExpect([store knownConversationWithID:@"C08LAUNCH"] == nil && StubCalls(@"conversations.info", @"C08LAUNCH") == 0, "the store's own reads ask nothing");
    BOOL unknown = YES;
    for (int i = 0; i < 20; i++) unknown = unknown && [store conversationWithID:@"C08LAUNCH"] == nil;
    SNExpect(unknown, "unknown: nil while Slack is asked");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store conversationWithID:@"C08LAUNCH"] != nil; }) && [named containsObject:@"C08LAUNCH"],
             "a channel the user is not in arrives as a conversations change");
    SNExpect(StubCalls(@"conversations.info", @"C08LAUNCH") == 1 && ![store conversationWithID:@"C08LAUNCH"].isMember, "asked once for twenty reads");
    SNExpect(![store isConversationUnavailable:@"C08LAUNCH"] && ![[store.memberChannels valueForKey:@"conversationID"] containsObject:@"C08LAUNCH"],
             "available, and not listed as the user's");

    [store conversationWithID:@"C09SECRET"];
    SNExpect(SNWaitUntil(1, ^BOOL { return [store isConversationUnavailable:@"C09SECRET"]; }) && [named containsObject:@"C09SECRET"],
             "channel_not_found: unavailable, announced so the UI stops waiting");
    for (int i = 0; i < 5; i++) [store conversationWithID:@"C09SECRET"];
    SNSettle(0.25);
    SNExpect(StubCalls(@"conversations.info", @"C09SECRET") == 1, "and never asked again");
    [store applyEvent:@{@"type" : @"channel_joined", @"channel" : @{@"id" : @"C09SECRET", @"name" : @"secret", @"is_channel" : @YES}}];
    SNExpect([store conversationWithID:@"C09SECRET"] && ![store isConversationUnavailable:@"C09SECRET"], "until the user is let in");

    [named removeAllObjects];
    [store conversationWithID:@"C10FLAKY"];
    SNExpect(SNWaitUntil(1, ^BOOL { return StubCalls(@"conversations.info", @"C10FLAKY") == 1; }), "asked");
    SNSettle(0.05);
    [store conversationWithID:@"C10FLAKY"];
    SNSettle(0.05);
    SNExpect(StubCalls(@"conversations.info", @"C10FLAKY") == 1 && ![store isConversationUnavailable:@"C10FLAKY"] && ![named containsObject:@"C10FLAKY"],
             "no answer: not unavailable, and not asked again at once");
    @synchronized(lock) {
        down = NO;
    }
    SNSettle(0.2);
    [store conversationWithID:@"C10FLAKY"];
    SNExpect(SNWaitUntil(1, ^BOOL { return [store conversationWithID:@"C10FLAKY"] != nil; }) && StubCalls(@"conversations.info", @"C10FLAKY") == 2,
             "asked again once the wait passed");
    SNStopObserving(observer);
}

SN_TEST(StoreFindsUsersByHandle) {
    NSURL *url = TemporaryDatabase(@"handles");
    @autoreleasepool {
        SNTestAPI *api = [SNTestAPI new];
        SNStore *store = Store([SNDatabase databaseAtURL:url], api);
        SNExpect([[store userWithHandle:@"sam"].userID isEqualToString:@"U02SAM"] && api.calls.count == 0, "a known handle, from the index");
        [store applyUsers:@[ @{@"id" : @"U02SAM", @"name" : @"samc", @"profile" : @{@"real_name" : @"Sam Chen"}} ]];
        SNExpect([[store userWithHandle:@"samc"].userID isEqualToString:@"U02SAM"] && ![store userWithHandle:@"sam"], "a renamed handle follows the user");
        SNExpect([api.methods isEqualToArray:@[ @"users/search" ]] && [api.calls[0][1][@"query"] isEqualToString:@"sam"], "an unknown one is searched for");
        [store userWithHandle:@"sam"];
        SNExpect(api.calls.count == 1, "once");
    }
    SNStore *again = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:nil];
    SNExpect([[again userWithHandle:@"samc"].userID isEqualToString:@"U02SAM"], "the index is rebuilt from the cache");
}

SN_TEST(StoreReadsCachedMessagesWithoutDecoding) {
    NSURL *url = TemporaryDatabase(@"cached-message");
    @autoreleasepool {
        SNStore *store = Store([SNDatabase databaseAtURL:url], nil);
        [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400200.000100", @"U02SAM", @"p"), Message(@"1795400100.000100", @"U02SAM", @"a") ]}
                   inConversation:@"C01GENERAL"];
        ApplyThread(store);
    }
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store([SNDatabase databaseAtURL:url], api);
    SNExpect([[store cachedMessageWithTS:@"1795400100.000100" inConversation:@"C01GENERAL" threadTS:nil].text isEqualToString:@"a"], "a message of the history");
    SNExpect([[store cachedMessageWithTS:@"1795400220.000100" inConversation:@"C01GENERAL" threadTS:@"1795400200.000100"].text isEqualToString:@"r"],
             "a reply, under its thread");
    SNExpect(![store cachedMessageWithTS:@"1795400220.000100" inConversation:@"C01GENERAL" threadTS:nil] &&
                 ![store cachedMessageWithTS:@"1795400999.000100" inConversation:@"C01GENERAL" threadTS:nil],
             "nil for what is not cached there");
    SNExpect(store.decodedCount == 0 && api.calls.count == 0, "nothing decoded, nothing asked");
    [store messagesInConversation:@"C01GENERAL"];
    SNExpect([[store cachedMessageWithTS:@"1795400200.000100" inConversation:@"C01GENERAL" threadTS:nil].text isEqualToString:@"p"] &&
                 [[store cachedMessageWithTS:@"1795400230.000100" inConversation:@"C01GENERAL" threadTS:@"1795400200.000100"].text isEqualToString:@"r"] &&
                 store.decodedCount == 1,
             "from the decoded history, and a reply's row without decoding its thread");
}
