// The Activity tab: its feed from what the source has loaded, the filters and the peek; and its
// look beside the capture of its peek.
#import "../net/stub.h"
#import "app/launch.h"
#import "render/format.h"
#import "render/strings.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/activity/pane.h"
#import "ui/kit/popover.h"
#import "ui/shell/shell.h"

/// The first subview of `view` (itself included) of `kind`, depth first.
static id SNFindSubview(NSView *view, Class kind) {
    if ([view isKindOfClass:kind]) return view;
    for (NSView *subview in view.subviews) {
        id found = SNFindSubview(subview, kind);
        if (found) return found;
    }
    return nil;
}

/// A shell on the Activity tab once the feed arrived.
static SNShell *ActivityShell(NSURL *fixture) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(fixture) defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabActivity conversation:shell.location.conversationID thread:nil]];
    SNSettle(0.1);
    return shell;
}

SN_TEST(ActivityShowsTheFeed) {
    SNShell *shell = ActivityShell(SNPublicFixture());
    SNFixtureSource *source = (SNFixtureSource *)shell.source;
    SNActivityPane *pane = (SNActivityPane *)[shell paneForTab:SNTabActivity];
    SNExpect(shell.card.sidebarView == pane.view, "the Activity tab shows its pane in the sidebar column");
    SNExpect(SNWaitUntil(1, ^BOOL { return pane.list.items.count == 4; }), "a short first page brings the next one");
    NSArray<SNActivityListItem *> *all = pane.list.items;
    SNExpect(all.count == source.activityEntries.count, "one row per entry the client shows");
    SNExpect(all[0].unread && !all[1].unread && all[2].unread && !all[3].unread, "unread entries are marked");
    SNExpect(all[2].unreadReplies == 1 && [all[1].reactionName isEqualToString:@"tada"] && all[1].bodyLines == 1, "a thread counts its unread replies, a reaction shows its pill");
    SNExpect([all[0].footer isEqualToString:SNLocalizedFormat(@"activity.footer.mention", @"#design")] &&
                 [all[2].footer isEqualToString:SNLocalizedFormat(@"activity.footer.thread", @"#general")], "where it happened");
    SNExpect(all[0].body && SNWaitUntil(1, ^BOOL { return pane.list.items[3].body != nil; }), "messages not held arrive through messages.list");
    NSUInteger total = 0;
    for (SNActivityFilter filter = SNActivityMentions; filter <= SNActivityReactions; filter++) {
        pane.filter = filter;
        total += pane.list.items.count;
    }
    SNExpect(total == all.count, "the filters split everything");
    pane.filter = SNActivityThreads;
    pane.list.chosen(pane.list.items.firstObject);
    SNExpect([shell.location.threadTS isEqualToString:@"1795192800.000103"], "a thread entry opens its thread");
    pane.filter = SNActivityAll;
    pane.header.unreadsToggle.on = YES;
    pane.header.unreadsToggle.changed(YES);
    SNExpect([source.calls.lastObject[1][@"mode"] isEqualToString:@"chrono_unreads"], "the unreads switch asks for unread entries");
    SNExpect(SNWaitUntil(1, ^BOOL { return pane.list.items.count == 2; }) && pane.list.items[0].unread && pane.list.items[1].unread,
             "and shows them");
    pane.header.unreadsToggle.on = NO;
    pane.header.unreadsToggle.changed(NO);
    [shell selectTab:SNTabHome];
    SNExpect(shell.card.sidebarView != pane.view, "Home brings the sidebar back");
}

SN_TEST(ActivityPeekPagesAndFollowsTheSwitch) {
    SNShell *shell = ActivityShell(SNPublicFixture());
    [shell selectTab:SNTabHome];
    [shell.rail showPeekForTab:SNTabActivity];
    SNSettle(0.3);
    SNActivityListView *list = SNFindSubview(shell.rail.peekPanel, SNActivityListView.class);
    SNExpect(list.style == SNActivityListPeek && list.items.count == 4, "the peek lists the feed");
    shell.source.activityUnreadsOnly = YES;
    SNExpect(SNWaitUntil(1, ^BOOL { return list.items.count == 2; }), "the switch is shared with the tab");
    SNUnreadsToggle *toggle = SNFindSubview(shell.rail.peekPanel, SNUnreadsToggle.class);
    SNExpect(toggle.on, "and shows in the peek's header");
    shell.source.activityUnreadsOnly = NO;
    SNSettle(0.1);
    [shell.rail closePeek];
}

SN_TEST(ActivityRowTimes) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1795300000];
    SNExpect([SNActivityTime([now dateByAddingTimeInterval:-20], now) isEqualToString:SNLocalized(@"activity.time.now")], "under a minute: now");
    SNExpect([SNActivityTime([now dateByAddingTimeInterval:-25 * 60], now) isEqualToString:SNLocalizedFormat(@"activity.time.minutes", 25L)], "under an hour: minutes");
    SNExpect([SNActivityTime([now dateByAddingTimeInterval:-3 * 3600], now) isEqualToString:SNFormatListDate([now dateByAddingTimeInterval:-3 * 3600], now)],
             "then as the lists word dates");
}

SN_SNAPSHOT(ActivityAndItsPeek) {
    // No capture of the official Activity tab or peek exists: the public fixture's feed shows
    // every row kind, read and unread, with the first row hovered.
    SNShell *shell = ActivityShell(SNPublicFixture());
    SNSettle(0.3);
    SNSaveSnapshot(@"activity_window", SNRenderWindow(shell.window));
    [shell selectTab:SNTabHome];
    [shell.rail showPeekForTab:SNTabActivity];
    SNSettle(0.5);
    NSView *peek = shell.rail.peekPanel;
    SNActivityListView *list = SNFindSubview(peek, SNActivityListView.class);
    list.hoveredIndex = 0;
    SNSettle(0.1);
    SNSaveSnapshot(@"activity_peek_window", SNRenderWindow(shell.window));
    [shell.rail closePeek];
}
