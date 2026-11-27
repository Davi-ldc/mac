// Messages against the shapes Slack sends (seen in a signed-in cache and trace; values made up):
// chat.postMessage's request, one request per send or retry, the HTTP answer arriving after the
// websocket's echo and an unfurl, message_changed replacing what a message says, deletions of
// replies cached under their thread, and bots known only by bot_id.
#import "../net/stub.h"
#import "model/json.h"
#import "store/database.h"
#import "store/store.h"
#import "test.h"

static NSURL *FreshDatabase(NSString *name) {
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [folder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"sqlite"]];
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ])
        [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    return url;
}

static SNStore *ShapesStore(SNDatabase *database, id<SNAPI> api) {
    SNStore *store = [[SNStore alloc] initWithDatabase:database api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"real_name" : @"Alex Rivera"}},
                             @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"real_name" : @"Sam Chen"}} ]];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES} ]];
    }];
    return store;
}

/// A message as conversations.history and the websocket give it: rich_text blocks and the text.
static NSDictionary *Posted(NSString *ts, NSString *user, NSString *text) {
    return @{@"type" : @"message", @"ts" : ts, @"user" : user, @"text" : text, @"team" : @"T0NORTHWND",
             @"blocks" : @[ @{@"type" : @"rich_text", @"block_id" : @"aB1",
                              @"elements" : @[ @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : text} ]} ]} ]};
}

static NSUInteger Posts(SNTestAPI *api) {
    NSUInteger posts = 0;
    for (NSString *method in api.methods) posts += [method isEqualToString:@"chat.postMessage"];
    return posts;
}

SN_TEST(StorePostsMessagesInSlacksShape) {
    SNTestAPI *api = [SNTestAPI new];
    api.holds = YES;
    SNStore *store = ShapesStore(nil, api);
    [store applyNewestHistory:@{@"messages" : @[ Posted(@"1795400000.000100", @"U02SAM", @"parent") ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    NSArray *blocks = @[ @{@"type" : @"rich_text", @"elements" : @[ @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : @"hi"} ]} ]} ];
    SNMessage *plain = [store sendText:@"hi" blocks:blocks inConversation:@"C01GENERAL" threadTS:nil broadcast:NO];
    NSDictionary *params = api.calls.lastObject[1];
    NSArray *sentBlocks = [NSJSONSerialization JSONObjectWithData:[params[@"blocks"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    SNExpect([params[@"channel"] isEqualToString:@"C01GENERAL"] && [params[@"text"] isEqualToString:@"hi"] && [sentBlocks isEqualToArray:blocks],
             "the channel, the text fallback and the rich_text blocks as JSON");
    SNExpect([params[@"client_msg_id"] isEqualToString:plain.clientMessageID] && [[NSUUID alloc] initWithUUIDString:plain.clientMessageID] &&
                 [plain.clientMessageID isEqualToString:plain.clientMessageID.lowercaseString],
             "a lowercase UUID as client_msg_id, the pending row's identifier");
    SNExpect(!params[@"thread_ts"] && !params[@"reply_broadcast"], "no thread fields outside threads");
    [store sendText:@"in thread" blocks:nil inConversation:@"C01GENERAL" threadTS:@"1795400000.000100" broadcast:NO];
    params = api.calls.lastObject[1];
    SNExpect([params[@"thread_ts"] isEqualToString:@"1795400000.000100"] && !params[@"reply_broadcast"], "a reply names its thread");
    SNMessage *broadcast = [store sendText:@"also here" blocks:nil inConversation:@"C01GENERAL" threadTS:@"1795400000.000100" broadcast:YES];
    params = api.calls.lastObject[1];
    SNExpect([params[@"thread_ts"] isEqualToString:@"1795400000.000100"] && [params[@"reply_broadcast"] isEqualToString:@"true"], "reply_broadcast when also sent");
    SNExpect([[[store messagesInConversation:@"C01GENERAL"] valueForKey:@"identifier"] containsObject:broadcast.identifier] &&
                 [[[store threadInConversation:@"C01GENERAL" ts:@"1795400000.000100"] valueForKey:@"identifier"] containsObject:broadcast.identifier],
             "a broadcast shows in the channel and in its thread at once");
    SNExpect(Posts(api) == 3, "one request per send");
}

SN_TEST(StoreSendsOneRequestPerRetry) {
    SNTestAPI *api = [SNTestAPI new];
    __block BOOL down = YES;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (down) return nil;
        return @{@"ok" : @YES, @"channel" : params[@"channel"], @"ts" : @"1795500000.000400", @"message" : Posted(@"1795500000.000400", @"U01ALEX", params[@"text"])};
    };
    SNStore *store = ShapesStore(nil, api);
    [store sendText:@"try" blocks:nil inConversation:@"C01GENERAL" threadTS:nil broadcast:NO];
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].lastObject.sendState == SNMessageFailed; }), "failed");
    // The row keeps the failed copy it was drawn from while the retry is out.
    SNMessage *drawn = [store messagesInConversation:@"C01GENERAL"].lastObject;
    down = NO;
    api.holds = YES;
    [store retrySendingMessage:drawn];
    [store retrySendingMessage:drawn];
    SNExpect(Posts(api) == 2, "a second Retry while the first is out sends nothing");
    for (dispatch_block_t answer in api.held) answer();
    [api.held removeAllObjects];
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].lastObject.sendState == SNMessageSent; }), "sent");
    [store retrySendingMessage:drawn];
    SNExpect(Posts(api) == 2 && [store messagesInConversation:@"C01GENERAL"].count == 1, "nor does a stale Retry after it was sent");
}

SN_TEST(StoreKeepsTheUnfurlWhenTheAnswerComesLast) {
    SNTestAPI *api = [SNTestAPI new];
    api.holds = YES;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return @{@"ok" : @YES, @"channel" : @"C01GENERAL", @"ts" : @"1795500000.000500", @"message" : Posted(@"1795500000.000500", @"U01ALEX", params[@"text"])};
    };
    SNStore *store = ShapesStore(nil, api);
    [store applyNewestHistory:@{@"messages" : @[], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    SNMessage *pending = [store sendText:@"https://example.com/post" blocks:nil inConversation:@"C01GENERAL" threadTS:nil broadcast:NO];
    NSDictionary *echo = SNJSONMerge(Posted(@"1795500000.000500", @"U01ALEX", @"https://example.com/post"),
                                     @{@"channel" : @"C01GENERAL", @"client_msg_id" : pending.clientMessageID, @"event_ts" : @"1795500000.000500"});
    [store applyEvent:echo];
    NSDictionary *unfurl = @{@"id" : @1, @"from_url" : @"https://example.com/post", @"original_url" : @"https://example.com/post", @"service_name" : @"Example",
                             @"title" : @"A post", @"title_link" : @"https://example.com/post", @"image_url" : @"https://example.com/cover.png",
                             @"image_width" : @1200, @"image_height" : @630, @"fallback" : @"Example: A post"};
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_changed", @"hidden" : @YES, @"channel" : @"C01GENERAL", @"ts" : @"1795500001.000100",
                        @"message" : SNJSONMerge(echo, @{@"attachments" : @[ unfurl ]}), @"previous_message" : echo}];
    for (dispatch_block_t answer in api.held) answer();
    SNSettle(0.1);
    NSArray<SNMessage *> *messages = [store messagesInConversation:@"C01GENERAL"];
    SNExpect(messages.count == 1 && messages[0].attachments.count == 1, "the answer after the echo and the unfurl keeps the unfurl");
}

SN_TEST(StoreReplacesWhatChangedMessagesSay) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = ShapesStore(nil, api);
    NSDictionary *link = SNJSONMerge(Posted(@"1795400000.000100", @"U02SAM", @"see https://example.com"), @{
        @"attachments" : @[ @{@"id" : @1, @"from_url" : @"https://example.com", @"title" : @"Example", @"fallback" : @"Example"} ],
        @"reactions" : @[ @{@"name" : @"eyes", @"users" : @[ @"U01ALEX" ], @"count" : @1} ]
    });
    NSDictionary *parent = SNJSONMerge(Posted(@"1795400100.000100", @"U02SAM", @"question"), @{
        @"thread_ts" : @"1795400100.000100", @"reply_count" : @2, @"reply_users" : @[ @"U01ALEX" ], @"reply_users_count" : @1,
        @"latest_reply" : @"1795400300.000100", @"is_locked" : @NO, @"subscribed" : @YES
    });
    [store applyNewestHistory:@{@"messages" : @[ parent, link ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    // Taking the link preview away: the edit's message has no attachments, and no reactions key.
    NSMutableDictionary *withoutPreview = [link mutableCopy];
    [withoutPreview removeObjectsForKeys:@[ @"attachments", @"reactions" ]];
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_changed", @"hidden" : @YES, @"channel" : @"C01GENERAL", @"message" : withoutPreview,
                        @"previous_message" : link, @"ts" : @"1795400400.000100", @"event_ts" : @"1795400400.000100"}];
    SNMessage *edited = [store messagesInConversation:@"C01GENERAL"].firstObject;
    SNExpect(edited.attachments.count == 0 && edited.reactions.count == 1, "the preview goes, the reactions stay");
    // A parent deleted while it has replies becomes a tombstone.
    NSDictionary *tombstone = @{@"type" : @"message", @"subtype" : @"tombstone", @"hidden" : @YES, @"text" : @"This message was deleted.", @"user" : @"USLACKBOT",
                                @"ts" : @"1795400100.000100", @"thread_ts" : @"1795400100.000100", @"reply_count" : @2, @"reply_users" : @[ @"U01ALEX" ],
                                @"reply_users_count" : @1, @"latest_reply" : @"1795400300.000100"};
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_changed", @"hidden" : @YES, @"channel" : @"C01GENERAL", @"message" : tombstone,
                        @"previous_message" : parent, @"ts" : @"1795400500.000100"}];
    SNMessage *gone = [store messagesInConversation:@"C01GENERAL"].lastObject;
    SNExpect([gone.subtype isEqualToString:@"tombstone"] && gone.blocks.count == 0 && gone.replyCount == 2, "a tombstone keeps its replies, not its blocks");
}

SN_TEST(StoreAppliesChangesToRepliesCachedUnderTheirThread) {
    SNTestAPI *api = [SNTestAPI new];
    NSURL *url = FreshDatabase(@"thread-events");
    SNStore *store = ShapesStore([SNDatabase databaseAtURL:url], api);
    NSDictionary *parent = SNJSONMerge(Posted(@"1795400100.000100", @"U02SAM", @"question"), @{
        @"thread_ts" : @"1795400100.000100", @"reply_count" : @2, @"reply_users" : @[ @"U01ALEX", @"U02SAM" ], @"reply_users_count" : @2,
        @"latest_reply" : @"1795400300.000100", @"last_read" : @"1795400300.000100", @"subscribed" : @YES
    });
    NSDictionary *first = SNJSONMerge(Posted(@"1795400200.000100", @"U01ALEX", @"first answer"), @{@"thread_ts" : @"1795400100.000100", @"parent_user_id" : @"U02SAM"});
    NSDictionary *second = SNJSONMerge(Posted(@"1795400300.000100", @"U02SAM", @"second answer"), @{@"thread_ts" : @"1795400100.000100", @"parent_user_id" : @"U02SAM"});
    [store applyNewestHistory:@{@"messages" : @[ parent ], @"has_more" : @NO} inConversation:@"C01GENERAL"];
    [store applyReplies:@{@"messages" : @[ parent, first, second ], @"has_more" : @NO} thread:@"1795400100.000100" inConversation:@"C01GENERAL"];

    // The same store over the cache: the thread is on disk only.
    SNStore *later = ShapesStore([SNDatabase databaseAtURL:url], api);
    NSDictionary *edit = SNJSONMerge(second, @{@"text" : @"second answer, fixed", @"edited" : @{@"user" : @"U02SAM", @"ts" : @"1795400400.000000"}});
    [later applyEvent:@{@"type" : @"message", @"subtype" : @"message_changed", @"hidden" : @YES, @"channel" : @"C01GENERAL", @"message" : edit, @"previous_message" : second,
                        @"ts" : @"1795400400.000100"}];
    SNMessage *cached = [later cachedMessageWithTS:@"1795400300.000100" inConversation:@"C01GENERAL" threadTS:@"1795400100.000100"];
    SNExpect([cached.text isEqualToString:@"second answer, fixed"] && cached.editedTS, "an edit reaches a reply cached under its thread");
    [later applyEvent:@{@"type" : @"message", @"subtype" : @"message_deleted", @"hidden" : @YES, @"channel" : @"C01GENERAL", @"deleted_ts" : @"1795400200.000100",
                        @"previous_message" : first, @"ts" : @"1795400500.000100", @"event_ts" : @"1795400500.000100"}];
    SNExpect(![later cachedMessageWithTS:@"1795400200.000100" inConversation:@"C01GENERAL" threadTS:@"1795400100.000100"], "so does a deletion");

    // In the thread fetched in this session, the parent's reply bar follows.
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_deleted", @"hidden" : @YES, @"channel" : @"C01GENERAL", @"deleted_ts" : @"1795400300.000100",
                        @"previous_message" : second, @"ts" : @"1795400600.000100"}];
    SNMessage *shown = [store messagesInConversation:@"C01GENERAL"].firstObject;
    SNExpect(shown.replyCount == 1 && [shown.latestReply isEqualToString:@"1795400200.000100"], "the reply bar counts what is left");
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_deleted", @"hidden" : @YES, @"channel" : @"C01GENERAL", @"deleted_ts" : @"1795400300.000100",
                        @"previous_message" : second, @"ts" : @"1795400600.000100"}];
    SNExpect([store messagesInConversation:@"C01GENERAL"].firstObject.replyCount == 1, "a repeated deletion counts once");
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

SN_TEST(StoreNamesBotsFromBotsInfo) {
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (![method isEqualToString:@"bots.info"]) return @{@"ok" : @YES};
        return @{@"ok" : @YES, @"bot" : @{@"id" : params[@"bot"], @"deleted" : @NO, @"name" : @"Review Digest", @"updated" : @1795000000,
                                          @"icons" : @{@"image_36" : @"https://avatars.example.com/digest_36.png", @"image_48" : @"https://avatars.example.com/digest_48.png",
                                                       @"image_72" : @"https://avatars.example.com/digest_72.png"}}};
    };
    NSURL *url = FreshDatabase(@"bots");
    SNStore *store = ShapesStore([SNDatabase databaseAtURL:url], api);
    SNExpect(![store botWithID:@"B0DIGEST"] && ![store botWithID:@"B0DIGEST"], "unknown at first");
    __block NSArray<SNChange *> *changes = @[];
    id observer = SNObserveChanges(store, ^(SNChange *change) {
        changes = [changes arrayByAddingObject:change];
    });
    SNExpect(SNWaitUntil(1, ^BOOL { return [store botWithID:@"B0DIGEST"] != nil; }), "bots.info answers");
    SNStopObserving(observer);
    NSUInteger asked = 0;
    for (NSArray *call in api.calls) asked += [call[0] isEqualToString:@"bots.info"] && [call[1][@"bot"] isEqualToString:@"B0DIGEST"];
    SNExpect(asked == 1, "asked once");
    SNExpect([changes.lastObject.users containsObject:@"B0DIGEST"], "announced by its ID");
    SNBot *bot = [store botWithID:@"B0DIGEST"];
    SNExpect([bot.name isEqualToString:@"Review Digest"] && [bot.iconURLs[@72].lastPathComponent isEqualToString:@"digest_72.png"], "name and icons");
    SNStore *later = ShapesStore([SNDatabase databaseAtURL:url], nil);
    SNExpect([[later botWithID:@"B0DIGEST"].name isEqualToString:@"Review Digest"], "kept in the cache");
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

SN_TEST(ModelPicksTheSharpestFilePicture) {
    // A files[] entry as history gives it: thumbnails up to the picture's own size only.
    NSString *base = @"https://files.slack.com/files-tmb/T0NORTHWND-F0SHOT-0a1b2c3d4e/screenshot";
    SNFile *file = [SNFile fileWithJSON:@{@"id" : @"F0SHOT", @"name" : @"screenshot.png", @"title" : @"screenshot.png", @"mimetype" : @"image/png",
                                          @"filetype" : @"png", @"pretty_type" : @"PNG", @"mode" : @"hosted", @"size" : @48213,
                                          @"url_private" : @"https://files.slack.com/files-pri/T0NORTHWND-F0SHOT/screenshot.png",
                                          @"url_private_download" : @"https://files.slack.com/files-pri/T0NORTHWND-F0SHOT/download/screenshot.png",
                                          @"thumb_64" : [base stringByAppendingString:@"_64.png"], @"thumb_80" : [base stringByAppendingString:@"_80.png"],
                                          @"thumb_160" : [base stringByAppendingString:@"_160.png"], @"thumb_360" : [base stringByAppendingString:@"_360.png"],
                                          @"thumb_360_w" : @360, @"thumb_360_h" : @206, @"thumb_480" : [base stringByAppendingString:@"_480.png"],
                                          @"thumb_480_w" : @480, @"thumb_480_h" : @274, @"thumb_tiny" : @"AwAbADC0", @"original_w" : @700, @"original_h" : @400}];
    SNExpect([[file thumbnailURLForPixels:400].lastPathComponent isEqualToString:@"screenshot_480.png"], "a thumbnail when one is big enough");
    SNExpect([[file thumbnailURLForPixels:960].absoluteString hasSuffix:@"/files-pri/T0NORTHWND-F0SHOT/screenshot.png"], "else the original");
}
