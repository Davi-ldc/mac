// The conversation column against the official app's captures, its hover states, and the
// public fixture's design channel with every render element.
#import "app/launch.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/channel/pane.h"
#import "ui/kit/dialog.h"
#import "ui/kit/tooltip.h"
#import "ui/right/thread.h"
#import "ui/shell/shell.h"

/// The window of the captures: the private fixture's newest DM open on the DMs tab, the window
/// in the background.
static SNShell *ReferenceShell(void) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabDirectMessages conversation:source.directMessages.firstObject.conversationID thread:nil]];
    return shell;
}

static SNChannelPane *ChannelPane(SNShell *shell) { return (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]; }

/// Where a message's row is in the window, in points from the top-left.
static NSPoint RowOrigin(SNShell *shell, NSString *ts) {
    SNMessageRowView *row = [ChannelPane(shell).list rowForTS:ts];
    if (!row) return NSZeroPoint;
    NSRect rect = [row convertRect:row.bounds toView:nil];
    return NSMakePoint(NSMinX(rect), shell.window.contentView.bounds.size.height - NSMaxY(rect));
}

static NSString *TSOfText(id<SNSource> source, NSString *conversationID, NSString *prefix) {
    for (SNMessage *message in [source messagesInConversation:conversationID])
        if ([message.text hasPrefix:prefix]) return message.ts;
    return nil;
}

SN_SNAPSHOT(ChannelMatchesTheCaptures) {
    SNShell *shell = ReferenceShell();
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"channel_window", window);
    id<SNSource> source = shell.source;
    NSString *conversationID = shell.location.conversationID;

    SNCompareWithReference(@"channel_header", window, @"channel_header_tabs_default", NSMakePoint(587, 40), 1, @[
        // The star sits half a point higher than the capture's.
        [SNRegion region:@"star" rect:NSMakeRect(18, 12, 30, 28) budget:12],
        [SNRegion ignored:@"avatar and name (made-up person)" rect:NSMakeRect(52, 8, 150, 36)],
        [SNRegion region:@"empty header" rect:NSMakeRect(210, 4, 420, 44) budget:1],
        [SNRegion region:@"icon buttons" rect:NSMakeRect(640, 10, 190, 32) budget:4],
        [SNRegion region:@"tabs" rect:NSMakeRect(16, 52, 400, 30) budget:15],
        [SNRegion region:@"selected tab underline" rect:NSMakeRect(17, 84, 100, 3) budget:5],
        [SNRegion region:@"tab bar line" rect:NSMakeRect(130, 86, 700, 2) budget:2],
    ]);

    NSPoint row = RowOrigin(shell, TSOfText(source, conversationID, @"Só preciso"));
    SNCompareWithReference(@"channel_message_row", window, @"message_row_default", row, 4, @[
        [SNRegion ignored:@"avatar (made-up picture)" rect:NSMakeRect(16, 6, 38, 40)],
        // The time follows the made-up name, so it moves with it (RenderLayoutGeometry checks the gap).
        [SNRegion ignored:@"name and time (made-up person)" rect:NSMakeRect(58, 4, 120, 24)],
        [SNRegion ignored:@"text (made-up words)" rect:NSMakeRect(58, 26, 300, 54)],
        [SNRegion region:@"background" rect:NSMakeRect(360, 0, 480, 80) budget:1],
    ]);
    SNCompareWithReference(@"channel_message_grouped", window, @"message_grouped_two_lines", NSMakePoint(row.x, row.y - 5), 6, @[
        [SNRegion ignored:@"avatar (made-up picture)" rect:NSMakeRect(16, 0, 38, 40)],
        [SNRegion ignored:@"name and text (made-up)" rect:NSMakeRect(58, 0, 300, 70)],
        [SNRegion region:@"background" rect:NSMakeRect(360, 0, 480, 70) budget:1],
    ]);
    NSPoint chip = RowOrigin(shell, TSOfText(source, conversationID, @"<https://github"));
    SNCompareWithReference(@"channel_link_chip", window, @"message_link_chip", chip, 4, @[
        [SNRegion ignored:@"avatar, name and time (made-up person)" rect:NSMakeRect(16, 4, 160, 40)],
        [SNRegion region:@"chip start" rect:NSMakeRect(60, 26, 22, 20) budget:18],
        [SNRegion ignored:@"chip text (made-up URL)" rect:NSMakeRect(82, 26, 300, 20)],
        [SNRegion region:@"background" rect:NSMakeRect(400, 0, 440, 50) budget:1],
    ]);
    NSPoint day = RowOrigin(shell, TSOfText(source, conversationID, @"Bom dia"));
    // This crop starts at the column divider, 1 pt left of the pane.
    SNCompareWithReference(@"channel_date_divider", window, @"date_divider_sticky_pill", NSMakePoint(587, day.y - 43), 4, @[
        [SNRegion region:@"line" rect:NSMakeRect(0, 18, 300, 6) budget:2],
        [SNRegion region:@"pill" rect:NSMakeRect(314, 4, 216, 32) budget:12],
        [SNRegion region:@"line right" rect:NSMakeRect(540, 18, 300, 6) budget:2],
        [SNRegion ignored:@"next message (made-up)" rect:NSMakeRect(0, 46, 848, 14)],
    ]);
    [SNTooltip hide];
}

SN_SNAPSHOT(ChannelSharedCardUnderStickyPill) {
    SNShell *shell = ReferenceShell();
    // A shorter window makes the short fixture scroll the way the captured history did.
    [shell.window setContentSize:NSMakeSize(SNWindowDefaultSize.width, 440)];
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNMessageListView *list = ChannelPane(shell).list;
    NSString *ts = TSOfText(shell.source, shell.location.conversationID, @"Encaminhando");
    [list scrollToOffset:0];
    SNMessageRowView *row = [list rowForTS:ts];
    // Captured with the card's bottom edge 114 pt under the list's top and the day's pill pinned.
    // The body's height is rounded up from the card's 22.5 pt lines: its edge is 0.5 pt above the row's spacer.
    CGFloat offset = NSMaxY(row.frame) - 4 - 0.5 - 114;
    [list scrollToOffset:offset];
    SNExpect(fabs(list.scrollView.contentView.bounds.origin.y - offset) < 0.5, "the list scrolls to the captured place");
    NSRect top = [list convertRect:list.bounds toView:nil];
    SNPixels *window = SNRenderWindow(shell.window);
    SNCompareWithReference(@"channel_shared_card", window, @"message_shared_quote_card_with_sticky_date_pill",
                           NSMakePoint(588, shell.window.contentView.bounds.size.height - NSMaxY(top)), 4, @[
        [SNRegion ignored:@"text (made-up words)" rect:NSMakeRect(60, 30, 720, 74)],
        [SNRegion region:@"pinned pill" rect:NSMakeRect(314, 4, 216, 32) budget:12],
        [SNRegion region:@"card left border" rect:NSMakeRect(58, 0, 6, 110) budget:5],
        [SNRegion region:@"card bottom" rect:NSMakeRect(66, 108, 700, 8) budget:5],
        [SNRegion region:@"background right" rect:NSMakeRect(790, 0, 50, 115) budget:2],
    ]);
}

SN_SNAPSHOT(ChannelHoverStates) {
    SNShell *shell = ReferenceShell();
    [shell setWindowActive:YES];
    SNChannelPane *pane = ChannelPane(shell);
    id<SNSource> source = shell.source;
    NSString *conversationID = shell.location.conversationID;
    NSString *grouped = TSOfText(source, conversationID, @"quem");
    [pane.list hoverMessageTS:grouped];
    SNSettle(0.2);
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"channel_hover_row", window);
    NSPoint row = RowOrigin(shell, grouped);
    SNExpect([window colorAtPoint:NSMakePoint(row.x + 500, row.y + 15)] >> 8 == SNMeasuredMessageRowHover >> 8, "hovered row is #222529 (live)");
    NSRect bar = [pane.list.actionBar convertRect:pane.list.actionBar.bounds toView:nil];
    CGFloat barTop = shell.window.contentView.bounds.size.height - NSMaxY(bar);
    SNExpect(fabs(barTop - (row.y - 16)) < 0.5 && bar.size.height == 40, "action bar 40 pt tall, 16 pt above the row (live)");
    SNExpect(fabs(NSMaxX(bar) - (NSMaxX([pane.view convertRect:pane.view.bounds toView:nil]) - 21)) < 0.5, "action bar 21 pt from the pane's right (live)");
    NSView *add = pane.list.actionBar.buttons[3];
    ((SNHoverView *)add).hovered = YES;
    SNSettle(0.3);
    SNSaveSnapshot(@"channel_hover_action", SNRenderWindow(shell.window));
    ((SNHoverView *)add).hovered = NO;
    [pane.list hoverMessageTS:nil];
    [SNTooltip hide];
    ((SNHoverView *)pane.header.tabs[1]).hovered = YES;
    pane.header.more.hovered = YES;
    pane.header.bell.hovered = YES;
    SNSettle(0.1);
    SNPixels *header = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"channel_hover_header", header);
    NSRect kebab = [pane.header.more convertRect:pane.header.more.bounds toView:nil];
    SNExpect([header colorAtPoint:NSMakePoint(NSMinX(kebab) + 3, shell.window.contentView.bounds.size.height - NSMaxY(kebab) + 14)] >> 8 ==
                 SNMeasuredHeaderKebabHover >> 8,
             "hovered kebab is #2c2e31 (live)");
    [SNTooltip hide];
}

SN_SNAPSHOT(ChannelActionBarMatchesTheCapture) {
    SNShell *shell = ReferenceShell();
    [shell setWindowActive:YES];
    SNChannelPane *pane = ChannelPane(shell);
    [pane.list hoverMessageTS:TSOfText(shell.source, shell.location.conversationID, @"quem")];
    SNSettle(0.2);
    SNPixels *window = SNRenderWindow(shell.window);
    NSRect bar = [pane.list.actionBar convertRect:pane.list.actionBar.bounds toView:nil];
    // The capture's bar starts at (14, 81) of its crop. Its message has replies, so a summary
    // button comes before "more"; this one's does not, so "more" is compared one button left.
    NSPoint origin = NSMakePoint(NSMinX(bar) - 14, shell.window.contentView.bounds.size.height - NSMaxY(bar) - 81);
    SNCompareWithReference(@"channel_action_bar", window, @"live/actionbar/a_ab_buttons/f000", origin, 2, @[
        [SNRegion ignored:@"quick reactions (emoji pictures)" rect:NSMakeRect(18, 85, 96, 32)],
        [SNRegion region:@"react, reply, forward, task" rect:NSMakeRect(114, 85, 128, 32) budget:2],
    ]);
    SNCompareWithReference(@"channel_action_bar_more", window, @"live/actionbar/a_ab_buttons/f000", NSMakePoint(origin.x - 32, origin.y), 2, @[
        [SNRegion region:@"more" rect:NSMakeRect(274, 85, 32, 32) budget:4],
    ]);
}

SN_SNAPSHOT(ChannelPublicDesignChannel) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]];
    SNChannelPane *pane = ChannelPane(shell);
    SNSaveSnapshot(@"channel_public_bottom", SNRenderWindow(shell.window));
    for (int page = 1; page <= 4; page++) {
        CGFloat height = pane.list.scrollView.contentView.bounds.size.height;
        [pane.list scrollToOffset:pane.list.contentHeight - height * (page + 1)];
        SNSaveSnapshot([NSString stringWithFormat:@"channel_public_page%d", page], SNRenderWindow(shell.window));
    }
    NSString *reacted = TSOfText(source, @"C03DESIGN", @"reacted");
    [pane.list scrollToBottom];
    [pane.list hoverMessageTS:reacted];
    SNMessageRowView *row = [pane.list rowForTS:reacted];
    ((SNHoverView *)row.pills[0]).hovered = YES;
    ((SNHoverView *)row.replyBar).hovered = YES;
    SNSettle(0.5);
    SNSaveSnapshot(@"channel_public_reactions_hover", SNRenderWindow(shell.window));
    ((SNHoverView *)row.pills[0]).hovered = NO;
    [shell openThread:reacted inConversation:@"C03DESIGN"];
    SNSaveSnapshot(@"channel_public_thread", SNRenderWindow(shell.window));
    [SNTooltip hide];
}

/// No capture has these (editing and deleting were not safe to do live): renders to look at.
SN_SNAPSHOT(ChannelEditDeleteAndFailedSend) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]];
    SNMessageListView *list = ChannelPane(shell).list;
    [source sendText:@"Shipping the *new* tokens today, review welcome" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNSettle(0.1);
    SNMessage *own = [source messagesInConversation:@"C03DESIGN"].lastObject;
    source.failsRequests = YES;
    [source sendText:@"this one never arrives" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNSettle(0.1);
    SNSaveSnapshot(@"channel_failed_send", SNRenderWindow(shell.window));
    source.failsRequests = NO;
    [list editMessage:own];
    SNSaveSnapshot(@"channel_edit_inline", SNRenderWindow(shell.window));
    [list.editor cancel];
    [list confirmDeleteOfMessage:own];
    SNSettle(0.2);
    SNSaveSnapshot(@"channel_delete_dialog", SNRenderWindow(shell.window));
    [SNConfirmDialog.current cancel];
}
