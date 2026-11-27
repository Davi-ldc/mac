// The DMs tab with VIPs on the public fixture (a paid plan; Priya is a VIP and in the unread group
// DM): unread DMs with a VIP float to the top under "VIP unreads", then "Everything else".
#import "app/launch.h"
#import "render/strings.h"
#import "test.h"
#import "ui/dms/pane.h"
#import "ui/shell/shell.h"

static NSArray<NSString *> *Identifiers(NSArray<SNDMListItem *> *items) {
    NSMutableArray *ids = [NSMutableArray new];
    for (SNDMListItem *item in items) [ids addObject:item.identifier];
    return ids;
}

SN_TEST(DMsFloatUnreadVIPsToTheTop) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    SNDMsPane *dms = (SNDMsPane *)[shell paneForTab:SNTabDirectMessages];
    [shell selectTab:SNTabDirectMessages];
    SNSettle(0.1);
    NSArray *ids = Identifiers(dms.list.items);
    SNExpect(ids.count > 3 && [ids[0] isEqualToString:@"header:dms.vip"] && [ids[1] isEqualToString:@"G07MPDM"] && [ids[2] isEqualToString:@"header:dms.everything"],
             "the unread group DM with Priya under VIP unreads, the rest under Everything else");
    SNExpect(dms.list.items[0].header && dms.list.items[0].rule && !dms.list.items[2].rule, "VIP unreads has the line over it");
    [source applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[ @"U02SAM" ]}];
    SNSettle(0.05);
    ids = Identifiers(dms.list.items);
    NSSet *floated = [NSSet setWithArray:[ids subarrayWithRange:NSMakeRange(1, 2)]], *expected = [NSSet setWithObjects:@"D05SAM", @"G07MPDM", nil];
    SNExpect([floated isEqualToSet:expected] && [ids[3] isEqualToString:@"header:dms.everything"], "with Sam a VIP, his unread DM floats too, and the group DM he is in stays");
    [source applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[]}];
    SNSettle(0.05);
    SNExpect(![Identifiers(dms.list.items) containsObject:@"header:dms.vip"], "without VIPs, the plain list");
}

SN_TEST(DMsSectionHeadersRefreshOnLanguageChange) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shellEN = [[SNShell alloc] initWithSource:source defaults:nil];
    SNDMsPane *dmsEN = (SNDMsPane *)[shellEN paneForTab:SNTabDirectMessages];
    [shellEN selectTab:SNTabDirectMessages];
    SNSettle(0.05);
    NSString *enTitle = dmsEN.list.items.firstObject.title;

    SNSetLanguage(@"pt-BR");
    SNShell *shellPT = [[SNShell alloc] initWithSource:source defaults:nil];
    SNDMsPane *dmsPT = (SNDMsPane *)[shellPT paneForTab:SNTabDirectMessages];
    [shellPT selectTab:SNTabDirectMessages];
    SNSettle(0.05);
    NSString *ptTitle = dmsPT.list.items.firstObject.title;
    SNExpect(enTitle.length && ptTitle.length && ![enTitle isEqualToString:ptTitle] && [ptTitle isEqualToString:SNLocalized(@"dms.vip")],
             "DMs VIP section header updates cleanly when language changes");
    SNSetLanguage(@"en");
}
