// The popups against the settled frame of each live capture (design/ref/live/<group>/<name>):
// the rail's DMs peek, the workspace menu, the search modal, a message's more-actions menu, the
// files tab's preview and tooltips. Most captures are 1x crops of the window at `rect` (their
// timeline.txt); those compare with the render scaled down to 1x. They were taken with another
// workspace's column left of the rail, so each comparison follows the popup's anchor instead of
// window coordinates. Content that names other people or workspaces is left out.
#import "app/launch.h"
#import "snapshot.h"
#import "test.h"
#import "ui/channel/actionbar.h"
#import "ui/channel/header.h"
#import "ui/channel/list.h"
#import "ui/channel/pane.h"
#import "ui/files/peek.h"
#import "ui/kit/popover.h"
#import "ui/kit/tooltip.h"
#import "ui/shell/search.h"
#import "ui/shell/shell.h"
#import "ui/shell/topbar.h"
#import "ui/sidebar/header.h"
#import "ui/sidebar/pane.h"

/// The window of the captures: the private fixture on the DMs tab with the newest DM open, the
/// window in the background like when they were taken.
static SNShell *CaptureShell(void) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabDirectMessages conversation:source.directMessages.firstObject.conversationID thread:nil]];
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

/// 2x2 pixel boxes averaged: the render at the 1x captures' scale.
static SNPixels *Halved(SNPixels *pixels) {
    SNPixels *half = [[SNPixels alloc] initWithWidth:pixels.width / 2 height:pixels.height / 2];
    for (size_t y = 0; y < half.height; y++)
        for (size_t x = 0; x < half.width; x++)
            for (int channel = 0; channel < 4; channel++) {
                const uint8_t *a = pixels.bytes + ((2 * y) * pixels.width + 2 * x) * 4 + channel, *b = a + pixels.width * 4;
                half.bytes[(y * half.width + x) * 4 + channel] = (uint8_t)((a[0] + a[4] + b[0] + b[4] + 2) / 4);
            }
    return half;
}

/// Compares the window with the 1x capture `frame`, a crop of the capture's window at
/// `cropOrigin`, matching the capture's point `theirs` with our window's point `ours` (the
/// popup's corner, its anchor). Regions are in the capture's window points.
static void CompareWithFrame(NSString *name, SNPixels *window, NSString *frame, NSPoint cropOrigin, NSPoint theirs, NSPoint ours,
                             CGFloat slack, NSArray<SNRegion *> * (^regions)(NSRect (^crop)(NSRect rect))) {
    // SNCompareWithReference measures in points of 2 pixels; at 1x a pixel is half of one.
    NSPoint origin = NSMakePoint((ours.x - theirs.x + cropOrigin.x) / 2, (ours.y - theirs.y + cropOrigin.y) / 2);
    NSArray *parts = regions(^NSRect(NSRect rect) {
        return NSMakeRect((rect.origin.x - cropOrigin.x) / 2, (rect.origin.y - cropOrigin.y) / 2, rect.size.width / 2, rect.size.height / 2);
    });
    SNCompareWithReference(name, Halved(window), frame, origin, slack / 2, parts);
}

static NSRect WindowFrame(NSView *view) {
    NSRect rect = [view convertRect:view.bounds toView:nil];
    return NSMakeRect(NSMinX(rect), view.window.contentView.bounds.size.height - NSMaxY(rect), NSWidth(rect), NSHeight(rect));
}

static void Report(NSString *name, NSRect frame) {
    printf("%s at %.1f,%.1f %.1fx%.1f\n", name.UTF8String, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
}

SN_SNAPSHOT(PopupsDMsPeek) {
    SNShell *shell = CaptureShell();
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:shell.location.conversationID thread:nil]];
    [shell.rail showPeekForTab:SNTabDirectMessages];
    SNSettle(0.3);
    NSRect peek = WindowFrame(shell.rail.peekPanel);
    Report(@"dms peek", peek);
    // b4_dms_peek: the peek's box at 127,69.5 (360 wide), 52 pt above the DMs tile; rows are
    // other people.
    CompareWithFrame(@"popups_dms_peek", SNRenderWindow(shell.window), @"live/misc/b4_dms_peek/f390", NSMakePoint(60, 40), NSMakePoint(127, 69.5), peek.origin, 2,
                     ^NSArray *(NSRect (^crop)(NSRect)) {
                         return @[
                             [SNRegion ignored:@"rail and sidebar around it" rect:crop(NSMakeRect(60, 40, 66, 600))],
                             [SNRegion region:@"header" rect:crop(NSMakeRect(128, 70, 359, 44)) budget:12],
                             [SNRegion region:@"line under the header" rect:crop(NSMakeRect(128, 114, 359, 1)) budget:3],
                             [SNRegion ignored:@"rows (other people)" rect:crop(NSMakeRect(128, 115, 359, 525))],
                             [SNRegion region:@"ring and corner" rect:crop(NSMakeRect(126, 68, 20, 20)) budget:12],
                         ];
                     });
    [shell.rail closePeek];
}

SN_SNAPSHOT(PopupsWorkspaceMenu) {
    SNShell *shell = CaptureShell();
    SNSidebarPane *sidebar = (SNSidebarPane *)[shell paneInSlot:SNPaneSlotSidebar];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:shell.location.conversationID thread:nil]];
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNHoverView *title = sidebar.header.titleButton;
    title.hovered = YES;
    title.action(title);
    NSRect menu = WindowFrame(SNPopover.current.content);
    Report(@"workspace menu", menu);
    // m_ws_open: the menu's box at 118,90 (322 x 467.5 with its ring) under a title whose text
    // starts at 148; ours starts 60 pt further left.
    NSRect titleFrame = WindowFrame(title);
    Report(@"sidebar title", titleFrame);
    CompareWithFrame(@"popups_workspace_menu", SNRenderWindow(shell.window), @"live/click/m_ws_open/f161", NSMakePoint(131, 40), NSMakePoint(118, 90), menu.origin, 2,
                     ^NSArray *(NSRect (^crop)(NSRect)) {
                         return @[
                             [SNRegion ignored:@"workspace icon and name (made up)" rect:crop(NSMakeRect(131, 91, 300, 72))],
                             [SNRegion region:@"plan note" rect:crop(NSMakeRect(131, 164, 300, 64)) budget:12],
                             [SNRegion region:@"upsell" rect:crop(NSMakeRect(131, 229, 300, 115)) budget:12],
                             [SNRegion ignored:@"invite (names the workspace)" rect:crop(NSMakeRect(131, 344, 300, 45))],
                             [SNRegion region:@"preferences and tools" rect:crop(NSMakeRect(131, 389, 300, 72)) budget:10],
                             [SNRegion region:@"mobile app and sign out" rect:crop(NSMakeRect(131, 462, 300, 95)) budget:10],
                             [SNRegion ignored:@"sidebar and content around it" rect:crop(NSMakeRect(131, 557, 560, 183))],
                         ];
                     });
    [SNPopover.current close];
}

SN_SNAPSHOT(PopupsSearchModal) {
    SNShell *shell = CaptureShell();
    [shell openSearch];
    SNSettle(0.1);
    NSRect modal = WindowFrame(SNSearchModal.current);
    Report(@"search modal", modal);
    Report(@"search field", WindowFrame(shell.topBar.searchField));
    SNPixels *window = SNRenderWindow(shell.window);
    // s_search_open: the modal's inside spans 408-1047 from y 4 over a 570 pt field at 442.5; the
    // field here is wider, so the left and right parts compare apart. Recent places are other people.
    CompareWithFrame(@"popups_search_left", window, @"live/click/s_search_open/f172", NSMakePoint(300, 0), NSMakePoint(408, 4), modal.origin, 2,
                     ^NSArray *(NSRect (^crop)(NSRect)) {
                         return @[
                             [SNRegion region:@"query row" rect:crop(NSMakeRect(408, 4, 400, 48)) budget:10],
                             [SNRegion region:@"ai note" rect:crop(NSMakeRect(428, 65, 400, 71)) budget:12],
                             [SNRegion region:@"heading" rect:crop(NSMakeRect(408, 136, 400, 48)) budget:8],
                             [SNRegion ignored:@"recent places (other people)" rect:crop(NSMakeRect(408, 184, 400, 200))],
                             [SNRegion region:@"footer" rect:crop(NSMakeRect(408, 396, 400, 46)) budget:10],
                             [SNRegion ignored:@"window right of the left part" rect:crop(NSMakeRect(808, 0, 392, 560))],
                             [SNRegion ignored:@"window left and below" rect:crop(NSMakeRect(300, 0, 106, 560))],
                             [SNRegion ignored:@"window below" rect:crop(NSMakeRect(406, 443, 402, 117))],
                         ];
                     });
    CompareWithFrame(@"popups_search_right", window, @"live/click/s_search_open/f172", NSMakePoint(300, 0), NSMakePoint(1048, 4), NSMakePoint(NSMaxX(modal), NSMinY(modal)), 2,
                     ^NSArray *(NSRect (^crop)(NSRect)) {
                         return @[
                             [SNRegion region:@"query row's buttons" rect:crop(NSMakeRect(940, 4, 107, 48)) budget:12],
                             [SNRegion region:@"ai note's end" rect:crop(NSMakeRect(900, 65, 127, 71)) budget:12],
                             [SNRegion region:@"footer's end" rect:crop(NSMakeRect(900, 396, 147, 46)) budget:10],
                             [SNRegion region:@"right ring" rect:crop(NSMakeRect(1044, 8, 6, 420)) budget:12],
                             [SNRegion ignored:@"window left of the right part" rect:crop(NSMakeRect(300, 0, 600, 560))],
                             [SNRegion ignored:@"rows (other people)" rect:crop(NSMakeRect(900, 184, 147, 200))],
                             [SNRegion ignored:@"window right and below" rect:crop(NSMakeRect(1050, 0, 150, 560))],
                             [SNRegion ignored:@"window below" rect:crop(NSMakeRect(900, 443, 150, 117))],
                         ];
                     });
    [SNSearchModal.current close];
}

SN_SNAPSHOT(PopupsMessageMoreMenu) {
    SNShell *shell = CaptureShell();
    SNChannelPane *pane = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    // The capture's message is someone else's, its row 184.5 pt from the window's top.
    SNMessage *message = nil;
    CGFloat best = CGFLOAT_MAX;
    for (SNMessage *candidate in [shell.source messagesInConversation:shell.location.conversationID]) {
        NSView *row = [pane.list rowForTS:candidate.ts];
        if (!row || [candidate.userID isEqualToString:shell.source.me.userID]) continue;
        CGFloat distance = fabs(NSMinY(WindowFrame(row)) - 184.5);
        if (distance < best) best = distance, message = candidate;
    }
    [pane.list hoverMessageTS:message.ts];
    SNSettle(0.1);
    SNMessageActionBar *bar = pane.list.actionBar;
    bar.action(SNMessageActionMore, nil, NSMakeRect(bar.width - 36, 4, 32, 32));
    SNSettle(0.1);
    NSRect menu = WindowFrame(SNPopover.current.content), barFrame = WindowFrame(bar);
    Report(@"more menu", menu);
    Report(@"action bar", barFrame);
    // m_msgmore_open: the bar's box ends at x 1412.5 from y 168.5; the menu's box (302 x 284 with
    // its ring) at 1083,155. The menu follows the bar.
    CompareWithFrame(@"popups_more_menu", SNRenderWindow(shell.window), @"live/actionbar/m_msgmore_open/f155", NSZeroPoint, NSMakePoint(1412.5, 168.5),
                     NSMakePoint(NSMaxX(barFrame), NSMinY(barFrame)), 2, ^NSArray *(NSRect (^crop)(NSRect)) {
                         return @[
                             [SNRegion ignored:@"window outside the menu" rect:crop(NSMakeRect(0, 0, 1434, 150))],
                             [SNRegion ignored:@"window left" rect:crop(NSMakeRect(0, 150, 1078, 788))],
                             [SNRegion ignored:@"window below" rect:crop(NSMakeRect(1078, 444, 356, 494))],
                             [SNRegion ignored:@"bar right of the menu" rect:crop(NSMakeRect(1390, 150, 44, 294))],
                             [SNRegion region:@"menu" rect:crop(NSMakeRect(1083, 155, 302, 284)) budget:15],
                         ];
                     });
    [SNPopover.current close];
}

SN_SNAPSHOT(PopupsFilesPreview) {
    SNShell *shell = CaptureShell();
    SNChannelPane *pane = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    [pane.header showFilesPreview];
    SNSettle(0.3);
    NSRect preview = WindowFrame(SNFilesPeek.current.panel), tab = WindowFrame(pane.header.tabs[2]);
    Report(@"files preview", preview);
    Report(@"files tab", tab);
    // b4_files_peek: the tab's box starts at 701 (its text at 728) and the preview's box at
    // 693,121.5; its rows are the channel's own files.
    CompareWithFrame(@"popups_files_preview", SNRenderWindow(shell.window), @"live/misc/b4_files_peek/f392", NSMakePoint(680, 90), NSMakePoint(701, 90),
                     NSMakePoint(NSMinX(tab), NSMinY(tab)), 2, ^NSArray *(NSRect (^crop)(NSRect)) {
                         return @[
                             [SNRegion ignored:@"tabs and messages around it" rect:crop(NSMakeRect(680, 90, 420, 30))],
                             [SNRegion ignored:@"rows (the channel's files)" rect:crop(NSMakeRect(700, 125, 350, 160))],
                             [SNRegion region:@"left ring and corner" rect:crop(NSMakeRect(690, 118, 12, 40)) budget:15],
                         ];
                     });
    [SNFilesPeek.current close];
}

SN_SNAPSHOT(PopupsTooltips) {
    SNShell *shell = CaptureShell();
    SNButton *help = shell.topBar.helpButton;
    help.hovered = YES;
    SNSettle(SNTooltipDelay + 0.3);
    NSRect button = WindowFrame(help);
    Report(@"help button", button);
    // a_tooltip_help is a 2x crop at 1120,0 of a window whose help button starts at 1400.
    SNCompareWithReference(@"popups_tooltip_help", SNRenderWindow(shell.window), @"live/anim/a_tooltip_help/f200",
                           NSMakePoint(NSMinX(button) - 1400 + 1120, 0), 2, @[
                               [SNRegion ignored:@"top bar" rect:NSMakeRect(0, 0, 314, 40)],
                               [SNRegion region:@"tooltip" rect:NSMakeRect(150, 40, 164, 60) budget:15],
                           ]);
    help.hovered = NO;
}
