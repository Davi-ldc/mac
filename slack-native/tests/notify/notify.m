// Notifications and the dock badge, decided from made-up store state; nothing is delivered to
// the system (the deliver and badge hooks are replaced).
#import "../net/stub.h"
#import "model/json.h"
#import "notify/notify.h"
#import "test.h"

static SNStore *Store(void) {
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:[SNTestAPI new]];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"real_name" : @"Alex Rivera"}},
                             @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"real_name" : @"Sam Chen"}} ]];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES},
                                     @{@"id" : @"C02RANDOM", @"name" : @"random", @"is_channel" : @YES, @"is_member" : @YES},
                                     @{@"id" : @"D05SAM", @"is_im" : @YES, @"user" : @"U02SAM"} ]];
        [store applySections:@[ @{@"channel_section_id" : @"L01", @"type" : @"channels", @"channel_ids_page" : @{@"channel_ids" : @[ @"C01GENERAL", @"C02RANDOM" ]}} ]];
    }];
    return store;
}

static SNMessage *Message(NSString *conversationID, NSString *text) {
    return [SNMessage messageWithJSON:@{@"type" : @"message", @"ts" : @"1795400100.000100", @"user" : @"U02SAM", @"text" : text} conversationID:conversationID];
}

SN_TEST(NotifyDecidesLikeSlack) {
    SNStore *store = Store();
    SNNotifier *notifier = [[SNNotifier alloc] initWithStore:store];
    notifier.showBadge = ^(NSString *label) {};
    SNConversation *general = [store conversationWithID:@"C01GENERAL"], *dm = [store conversationWithID:@"D05SAM"];
    SNExpect([notifier shouldNotify:Message(@"D05SAM", @"hi") inConversation:dm], "a DM notifies");
    SNExpect(![notifier shouldNotify:Message(@"C01GENERAL", @"hi all") inConversation:general], "a channel message without a mention does not");
    SNExpect([notifier shouldNotify:Message(@"C01GENERAL", @"hey <@U01ALEX>") inConversation:general], "a mention does");
    SNExpect([notifier shouldNotify:Message(@"C01GENERAL", @"<!here> standup") inConversation:general], "@here does");
    SNMessage *own = [SNMessage messageWithJSON:@{@"ts" : @"1795400100.000100", @"user" : @"U01ALEX", @"text" : @"me"} conversationID:@"D05SAM"];
    SNExpect(![notifier shouldNotify:own inConversation:dm], "never the user's own");
    SNMessage *join = [SNMessage messageWithJSON:@{@"ts" : @"1795400100.000100", @"user" : @"U02SAM", @"subtype" : @"channel_join", @"text" : @"joined"} conversationID:@"D05SAM"];
    SNExpect(![notifier shouldNotify:join inConversation:dm], "not joins");
    [store applyPreferences:@{@"highlight_words" : @"launch, Rocket"}];
    SNExpect([notifier shouldNotify:Message(@"C01GENERAL", @"the rocket is ready") inConversation:general], "a keyword does");
    [store applyPreferences:@{@"all_notifications_prefs" : @"{\"global\":{\"global_desktop\":\"everything\"},\"channels\":{\"C02RANDOM\":{\"desktop\":\"nothing\"}}}"}];
    SNExpect([notifier shouldNotify:Message(@"C01GENERAL", @"anything") inConversation:general], "everything notifies everything");
    SNExpect(![notifier shouldNotify:Message(@"C02RANDOM", @"<@U01ALEX>") inConversation:[store conversationWithID:@"C02RANDOM"]], "a channel set to nothing never does");
    [store applyPreferences:@{@"muted_channels" : @"C01GENERAL"}];
    SNExpect(![notifier shouldNotify:Message(@"C01GENERAL", @"<@U01ALEX>") inConversation:[store conversationWithID:@"C01GENERAL"]], "muted never notifies");
    [store applyDoNotDisturb:@{@"U01ALEX" : @{@"snooze_enabled" : @YES, @"snooze_endtime" : @(NSDate.date.timeIntervalSince1970 + 600)}}];
    SNExpect(![notifier shouldNotify:Message(@"D05SAM", @"hi") inConversation:dm], "Do Not Disturb silences DMs too");
}

SN_TEST(NotifyLetsVIPsThroughPausedNotifications) {
    SNStore *store = Store();
    [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"plan" : @"std"}];
    SNNotifier *notifier = [[SNNotifier alloc] initWithStore:store];
    notifier.showBadge = ^(NSString *label) {};
    SNConversation *general = [store conversationWithID:@"C01GENERAL"], *dm = [store conversationWithID:@"D05SAM"];
    [store applyDoNotDisturb:@{@"U01ALEX" : @{@"snooze_enabled" : @YES, @"snooze_endtime" : @(NSDate.date.timeIntervalSince1970 + 600)}}];
    [store applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[ @"U02SAM" ]}];
    SNExpect(![notifier shouldNotify:Message(@"D05SAM", @"hi") inConversation:dm], "a VIP stays silent while priority_dnd_override is off");
    [store applyEvent:@{@"type" : @"pref_change", @"name" : @"priority_dnd_override", @"value" : @YES}];
    SNExpect([notifier shouldNotify:Message(@"D05SAM", @"hi") inConversation:dm], "with it on, a VIP's DM gets through");
    SNExpect([notifier shouldNotify:Message(@"C01GENERAL", @"hey <@U01ALEX>") inConversation:general], "and a VIP's mention");
    SNExpect(![notifier shouldNotify:Message(@"C01GENERAL", @"hi all") inConversation:general], "not what would not notify anyway");
    SNMessage *bot = [SNMessage messageWithJSON:@{@"type" : @"message", @"ts" : @"1795400100.000100", @"subtype" : @"bot_message", @"bot_id" : @"B01DEPLOY",
                                                  @"bot_profile" : @{@"id" : @"B01DEPLOY", @"user_id" : @"U02SAM"}, @"text" : @"deploy done <@U01ALEX>"}
                                   conversationID:@"C01GENERAL"];
    SNExpect([notifier shouldNotify:bot inConversation:general], "a bot posting for a VIP gets through");
    [store applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[]}];
    SNExpect(![notifier shouldNotify:Message(@"D05SAM", @"hi") inConversation:dm], "someone no longer a VIP is silenced again");
    [store applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[ @"U02SAM" ]}];
    [store applyPreferences:@{@"muted_channels" : @"C01GENERAL"}];
    SNExpect(![notifier shouldNotify:Message(@"C01GENERAL", @"hey <@U01ALEX>") inConversation:[store conversationWithID:@"C01GENERAL"]], "a muted channel stays muted");
}

SN_TEST(NotifyDeliversReadableText) {
    SNStore *store = Store();
    SNNotifier *notifier = [[SNNotifier alloc] initWithStore:store];
    __block NSArray *delivered;
    notifier.deliver = ^(NSString *identifier, NSString *title, NSString *subtitle, NSString *body, NSDictionary *info) {
        delivered = @[ identifier, title, subtitle ?: @"", body, info ];
    };
    notifier.showBadge = ^(NSString *label) {};
    [store applyEvent:@{@"type" : @"message", @"channel" : @"C01GENERAL", @"ts" : @"1795400100.000100", @"user" : @"U02SAM",
                        @"text" : @"<@U01ALEX> see <#C02RANDOM|random> and <https://example.com|the doc> &amp; more"}];
    SNExpect([delivered[1] isEqualToString:@"Sam Chen"] && [delivered[2] isEqualToString:@"#general"], "sender and channel");
    SNExpect([delivered[3] isEqualToString:@"@Alex Rivera see #random and the doc & more"], "mentions, channels and links made readable");
    SNExpect([delivered[4][@"conversation"] isEqualToString:@"C01GENERAL"], "the click opens the conversation");
}

SN_TEST(NotifyBadgesTheDock) {
    SNStore *store = Store();
    SNNotifier *notifier = [[SNNotifier alloc] initWithStore:store];
    __block NSString *badge = nil;
    notifier.showBadge = ^(NSString *label) { badge = label; };
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C02RANDOM", @"has_unreads" : @YES, @"mention_count" : @0} ]}];
    SNExpect([badge isEqualToString:@"•"], "a dot for unread without mentions");
    [store applyNewestHistory:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400100.000100", @"user" : @"U02SAM", @"text" : @"hi"} ], @"has_more" : @NO}
               inConversation:@"D05SAM"];
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"has_unreads" : @YES, @"mention_count" : @2} ],
                         @"ims" : @[ @{@"id" : @"D05SAM", @"last_read" : @"1795400000.000100", @"has_unreads" : @YES, @"mention_count" : @1} ]}];
    SNExpect([badge isEqualToString:@"3"], "mentions and DMs counted");
    [store applyPreferences:@{@"muted_channels" : @"C01GENERAL,C02RANDOM"}];
    SNExpect([badge isEqualToString:@"1"], "muted conversations leave the badge");
    [store markConversation:@"D05SAM" readThrough:@"1795400100.000100"];
    SNExpect([notifier.badgeLabel isEqualToString:@""], "nothing unread, no badge");
}
