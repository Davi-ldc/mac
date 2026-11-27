// The DMs and Activity panes and the Home sidebar do nothing while they are not on screen, and
// on screen remake only the rows that changed.
#import "app/launch.h"
#import "test.h"
#import "ui/activity/pane.h"
#import "ui/dms/pane.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/pane.h"

static NSDictionary *Message(NSString *channel, NSString *ts, NSString *text) {
    return @{@"type" : @"message", @"channel" : channel, @"user" : @"U02SAM", @"text" : text, @"ts" : ts};
}

SN_TEST(PanesIdleWhileHidden) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    SNDMsPane *dms = (SNDMsPane *)[shell paneForTab:SNTabDirectMessages];
    SNActivityPane *activity = (SNActivityPane *)[shell paneForTab:SNTabActivity];
    SNSettle(0.1);
    NSArray *dmItems = dms.list.items, *activityItems = activity.list.items;
    [source applyEvent:Message(@"D05SAM", @"1795400000.000100", @"while hidden")];
    SNSettle(0.05);
    SNExpect(dms.list.items == dmItems && activity.list.items == activityItems, "hidden, the DMs and Activity lists do not change");

    [shell selectTab:SNTabDirectMessages];
    NSUInteger sam = [[dms.list.items valueForKey:@"identifier"] indexOfObject:@"D05SAM"];
    SNExpect(sam != NSNotFound && [dms.list.items[sam].preview.plainText containsString:@"while hidden"], "shown, the DMs list catches up");

    SNSidebarPane *sidebar = (SNSidebarPane *)[shell paneInSlot:SNPaneSlotSidebar];
    NSArray *sidebarItems = sidebar.list.items;
    NSArray<SNDMListItem *> *before = dms.list.items;
    [source applyEvent:Message(@"D05SAM", @"1795400001.000100", @"one more")];
    SNExpect(sidebar.list.items == sidebarItems, "the Home sidebar, hidden behind the DMs tab, does not rebuild");
    NSUInteger changed = 0, kept = 0;
    for (SNDMListItem *item in dms.list.items) {
        if ([before indexOfObjectIdenticalTo:item] != NSNotFound) kept++;
        else changed++;
    }
    SNExpect(changed == 1 && kept == before.count - 1, "only the DM that changed gets a new row");

    [shell selectTab:SNTabHome];
    SNExpect(sidebar.list.items != sidebarItems, "back on Home, the sidebar catches up");
    [shell selectTab:SNTabActivity];
    SNSettle(0.1);
    SNExpect(activity.list.items.count == source.activityEntries.count, "and so does Activity");
}
