// The Activity tab's VIP tab on the public fixture (a paid plan; Priya is a VIP): shown while the
// user has VIPs, its feed asked in the web client's priority-only modes and types.
#import "../net/stub.h"
#import "app/launch.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/activity/pane.h"
#import "ui/shell/shell.h"

static NSDictionary *LastFeed(SNFixtureSource *source) {
    for (NSArray *call in source.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:@"activity.feed"]) return call[1];
    return nil;
}

SN_TEST(ActivityHasAVIPTabWithItsOwnFeed) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell selectTab:SNTabActivity];
    SNActivityPane *pane = (SNActivityPane *)[shell paneForTab:SNTabActivity];
    pane.filter = SNActivityVIP;
    SNExpect(source.activityVIPOnly, "the VIP tab asks for VIP activity");
    NSDictionary *feed = LastFeed(source);
    SNExpect([feed[@"mode"] isEqualToString:@"chrono_priority_only_reads_and_unreads_v1"], "in the priority-only mode");
    SNExpect([feed[@"types"] isEqualToString:@"thread_v2,internal_channel_invite,at_user,at_user_group,at_channel,at_everyone,keyword,bot_dm_bundle"], "with the VIP tab's types");
    source.activityUnreadsOnly = YES;
    SNExpect([LastFeed(source)[@"mode"] isEqualToString:@"chrono_priority_only_unreads_v1"], "unread VIP activity with the switch on");
    source.activityUnreadsOnly = NO;
    [shell selectTab:SNTabHome];
    SNExpect(!source.activityVIPOnly, "leaving the tab, the feed (and its peek) is the whole one again");
    [shell selectTab:SNTabActivity];
    SNExpect(source.activityVIPOnly && pane.filter == SNActivityVIP, "coming back keeps the VIP tab");
    [source applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[]}];
    SNExpect(pane.filter == SNActivityAll && !source.activityVIPOnly && [LastFeed(source)[@"mode"] isEqualToString:@"chrono_reads_and_unreads"],
             "without VIPs the tab goes and All shows");
}

SN_TEST(ActivityVIPFiltersNonVIPWebSocketEvents) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    // Priya (U03PRIYA) is a VIP in the public fixture; Sam (U02SAM) is not.
    source.activityVIPOnly = YES;
    SNFlushChanges();
    NSString *nonVIPKey = @"at_user-C01GENERAL-1799000001.000100";
    NSString *reactionKey = @"message_reaction-C01GENERAL-1799000002.000100-tada-U03PRIYA";
    NSString *vipKey = @"at_user-C01GENERAL-1799000003.000100";
    [source applyEvent:@{
        @"type" : @"activity",
        @"subtype" : @"activity_updated",
        @"entry" : @{
            @"is_unread" : @YES,
            @"feed_ts" : @"1799000001.000100",
            @"key" : nonVIPKey,
            @"item" : @{@"type" : @"at_user", @"message" : @{@"ts" : @"1799000001.000100", @"channel" : @"C01GENERAL", @"author_user_id" : @"U02SAM"}},
        },
    }];
    [source applyEvent:@{
        @"type" : @"activity",
        @"subtype" : @"activity_updated",
        @"entry" : @{
            @"is_unread" : @YES,
            @"feed_ts" : @"1799000002.000100",
            @"key" : reactionKey,
            @"item" : @{
                @"type" : @"message_reaction",
                @"message" : @{@"ts" : @"1799000002.000100", @"channel" : @"C01GENERAL", @"author_user_id" : @"U01ALEX"},
                @"reaction" : @{@"user" : @"U03PRIYA", @"name" : @"tada"},
            },
        },
    }];
    [source applyEvent:@{
        @"type" : @"activity",
        @"subtype" : @"activity_updated",
        @"entry" : @{
            @"is_unread" : @YES,
            @"feed_ts" : @"1799000003.000100",
            @"key" : vipKey,
            @"item" : @{@"type" : @"at_user", @"message" : @{@"ts" : @"1799000003.000100", @"channel" : @"C01GENERAL", @"author_user_id" : @"U03PRIYA"}},
        },
    }];
    SNFlushChanges();
    NSArray<NSString *> *keys = [source.activityEntries valueForKey:@"key"];
    SNExpect(![keys containsObject:nonVIPKey], "non-VIP mention is excluded from live VIP feed");
    SNExpect(![keys containsObject:reactionKey], "reaction event is excluded from live VIP feed");
    SNExpect([keys containsObject:vipKey], "VIP mention enters live VIP feed");
}
