// The Activity feed in the source: activity.feed asked as the web client asks it, its pages,
// the `activity` websocket events, the unreads switch and the messages behind the entries
// (messages.list). Shapes are the web client's (activity.feed items, RTM activity events);
// values are made up (tests/fixtures/activity.feed*.json).
#import "../net/stub.h"
#import "app/launch.h"
#import "model/json.h"
#import "net/switches.h"
#import "store/fixture.h"
#import "test.h"

/// The calls to `method` the fixture answered, oldest first.
static NSArray<NSDictionary *> *Calls(SNFixtureSource *source, NSString *method) {
    NSMutableArray *calls = [NSMutableArray new];
    for (NSArray *call in source.calls)
        if ([call[0] isEqualToString:method]) [calls addObject:call[1]];
    return calls;
}

static NSArray<NSString *> *Keys(id<SNSource> source) { return [source.activityEntries valueForKey:@"key"]; }

/// A websocket `activity` event (subtype activity_updated) for an at_user item.
static NSDictionary *Updated(NSString *key, NSString *feedTS, BOOL unread) {
    return @{@"type" : @"activity", @"subtype" : @"activity_updated",
             @"entry" : @{@"key" : key, @"feed_ts" : feedTS, @"is_unread" : @(unread),
                          @"item" : @{@"type" : @"at_user", @"message" : @{@"ts" : @"1795300481.000013", @"channel" : @"C03DESIGN", @"author_user_id" : @"U02SAM"}}}};
}

SN_TEST(ActivityFeedAsksLikeTheWebClient) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNExpect(source.activityEntries.count == 0 && !source.isLoadingActivity, "nothing until asked");
    __block NSInteger changes = 0;
    id observer = SNObserveChanges(source, ^(SNChange *change) { changes += change.activity; });
    [source loadActivity];
    SNExpect(source.isLoadingActivity && changes == 1, "loading, announced");
    NSDictionary *params = Calls(source, @"activity.feed").lastObject;
    NSDictionary *expected = @{@"limit" : @"20", @"mode" : @"chrono_reads_and_unreads", @"archive_only" : @"false", @"unread_only" : @"false",
                               @"priority_only" : @"false", @"only_salesforce_channels" : @"false", @"exclude_automations" : @"false",
                               @"automations_only" : @"false", @"is_activity_inbox" : @"false", @"_x_reason" : @"fetchActivityFeed"};
    NSMutableDictionary *sent = [params mutableCopy];
    NSArray *types = [sent[@"types"] componentsSeparatedByString:@","];
    [sent removeObjectForKey:@"types"];
    SNExpect([sent isEqualToDictionary:expected], "the web client's arguments, no cursor on the first page");
    SNExpect(types.count == 20 && [types containsObject:@"thread_v2"] && [types containsObject:@"message_reaction"] && [types containsObject:@"at_user"] &&
                 ![types containsObject:@"thread_reply"],
             "its type list (thread_reply is not one Slack accepts)");
    SNExpect(SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; }) && changes >= 2, "the answer is announced");
    SNStopObserving(observer);

    NSArray<SNActivityEntry *> *entries = source.activityEntries;
    SNExpect(entries.count == 3, "kinds this client does not show are left out");
    SNActivityEntry *mention = entries[0], *reaction = entries[1], *thread = entries[2];
    SNExpect(mention.kind == SNActivityMention && mention.isUnread && [mention.conversationID isEqualToString:@"C03DESIGN"] &&
                 [mention.actorUserID isEqualToString:@"U02SAM"] && [mention.key isEqualToString:@"at_user-C03DESIGN-1795300444.000012"],
             "a mention: where, by whom, unread, Slack's key");
    SNExpect(reaction.kind == SNActivityReaction && [reaction.reactionName isEqualToString:@"tada"] && [reaction.actorUserID isEqualToString:@"U03PRIYA"] &&
                 !reaction.isUnread,
             "a reaction: which and by whom");
    SNExpect(thread.kind == SNActivityThreadReply && [thread.threadTS isEqualToString:@"1795192800.000103"] &&
                 [thread.messageTS isEqualToString:@"1795194600.000107"] && thread.unreadCount == 1 && thread.isUnread,
             "a thread: its first unread reply and how many");

    SNExpect(source.hasMoreActivity, "Slack's cursor says there is more");
    [source loadMoreActivity];
    SNExpect([Calls(source, @"activity.feed").lastObject[@"cursor"] isEqualToString:@"page2"], "the next page goes by the cursor");
    SNExpect(SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; }) && source.activityEntries.count == 4 &&
                 [Keys(source).lastObject isEqualToString:@"keyword-C01GENERAL-1795100000.000200"] && !source.hasMoreActivity,
             "it is added after the first, and was the last");
    NSUInteger calls = Calls(source, @"activity.feed").count;
    [source loadMoreActivity];
    SNExpect(Calls(source, @"activity.feed").count == calls, "nothing more to ask for");

    [source loadActivity];
    [source loadActivity];
    SNExpect(SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; }) && source.activityEntries.count == 3, "a first page replaces the pages held");
    SNExpect(!SNIsMutatingMethod(@"activity.feed") && !SNIsMutatingMethod(@"messages.list"), "both are reads, allowed in read-only mode");
}

SN_TEST(ActivityFeedFollowsTheWebsocket) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    [source loadActivity];
    SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; });
    __block NSInteger changes = 0;
    id observer = SNObserveChanges(source, ^(SNChange *change) { changes += change.activity; });

    [source applyEvent:@{@"type" : @"activity", @"subtype" : @"activity_updated",
                         @"entry" : SNJSONMerge(source.activityEntries[0].json, @{@"is_unread" : @NO})}];
    SNExpect(!source.activityEntries[0].isUnread && source.activityEntries.count == 3 && changes == 1, "read elsewhere: the entry turns read in place");

    [source applyEvent:Updated(@"at_user-C03DESIGN-1795300481.000013", @"1795400000.000000", YES)];
    SNExpect([Keys(source).firstObject isEqualToString:@"at_user-C03DESIGN-1795300481.000013"] && source.activityEntries.count == 4,
             "a new mention goes on top");
    [source applyEvent:Updated(@"at_user-C03DESIGN-1795300481.000013", @"1795250000.000000", YES)];
    SNExpect([Keys(source)[2] isEqualToString:@"at_user-C03DESIGN-1795300481.000013"] && source.activityEntries.count == 4,
             "an update moves the entry to its feed_ts");

    [source applyEvent:@{@"type" : @"activity", @"subtype" : @"activity_deleted", @"key" : @"at_user-C03DESIGN-1795300481.000013"}];
    SNExpect(source.activityEntries.count == 3 && ![Keys(source) containsObject:@"at_user-C03DESIGN-1795300481.000013"], "deleted: it leaves");

    NSUInteger calls = Calls(source, @"activity.feed").count;
    [source applyEvent:@{@"type" : @"activity", @"subtype" : @"activity_invalidated"}];
    SNExpect(Calls(source, @"activity.feed").count == calls + 1, "invalidated: the feed is asked again");
    SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; });
    [source applyEvent:@{@"type" : @"activity", @"subtype" : @"activity_views_updated"}];
    SNExpect(source.activityEntries.count == 3, "other subtypes change nothing");
    SNStopObserving(observer);
}

SN_TEST(ActivityUnreadsSwitch) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    [source loadActivity];
    SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; });
    source.activityUnreadsOnly = YES;
    SNExpect(source.activityEntries.count == 0 && source.isLoadingActivity, "the other mode's entries go at once");
    SNExpect([Calls(source, @"activity.feed").lastObject[@"mode"] isEqualToString:@"chrono_unreads"], "and the feed is asked for unread ones");
    SNExpect(SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; }) && source.activityEntries.count == 2, "which arrive");
    [source applyEvent:@{@"type" : @"activity", @"subtype" : @"activity_updated",
                         @"entry" : SNJSONMerge(source.activityEntries[0].json, @{@"is_unread" : @NO})}];
    SNExpect(source.activityEntries.count == 1, "an entry read meanwhile leaves the unread list");
    source.activityUnreadsOnly = NO;
    SNExpect([Calls(source, @"activity.feed").lastObject[@"mode"] isEqualToString:@"chrono_reads_and_unreads"], "off: everything again");
    SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; });
}

SN_TEST(ActivityMessagesComeFromMessagesList) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    [source loadActivity];
    SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; });
    [source loadMoreActivity];
    SNWaitUntil(1, ^BOOL { return !source.isLoadingActivity; });
    SNActivityEntry *mention = source.activityEntries[0], *old = source.activityEntries.lastObject;
    SNExpect([[source messageForActivityEntry:mention].ts isEqualToString:@"1795300444.000012"], "a message the source holds is there at once");
    SNExpect([source messageForActivityEntry:old] == nil, "an old one is not");
    SNExpect(Calls(source, @"messages.list").count == 0, "asked on the next turn, with whatever else rows asked for");
    __block BOOL changed = NO;
    id observer = SNObserveChanges(source, ^(SNChange *change) { changed = changed || change.activity; });
    SNExpect(SNWaitUntil(1, ^BOOL { return changed; }), "its arrival is announced");
    SNStopObserving(observer);
    NSArray<NSDictionary *> *calls = Calls(source, @"messages.list");
    NSData *idsJSON = [calls.firstObject[@"message_ids"] ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *ids = [NSJSONSerialization JSONObjectWithData:idsJSON options:0 error:nil];
    NSArray *wanted = @[ @{@"channel" : @"C01GENERAL", @"timestamps" : @[ @"1795100000.000200" ]} ];
    SNExpect(calls.count == 1 && [ids isEqual:wanted] && [calls[0][@"org_wide_aware"] isEqualToString:@"true"] &&
                 [calls[0][@"_x_reason"] isEqualToString:@"messages-ufm"],
             "messages.list with the web client's message_ids");
    SNExpect([[source messageForActivityEntry:old].userID isEqualToString:@"U02SAM"], "the message is known now");
    SNActivityEntry *gone = [SNActivityEntry entryWithJSON:@{@"key" : @"x", @"feed_ts" : @"1", @"item" : @{@"type" : @"at_user", @"message" : @{@"ts" : @"1.000001", @"channel" : @"C09GONE"}}}];
    [source messageForActivityEntry:gone];
    SNSettle(0.2);
    [source messageForActivityEntry:gone];
    SNSettle(0.1);
    SNExpect(Calls(source, @"messages.list").count == 2, "a message Slack does not return is asked once");
}
