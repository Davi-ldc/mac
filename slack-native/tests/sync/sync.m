// Sync against a fake API with made-up, API-shaped answers: boot order, users the store has not
// met (one lookup per batch), prefetch order, presence targets and the gap fill after a reconnect
// (once per change).
#import "../net/stub.h"
#import "model/json.h"
#import "render/emoji.h"
#import "sync/sync.h"
#import "test.h"

static NSDictionary *Message(NSString *ts, NSString *user) { return @{@"type" : @"message", @"ts" : ts, @"user" : user, @"text" : @"x"}; }

/// What a small workspace answers.
static NSDictionary *Answer(NSString *method, NSDictionary *params) {
    if ([method isEqualToString:@"client.userBoot"])
        return @{@"ok" : @YES, @"self" : @{@"id" : @"U01ALEX", @"name" : @"alex", @"prefs" : @{@"locale" : @"pt-BR"}},
                 @"team" : @{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"},
                 @"channels" : @[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES},
                                  @{@"id" : @"C02RANDOM", @"name" : @"random", @"is_channel" : @YES},
                                  @{@"id" : @"C03QUIET", @"name" : @"quiet", @"is_channel" : @YES} ],
                 @"ims" : @[ @{@"id" : @"D05SAM", @"is_im" : @YES, @"user" : @"U02SAM"} ]};
    if ([method isEqualToString:@"client.counts"])
        return @{@"ok" : @YES,
                 @"channels" : @[ @{@"id" : @"C01GENERAL", @"latest" : @"1795400300.000100", @"last_read" : @"1795400000.000100", @"has_unreads" : @YES, @"mention_count" : @0},
                                  @{@"id" : @"C02RANDOM", @"latest" : @"1795400200.000100", @"last_read" : @"1795400000.000100", @"has_unreads" : @YES, @"mention_count" : @2},
                                  @{@"id" : @"C03QUIET", @"latest" : @"1795400000.000100", @"last_read" : @"1795400000.000100", @"has_unreads" : @NO, @"mention_count" : @0} ],
                 @"ims" : @[ @{@"id" : @"D05SAM", @"latest" : @"1795400100.000100", @"last_read" : @"1795400000.000100", @"has_unreads" : @YES, @"mention_count" : @1} ],
                 @"mpims" : @[], @"threads" : @{@"has_unreads" : @YES, @"mention_count" : @1}};
    if ([method isEqualToString:@"users.channelSections.list"])
        return @{@"ok" : @YES, @"channel_sections" : @[ @{@"channel_section_id" : @"L01", @"type" : @"channels",
                                                          @"channel_ids_page" : @{@"channel_ids" : @[ @"C01GENERAL", @"C02RANDOM", @"C03QUIET" ]}} ]};
    if ([method isEqualToString:@"users.prefs.get"]) return @{@"ok" : @YES, @"prefs" : @{@"muted_channels" : @"C03QUIET"}};
    if ([method isEqualToString:@"client.dms"]) return @{@"ok" : @YES, @"ims" : @[ @{@"channel" : @{@"id" : @"D06PRIYA", @"user" : @"U03PRIYA"}, @"message" : Message(@"1795400050.000100", @"U03PRIYA")} ]};
    if ([method isEqualToString:@"emoji.list"]) return @{@"ok" : @YES, @"emoji" : @{@"shipit" : @"https://emoji.example.com/shipit.png"}};
    if ([method isEqualToString:@"usergroups.list"]) return @{@"ok" : @YES, @"usergroups" : @[ @{@"id" : @"S01DESIGN", @"handle" : @"designers"} ]};
    if ([method isEqualToString:@"conversations.history"])
        return @{@"ok" : @YES, @"messages" : @[ Message(@"1795400300.000100", @"U09STRANGER") ], @"has_more" : @NO};
    return @{@"ok" : @YES};
}

static NSDictionary *EdgeAnswer(NSString *path, NSDictionary *body) {
    NSMutableArray *results = [NSMutableArray new];
    for (NSString *userID in SNJSONObject(body, @"updated_ids"))
        [results addObject:@{@"id" : userID, @"name" : userID.lowercaseString, @"profile" : @{@"real_name" : [@"Person " stringByAppendingString:userID]}}];
    return @{@"ok" : @YES, @"results" : results};
}

static SNSync *Sync(SNTestAPI *api) {
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return Answer(method, params); };
    api.edgeAnswer = ^NSDictionary *(NSString *path, NSDictionary *body) { return EdgeAnswer(path, body); };
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    return [[SNSync alloc] initWithStore:store api:api];
}

SN_TEST(SyncBootsInTheOfficialOrder) {
    SNTestAPI *api = [SNTestAPI new];
    SNSync *sync = Sync(api);
    __block BOOL booted = NO;
    [sync bootWithCompletion:^(BOOL ok) { booted = ok; }];
    SNExpect(SNWaitUntil(1, ^BOOL { return booted; }), "boot completes");
    SNStore *store = sync.store;
    SNExpect(store.hasState && [store.me.userID isEqualToString:@"U01ALEX"] && [store.workspace.name isEqualToString:@"Northwind Studio"], "workspace and user from userBoot");
    SNExpect([api.methods.firstObject isEqualToString:@"client.userBoot"], "userBoot first");
    SNExpect([api.calls.firstObject[1][@"_x_reason"] isEqualToString:@"initial-data"], "a first boot is initial-data");
    SNExpect(SNWaitUntil(2, ^BOOL { return store.sections.count == 1 && SNCustomEmojiNames().count == 1 && [store conversationWithID:@"D06PRIYA"]; }),
             "sections, emoji and client.dms applied");
    SNExpect(SNWaitUntil(2, ^BOOL { return [[store usergroupHandleWithID:@"S01DESIGN"] isEqualToString:@"designers"]; }), "usergroup handles");
    SNExpect([store conversationWithID:@"C02RANDOM"].mentionCount == 2 && store.hasUnreadThreads, "counts applied");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store conversationWithID:@"C03QUIET"].isMuted; }), "muted from prefs");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store knownUserWithID:@"U02SAM"] != nil && [store knownUserWithID:@"U03PRIYA"] != nil; }),
             "the people of DMs fetched through the edge API");
    NSArray *presence = sync.presenceUserIDs;
    SNExpect([presence.firstObject isEqualToString:@"U01ALEX"] && [presence containsObject:@"U02SAM"] && [presence containsObject:@"U03PRIYA"], "presence: me and DM partners");
    NSArray *order = sync.prefetchOrder;
    SNExpect(([order isEqualToArray:@[ @"D05SAM", @"C02RANDOM", @"C01GENERAL" ]]), "prefetch: DMs, mentions, then unread by activity; muted and read left out");
    SNExpect(SNWaitUntil(2, ^BOOL { return [store messagesInConversation:@"D05SAM"].count == 1; }), "prefetched history");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store knownUserWithID:@"U09STRANGER"] != nil; }), "authors the store did not know are fetched");
}

SN_TEST(SyncFillsGapsAfterAReconnect) {
    SNTestAPI *api = [SNTestAPI new];
    SNSync *sync = Sync(api);
    SNStore *store = sync.store;
    __block BOOL booted = NO;
    [sync bootWithCompletion:^(BOOL ok) { booted = ok; }];
    SNWaitUntil(1, ^BOOL { return booted; });
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400000.000100", @"U02SAM") ], @"has_more" : @NO} inConversation:@"C03QUIET"];
    SNSettle(0.3);
    [api.calls removeAllObjects];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"client.counts"])
            return @{@"ok" : @YES, @"channels" : @[ @{@"id" : @"C03QUIET", @"latest" : @"1795400900.000100", @"last_read" : @"1795400000.000100", @"has_unreads" : @YES} ]};
        if ([method isEqualToString:@"conversations.history"] && [params[@"channel"] isEqualToString:@"C03QUIET"])
            return @{@"ok" : @YES, @"messages" : @[ Message(@"1795400900.000100", @"U02SAM"), Message(@"1795400000.000100", @"U02SAM") ], @"has_more" : @NO};
        return Answer(method, params);
    };
    [sync connectedWithFastReconnect:YES];
    SNExpect(api.calls.count == 0, "a fast reconnect needs nothing");
    [sync connectedWithFastReconnect:NO];
    SNExpect(SNWaitUntil(2, ^BOOL { return [store messagesInConversation:@"C03QUIET"].count == 2; }), "what moved while away is fetched");
    SNExpect([api.methods.firstObject isEqualToString:@"client.counts"], "counts first, to see what moved");
}

SN_TEST(SyncBootsIncrementallyFromACache) {
    NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests/sync.sqlite"];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return Answer(method, params); };
    @autoreleasepool {
        SNStore *store = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:api];
        SNSync *sync = [[SNSync alloc] initWithStore:store api:api];
        __block BOOL booted = NO;
        [sync bootWithCompletion:^(BOOL ok) { booted = ok; }];
        SNWaitUntil(1, ^BOOL { return booted; });
    }
    [api.calls removeAllObjects];
    SNStore *store = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:url] api:api];
    SNSync *sync = [[SNSync alloc] initWithStore:store api:api];
    SNExpect(store.hasState, "the second launch shows the cache before boot");
    [sync bootWithCompletion:nil];
    NSDictionary *params = api.calls.firstObject[1];
    SNExpect([params[@"_x_reason"] isEqualToString:@"deferred-data"] && params[@"min_channel_updated"], "an incremental boot asks only for what changed");
}

/// A booted sync over a memory store.
static SNSync *Booted(SNTestAPI *api) {
    SNSync *sync = Sync(api);
    __block BOOL booted = NO;
    [sync bootWithCompletion:^(BOOL ok) { booted = ok; }];
    SNWaitUntil(1, ^BOOL { return booted; });
    SNSettle(0.3);
    return sync;
}

static NSUInteger Calls(SNTestAPI *api, NSString *method, NSString *channel) {
    NSUInteger count = 0;
    for (NSArray *call in api.calls) count += [call[0] isEqualToString:method] && (!channel || [call[1][@"channel"] isEqualToString:channel]);
    return count;
}

SN_TEST(SyncFetchesAMovedConversationOncePerChange) {
    SNTestAPI *api = [SNTestAPI new];
    SNSync *sync = Booted(api);
    SNStore *store = sync.store;
    [store applyNewestHistory:@{@"messages" : @[ Message(@"1795400000.000100", @"U02SAM") ], @"has_more" : @NO} inConversation:@"C03QUIET"];
    __block NSString *latest = @"1795400900.000100";
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"client.counts"])
            return @{@"ok" : @YES, @"channels" : @[ @{@"id" : @"C03QUIET", @"latest" : latest, @"last_read" : @"1795400000.000100", @"has_unreads" : @NO} ]};
        // The counts' latest is a reply, which the history never lists.
        if ([method isEqualToString:@"conversations.history"]) return @{@"ok" : @YES, @"messages" : @[], @"has_more" : @NO};
        return Answer(method, params);
    };
    [api.calls removeAllObjects];
    for (int i = 0; i < 3; i++) {
        [sync connectedWithFastReconnect:NO];
        SNSettle(0.1);
    }
    SNExpect(Calls(api, @"client.counts", nil) == 3 && Calls(api, @"conversations.history", @"C03QUIET") == 1,
             "a latest the cache never reaches is fetched once, not on every counts call");
    latest = @"1795401000.000100";
    [sync connectedWithFastReconnect:NO];
    SNExpect(SNWaitUntil(1, ^BOOL { return Calls(api, @"conversations.history", @"C03QUIET") == 2; }), "a new latest is fetched again");
}

SN_TEST(SyncResubscribesPresenceForNewPeopleOnly) {
    SNTestAPI *api = [SNTestAPI new];
    SNSync *sync = Booted(api);
    SNStore *store = sync.store;
    NSMutableArray<NSArray *> *sent = [NSMutableArray new];
    sync.presenceChanged = ^(NSArray<NSString *> *userIDs) { [sent addObject:userIDs]; };
    [store applyEvent:SNJSONMerge(Message(@"1795400500.000100", @"U02SAM"), @{@"channel" : @"D05SAM"})];
    [store applyEvent:SNJSONMerge(Message(@"1795400600.000100", @"U03PRIYA"), @{@"channel" : @"D06PRIYA"})];
    [store applyEvent:SNJSONMerge(Message(@"1795400700.000100", @"U02SAM"), @{@"channel" : @"D05SAM"})];
    SNExpect(sent.count == 0, "the DM list reordering resends nothing");
    [store applyEvent:@{@"type" : @"im_created", @"channel" : @{@"id" : @"D07CASEY", @"is_im" : @YES, @"is_open" : @YES, @"user" : @"U07CASEY"}}];
    SNExpect(sent.count == 1 && [sent[0] containsObject:@"U07CASEY"], "someone new in it does");
}

/// client.dms as Slack answers its DMs tab (made-up values): {id, latest, message} per entry, and
/// the channel object only when include_channel asks for it.
SN_TEST(SyncTakesDMsFromTheirChannelObjects) {
    SNTestAPI *api = [SNTestAPI new];
    SNSync *sync = Sync(api);
    NSDictionary *mine = @{@"type" : @"message", @"ts" : @"1795400070.000100", @"user" : @"U01ALEX", @"text" : @"x", @"team" : @"T0NORTHWND",
                           @"client_msg_id" : @"5f0c1d2e-0000-4000-8000-000000000001", @"blocks" : @[]};
    NSDictionary *im = @{@"id" : @"D07CASEY", @"created" : @1795000000, @"is_frozen" : @NO, @"is_archived" : @NO, @"is_im" : @YES, @"is_org_shared" : @NO,
                         @"context_team_id" : @"T0NORTHWND", @"updated" : @1795000000000, @"user" : @"U07CASEY", @"last_read" : @"1795400000.000100",
                         @"latest" : @"1795400070.000100", @"is_open" : @YES};
    NSDictionary *mpim = @{@"id" : @"C08GROUP", @"name" : @"mpdm-alex--sam--priya-1", @"is_mpim" : @YES, @"is_group" : @YES, @"is_private" : @YES,
                           @"is_open" : @YES, @"created" : @1795000000, @"last_read" : @"1795400000.000100"};
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (![method isEqualToString:@"client.dms"]) return Answer(method, params);
        return @{@"ok" : @YES,
                 @"ims" : @[ @{@"id" : @"D07CASEY", @"latest" : @"1795400070.000100", @"message" : mine, @"channel" : im},
                             @{@"id" : @"D05SAM", @"latest" : @"1795400080.000100", @"message" : SNJSONMerge(mine, @{@"ts" : @"1795400080.000100"})},
                             @{@"id" : @"D09BARE", @"latest" : @"1795400090.000100", @"message" : SNJSONMerge(mine, @{@"ts" : @"1795400090.000100"})} ],
                 @"mpims" : @[ @{@"id" : @"C08GROUP", @"latest" : @"1795400060.000100", @"message" : SNJSONMerge(mine, @{@"ts" : @"1795400060.000100"}),
                                 @"channel" : mpim} ]};
    };
    [sync bootWithCompletion:nil];
    SNStore *store = sync.store;
    SNExpect(SNWaitUntil(2, ^BOOL { return [store knownConversationWithID:@"D07CASEY"] != nil; }), "client.dms applied");
    NSDictionary *params;
    for (NSArray *call in api.calls)
        if ([call[0] isEqualToString:@"client.dms"]) params = call[1];
    SNExpect([params[@"include_channel"] isEqualToString:@"true"], "asked with the channel objects, as Slack's DMs tab asks");
    SNConversation *casey = [store knownConversationWithID:@"D07CASEY"];
    SNExpect(casey.kind == SNConversationDirect && [casey.userID isEqualToString:@"U07CASEY"] && casey.isOpen, "a DM is its channel object: whose it is");
    SNConversation *group = [store knownConversationWithID:@"C08GROUP"];
    SNExpect(group.kind == SNConversationGroupDirect && [group.name isEqualToString:@"mpdm-alex--sam--priya-1"], "a group DM keeps its mpdm name");
    SNExpect([[store knownConversationWithID:@"D05SAM"].userID isEqualToString:@"U02SAM"], "an entry without a channel leaves userBoot's DM whole");
    SNExpect([store knownConversationWithID:@"D09BARE"] == nil, "and makes no DM that does not say whose it is");
    SNExpect([[store latestMessageInConversation:@"D09BARE"].ts isEqualToString:@"1795400090.000100"], "its newest message is still kept");
}

SN_TEST(SyncLooksUsersUpInOneBatch) {
    SNTestAPI *api = [SNTestAPI new];
    SNSync *sync = Booted(api);
    SNStore *store = sync.store;
    api.edgeAnswer = ^NSDictionary *(NSString *path, NSDictionary *body) { return @{@"ok" : @YES, @"results" : @[]}; };
    [api.calls removeAllObjects];
    for (NSString *userID in @[ @"U09GONE", @"U09GONE", @"U08LEFT" ]) [store userWithID:userID];
    SNSettle(0.3);
    for (int i = 0; i < 20; i++) [store userWithID:@"U09GONE"];
    SNSettle(0.3);
    NSDictionary *lookup = nil;
    for (NSArray *call in api.calls)
        if ([call[0] isEqualToString:@"users/info"]) lookup = call[1];
    SNExpect(Calls(api, @"users/info", nil) == 1 && [lookup[@"updated_ids"] count] == 2, "one edge lookup for both, however often they are read");
    SNExpect(Calls(api, @"users.info", nil) == 0, "users it does not return are not asked for one by one");
}
