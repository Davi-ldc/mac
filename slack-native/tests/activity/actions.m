// The Activity rows' hover actions: the buttons ActivityRowContentActions shows per entry, their
// requests as the web client sends them (activity.markRead, activity.markUnread, activity.archive,
// saved.add, saved.delete; values made up), and the bar drawn as the client's CSS places it.
#import "../net/stub.h"
#import "app/launch.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/activity/pane.h"
#import "ui/kit/popover.h"
#import "ui/shell/shell.h"

static NSDictionary *LastCall(SNFixtureSource *source, NSString *method) {
    for (NSArray *call in source.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:method]) return call[1];
    return nil;
}

static SNShell *ActivityShell(void) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabActivity conversation:shell.location.conversationID thread:nil]];
    SNActivityPane *pane = (SNActivityPane *)[shell paneForTab:SNTabActivity];
    SNWaitUntil(2, ^BOOL { return pane.list.items.count == 4; });
    return shell;
}

/// Each channel of two 0xRRGGBBAA colours within `tolerance`.
static BOOL Near(uint32_t a, uint32_t b, int tolerance) {
    for (int shift = 8; shift < 32; shift += 8)
        if (abs((int)((a >> shift) & 0xff) - (int)((b >> shift) & 0xff)) > tolerance) return NO;
    return YES;
}

static NSArray<NSNumber *> *Actions(SNActivityActionBar *bar) { return bar.actions; }

SN_TEST(ActivityActionsSendTheWebClientsRequests) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    [source loadActivity];
    SNWaitUntil(2, ^BOOL { return source.activityEntries.count == 3; });
    SNActivityEntry *mention = source.activityEntries[0], *reaction = source.activityEntries[1], *thread = source.activityEntries[2];

    [source markActivityEntry:mention read:YES];
    NSDictionary *read = LastCall(source, @"activity.markRead");
    SNExpect(!source.activityEntries[0].isUnread, "read at once");
    SNExpect([read isEqualToDictionary:(@{@"type" : @"at_user", @"key" : @"at_user-C03DESIGN-1795300444.000012", @"feed_ts" : @"1795300600.000000",
                                          @"_x_reason" : @"mark-as-read-v2"})],
             "activity.markRead with the item's type, key and feed_ts");
    [source markActivityEntry:source.activityEntries[0] read:NO];
    NSDictionary *unread = LastCall(source, @"activity.markUnread");
    NSArray *entries = [NSJSONSerialization JSONObjectWithData:[unread[@"entries"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    SNExpect(source.activityEntries[0].isUnread && [unread[@"_x_reason"] isEqualToString:@"mark-as-unread"] &&
                 [entries isEqualToArray:(@[ @{@"type" : @"at_user", @"key" : @"at_user-C03DESIGN-1795300444.000012", @"ts" : @"1795300600.000000",
                                               @"feed_ts" : @"1795300600.000000"} ])],
             "activity.markUnread with the entries as JSON");

    NSUInteger calls = source.calls.count;
    [source markActivityEntry:reaction read:NO];
    SNExpect(source.calls.count == calls, "a reaction is never sent");

    source.failsRequests = YES;
    [source markActivityEntry:thread read:YES];
    SNExpect(!source.activityEntries[2].isUnread, "read before Slack answers");
    SNWaitUntil(2, ^BOOL { return source.activityEntries.count == 3 && source.activityEntries[2].isUnread; });
    SNExpect(source.activityEntries[2].isUnread, "unread again when Slack refuses");
    source.failsRequests = NO;
    SNWaitUntil(2, ^BOOL { return !source.isLoadingActivity; });

    [source clearActivityEntry:source.activityEntries[2]];
    NSDictionary *archive = LastCall(source, @"activity.archive");
    SNExpect(source.activityEntries.count == 2 && [archive isEqualToDictionary:(@{@"type" : @"thread_v2", @"key" : @"thread_v2-C01GENERAL-1795192800.000103",
                                                                                   @"ts" : @"1795194600.000107", @"_x_reason" : @"clear_notification_button"})],
             "Clear: activity.archive, the entry gone at once");

    SNExpect(![source isMessageSavedWithTS:mention.messageTS inConversation:mention.conversationID], "not saved");
    [source setSaved:YES messageWithTS:mention.messageTS inConversation:mention.conversationID];
    SNExpect([source isMessageSavedWithTS:mention.messageTS inConversation:mention.conversationID] &&
                 [LastCall(source, @"saved.add") isEqualToDictionary:(@{@"item_type" : @"message", @"item_id" : @"C03DESIGN", @"ts" : @"1795300444.000012",
                                                                         @"_x_reason" : @"saved-api/saveMessage"})],
             "Save for later: saved.add");
    [source setSaved:NO messageWithTS:mention.messageTS inConversation:mention.conversationID];
    SNExpect(![source isMessageSavedWithTS:mention.messageTS inConversation:mention.conversationID] &&
                 [LastCall(source, @"saved.delete")[@"_x_reason"] isEqualToString:@"saved-api/removeSavedMessage"],
             "Remove from Later: saved.delete");
}

SN_TEST(ActivityRowsOfferTheirActions) {
    SNShell *shell = ActivityShell();
    SNFixtureSource *source = (SNFixtureSource *)shell.source;
    SNActivityPane *pane = (SNActivityPane *)[shell paneForTab:SNTabActivity];
    SNActivityListView *list = pane.list;
    [list layoutSubtreeIfNeeded];
    SNExpect(list.actionBar.hidden, "no actions until a row is hovered");
    list.hoveredIndex = 0;
    SNExpect(!list.actionBar.hidden && [Actions(list.actionBar) isEqualToArray:(@[ @(SNActivityActionMarkRead), @(SNActivityActionClear), @(SNActivityActionMore) ])],
             "an unread row: Mark as read, Clear, More actions");
    list.hoveredIndex = 1;
    SNExpect([Actions(list.actionBar) isEqualToArray:(@[ @(SNActivityActionClear), @(SNActivityActionMore) ])], "a read reaction cannot be marked unread");
    list.hoveredIndex = 3;
    SNExpect([Actions(list.actionBar) isEqualToArray:(@[ @(SNActivityActionMarkUnread), @(SNActivityActionClear), @(SNActivityActionMore) ])],
             "another read row can");
    list.hoveredIndex = 0;
    list.actionChosen(list.items[0], SNActivityActionMarkRead, NSZeroRect);
    SNExpect(LastCall(source, @"activity.markRead") && SNWaitUntil(1, ^BOOL { return !pane.list.items[0].unread; }), "Mark as read reads the row");
    [list layoutSubtreeIfNeeded];
    SNExpect([Actions(list.actionBar) containsObject:@(SNActivityActionMarkUnread)], "and its actions follow");
    list.actionChosen(list.items[0], SNActivityActionMore, NSMakeRect(300, 40, 32, 32));
    SNExpect(SNPopover.current && list.holdsHover, "More actions opens the menu and the row keeps its actions");
    list.hoveredIndex = 2;
    SNExpect([Actions(list.actionBar) containsObject:@(SNActivityActionMarkUnread)], "the pointer elsewhere changes nothing while it is open");
    [SNPopover.current close];
    SNExpect(!list.holdsHover, "closing it lets the actions follow the pointer again");
}

SN_SNAPSHOT(ActivityActionsAsTheClientsCSS) {
    // No capture of the Activity rows exists: the bar is checked against the client's CSS
    // (activity_multi_line_row_content__actions_toggle, activity_row_content__actions).
    SNShell *shell = ActivityShell();
    SNActivityPane *pane = (SNActivityPane *)[shell paneForTab:SNTabActivity];
    SNActivityListView *list = pane.list;
    SNSettle(0.3);
    list.hoveredIndex = 2;
    ((SNHoverView *)list.actionBar.buttons[1]).hovered = YES;
    SNSettle(0.2);
    SNPixels *pixels = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"activity_actions", pixels);
    NSRect row = [[list rowAtIndex:2] convertRect:[list rowAtIndex:2].bounds toView:nil];
    NSRect bar = [list.actionBar convertRect:list.actionBar.bounds toView:nil];
    CGFloat windowHeight = NSHeight(shell.window.contentView.bounds);
    CGFloat rowTop = windowHeight - NSMaxY(row), barTop = windowHeight - NSMaxY(bar), barBottom = windowHeight - NSMinY(bar);
    SNExpect(fabs(barBottom - (rowTop + 12 + 2)) < 0.01, "the bar's bottom 2 pt into the row's content, which starts after its 12 pt padding");
    SNExpect(fabs(NSMaxX(bar) - (NSMaxX(row) - 20 + 4)) < 0.01, "its right edge 4 pt past the content's, 20 pt in from the row's");
    SNExpect(NSWidth(bar) == 4 + 3 * 32 + 4 && NSHeight(bar) == 40, "three 32 pt buttons in 4 pt of padding");
    CGFloat midY = barTop + 20;
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(NSMinX(bar) + 2.5, midY)], SNColorBasePry, 6), "base-pry inside");
    uint32_t hovered = [pixels colorAtPoint:NSMakePoint(NSMinX(bar) + 4 + 32 + 2, midY)], plain = [pixels colorAtPoint:NSMakePoint(NSMinX(bar) + 4 + 2 * 32 + 2, midY)];
    SNExpect(hovered != plain && Near(hovered, 0x222529ff, 4), "the hovered button takes the 4% fill");
    list.hoveredIndex = 0;
    SNSettle(0.1);
    NSRect first = [list.actionBar convertRect:list.actionBar.bounds toView:nil];
    NSRect firstRow = [[list rowAtIndex:0] convertRect:[list rowAtIndex:0].bounds toView:nil];
    SNExpect(fabs((windowHeight - NSMaxY(first)) - (windowHeight - NSMaxY(firstRow) + 12 + 4)) < 0.01, "the first row's sits 4 pt into its content");
}
