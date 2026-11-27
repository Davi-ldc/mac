// The DMs tab against the official app's captures, and its hover and peek states.
#import "app/launch.h"
#import "snapshot.h"
#import "test.h"
#import "ui/dms/pane.h"
#import "ui/kit/popover.h"
#import "ui/shell/shell.h"

/// The captures' clock: the Monday after the newest DMs (their dates read "Sexta-feira").
static NSDate *CaptureDate(void) {
    NSDateComponents *components = [NSDateComponents new];
    components.year = 2026, components.month = 11, components.day = 23, components.hour = 9;
    return [NSCalendar.currentCalendar dateFromComponents:components];
}

/// The window of the captures on the DMs tab with the newest DM open, once the rows' latest
/// messages arrived.
static SNShell *DMsShell(void) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabDirectMessages conversation:source.directMessages.firstObject.conversationID thread:nil]];
    ((SNDMsPane *)[shell paneForTab:SNTabDirectMessages]).list.now = CaptureDate();
    SNSettle(0.1);
    return shell;
}

SN_SNAPSHOT(DMsMatchTheCaptures) {
    SNShell *shell = DMsShell();
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"dms_window", window);

    SNCompareWithReference(@"dms_header", window, @"sidebar_header_dms_default", NSMakePoint(70, 40), 1, @[
        [SNRegion region:@"card edge" rect:NSMakeRect(0, 0, 518, 1) budget:2],
        [SNRegion region:@"title" rect:NSMakeRect(1, 1, 200, 49) budget:8],
        [SNRegion region:@"title row background" rect:NSMakeRect(200, 1, 180, 49) budget:1],
        [SNRegion region:@"unreads switch" rect:NSMakeRect(380, 1, 95, 49) budget:10],
        [SNRegion region:@"compose" rect:NSMakeRect(475, 1, 42, 49) budget:2],
        [SNRegion region:@"filter field" rect:NSMakeRect(1, 50, 516, 28) budget:6],
        [SNRegion region:@"gap and first row" rect:NSMakeRect(1, 78, 516, 12) budget:2],
    ]);

    // Names, pictures and messages are made up; the rows' fills, hairlines and dates are not.
    SNCompareWithReference(@"dms_rows", window, @"sidebar_dm_rows_selected_default", NSMakePoint(70, 122), 2, @[
        [SNRegion region:@"left margin" rect:NSMakeRect(1, 0, 15, 300) budget:1],
        [SNRegion ignored:@"pictures (made up)" rect:NSMakeRect(16, 0, 37, 300)],
        [SNRegion ignored:@"names and previews (made up)" rect:NSMakeRect(53, 0, 380, 300)],
        [SNRegion region:@"dates" rect:NSMakeRect(433, 0, 85, 300) budget:6],
        [SNRegion region:@"hairline 1" rect:NSMakeRect(1, 74, 516, 1) budget:2],
        [SNRegion region:@"hairline 2" rect:NSMakeRect(1, 148, 516, 1) budget:2],
        [SNRegion region:@"hairline 3" rect:NSMakeRect(1, 222, 516, 1) budget:2],
    ]);
}

SN_SNAPSHOT(DMsHoverAndPeek) {
    SNShell *shell = DMsShell();
    SNDMsPane *pane = (SNDMsPane *)[shell paneForTab:SNTabDirectMessages];
    pane.list.hoveredIndex = 2;
    pane.header.composeButton.hovered = YES;
    pane.header.titleButton.hovered = YES;
    SNSettle(0.2);
    SNSaveSnapshot(@"dms_hover", SNRenderWindow(shell.window));

    [shell go:[SNLocation locationWithTab:SNTabHome conversation:shell.location.conversationID thread:nil]];
    [shell.rail showPeekForTab:SNTabDirectMessages];
    SNSettle(0.3);
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"dms_peek_window", window);
    // The capture's rail has a second workspace above the tabs, so its peek sits elsewhere: the
    // comparison follows the peek. Its rows are other people; a tooltip covers part of it there.
    NSView *peek = shell.rail.peekPanel;
    NSRect frame = [shell.window.contentView convertRect:peek.bounds fromView:peek];
    static const NSPoint kCapturePeek = {127.5, 69.5};
    SNCompareWithReference(@"dms_peek", window, @"live/static/h_rail_dms", NSMakePoint(NSMinX(frame) - kCapturePeek.x, NSMinY(frame) - kCapturePeek.y), 0, @[
        [SNRegion ignored:@"another workspace's tooltip" rect:NSMakeRect(55, 100, 192, 43)],
        [SNRegion region:@"header" rect:NSMakeRect(247, 69.5, 240, 44) budget:10],
        [SNRegion region:@"line under the header" rect:NSMakeRect(247, 113.5, 240, 1) budget:3],
        [SNRegion ignored:@"rows (other people)" rect:NSMakeRect(143, 143, 329, 537)],
        [SNRegion region:@"left edge and hairlines" rect:NSMakeRect(127.5, 143, 15, 385) budget:3],
        [SNRegion region:@"right edge and hairlines" rect:NSMakeRect(472, 114.5, 15, 413) budget:3],
    ]);
    [shell.rail closePeek];
}
