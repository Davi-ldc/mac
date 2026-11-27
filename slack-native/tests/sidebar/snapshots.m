// The Home sidebar against the official app's live captures (design/ref/live): at rest, every
// hover and press state captured, and a collapsed section.
//
// The captures are whole windows with a second workspace in the rail, so the sidebar column
// starts at x 131 there and at x 71 here, 311 pt wide in both. Each comparison covers one block
// and ignores the rest of the window; blocks are aligned on their own because the capture has a
// row the data has no source for (the onboarding tasks) and more channels than the fixture.
#import "app/launch.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/kit/popover.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/pane.h"

/// The live column: x 131-442, y 41-934 of the capture's window.
static const NSRect kColumn = {{131, 41}, {311, 893}};
static const CGFloat kOurColumnX = 71;

/// The window of the live captures: Home, the first channel open, the window key.
static SNShell *LiveShell(void) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    shell.card.sidebarWidth = kColumn.size.width;
    [shell setWindowActive:YES];
    SNSidebarPane *pane = (SNSidebarPane *)[shell paneInSlot:SNPaneSlotSidebar];
    NSString *first = nil;
    for (SNSidebarItem *item in pane.list.items)
        if (item.kind == SNSidebarItemConversation && !first) first = item.conversationID;
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:first thread:nil]];
    // Laid out as showing it would: a list makes rows only once it has its width.
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

static SNSidebarPane *Pane(SNShell *shell) { return (SNSidebarPane *)[shell paneInSlot:SNPaneSlotSidebar]; }

/// An entry's top in the window, in points from the window's top.
static CGFloat TopOf(SNShell *shell, NSString *key) {
    SNSidebarListView *list = Pane(shell).list;
    NSView *document = list.scrollView.documentView;
    NSRect rect = [document convertRect:[list rectForKey:key] toView:nil];
    return shell.window.contentView.bounds.size.height - NSMaxY(rect);
}

static NSString *KeyOfKind(SNShell *shell, SNSidebarItemKind kind, NSUInteger skip) {
    for (SNSidebarItem *item in Pane(shell).list.items)
        if (item.kind == kind && skip-- == 0) return item.key;
    return @"";
}

static NSString *HeadingKey(SNShell *shell, SNSectionType type) {
    for (SNSidebarItem *item in Pane(shell).list.items)
        if (item.kind == SNSidebarItemHeading && [item.section.type isEqualToString:type]) return item.key;
    return @"";
}

/// Compares the block of the capture between `top` and `bottom` (capture window points) with
/// ours shifted by `dy`; `regions` are in capture window points too.
static void CompareBlock(NSString *name, SNPixels *pixels, NSString *reference, CGFloat top, CGFloat bottom, CGFloat dy,
                         NSArray<SNRegion *> *regions) {
    NSMutableArray *all = [NSMutableArray arrayWithArray:@[
        [SNRegion ignored:@"left of the sidebar" rect:NSMakeRect(0, 0, NSMinX(kColumn), 938)],
        [SNRegion ignored:@"right of the sidebar" rect:NSMakeRect(NSMaxX(kColumn), 0, 1434 - NSMaxX(kColumn), 938)],
        [SNRegion ignored:@"above the block" rect:NSMakeRect(NSMinX(kColumn), 0, kColumn.size.width, top)],
        [SNRegion ignored:@"below the block" rect:NSMakeRect(NSMinX(kColumn), bottom, kColumn.size.width, 938 - bottom)],
    ]];
    [all addObjectsFromArray:regions];
    SNCompareWithReference(name, pixels, reference, NSMakePoint(kOurColumnX - NSMinX(kColumn), dy), 1, all);
}

static NSRect Row(CGFloat top) { return NSMakeRect(139, top, 295, 28); }

SN_SNAPSHOT(SidebarMatchesTheCaptures) {
    SNShell *shell = LiveShell();
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"sidebar_window", window);
    NSString *base = @"live/static/h__base";

    CompareBlock(@"sidebar_header", window, base, 41, 248, 0, @[
        [SNRegion ignored:@"workspace name (made-up)" rect:NSMakeRect(139, 50, 170, 32)],
        [SNRegion region:@"header background" rect:NSMakeRect(310, 41, 60, 49) budget:1],
        [SNRegion region:@"settings and compose" rect:NSMakeRect(372, 52, 62, 28) budget:25],
        [SNRegion region:@"field" rect:NSMakeRect(139, 98, 295, 28) budget:5],
        [SNRegion region:@"link icons" rect:NSMakeRect(147, 136, 16, 112) budget:25],
        [SNRegion region:@"link names" rect:NSMakeRect(163, 136, 271, 112) budget:6],
    ]);

    CGFloat dy = TopOf(shell, @"divider") - 276;
    CompareBlock(@"sidebar_sections", window, base, 276, 494, dy, @[
        [SNRegion region:@"divider" rect:NSMakeRect(131, 276, 311, 24) budget:2],
        [SNRegion region:@"favoritos heading" rect:NSMakeRect(139, 300, 295, 28) budget:5],
        [SNRegion region:@"favoritos hint" rect:NSMakeRect(139, 328, 295, 54) budget:5],
        [SNRegion region:@"canais heading" rect:NSMakeRect(139, 382, 295, 28) budget:5],
        [SNRegion region:@"selected fill and lock" rect:NSMakeRect(131, 410, 55, 28) budget:6],
        [SNRegion ignored:@"selected name (made-up)" rect:NSMakeRect(186, 410, 214, 28)],
        [SNRegion region:@"selected fill end" rect:NSMakeRect(400, 410, 42, 28) budget:1],
        [SNRegion region:@"rows before the icon" rect:NSMakeRect(131, 438, 32, 56) budget:1],
        // The capture's channels are private; the fixture's next two are public.
        [SNRegion ignored:@"row icons and names (made-up)" rect:NSMakeRect(163, 438, 237, 56)],
        [SNRegion region:@"rows after the names" rect:NSMakeRect(400, 438, 42, 56) budget:1],
    ]);

    CGFloat dms = TopOf(shell, KeyOfKind(shell, SNSidebarItemAdd, 0)) - 634;
    CompareBlock(@"sidebar_dms", window, base, 634, 924, dms, @[
        [SNRegion region:@"add channels" rect:Row(634) budget:4],
        [SNRegion region:@"dms heading" rect:NSMakeRect(139, 672, 295, 28) budget:5],
        [SNRegion region:@"dm rows before the avatar" rect:NSMakeRect(131, 700, 30, 224) budget:1],
        [SNRegion ignored:@"avatars and names (made-up people)" rect:NSMakeRect(161, 700, 239, 224)],
        [SNRegion region:@"dm rows after the names" rect:NSMakeRect(400, 700, 42, 224) budget:1],
    ]);
}

/// Renders the shell with `key` hovered (or pressed) and compares the row at `top` in `capture`.
static void CompareHover(NSString *name, NSString *capture, NSString *key, CGFloat top, BOOL pressed, NSArray<SNRegion *> *regions) {
    SNShell *shell = LiveShell();
    SNSidebarListView *list = Pane(shell).list;
    [list hoverKey:key];
    if (pressed) [list rowForKey:key].pressed = YES;
    SNPixels *window = SNRenderWindow(shell.window);
    NSMutableArray *all = [NSMutableArray arrayWithArray:regions];
    // The capture's scrollbar shows under the pointer; the fixture's list is too short for one
    // (SidebarScrollbar checks it on a list padded to the capture's length).
    [all addObject:[SNRegion ignored:@"scrollbar" rect:NSMakeRect(434, 130, 8, 804)]];
    CompareBlock(name, window, capture, top, top + 28, TopOf(shell, key) - top, all);
}

SN_SNAPSHOT(SidebarHoverStates) {
    SNShell *shell = LiveShell();
    CompareHover(@"sidebar_link_hover", @"live/static/h_sb_row_nav", KeyOfKind(shell, SNSidebarItemPage, 0), 136, NO, @[
        [SNRegion region:@"hovered link" rect:Row(136) budget:5],
    ]);
    CompareHover(@"sidebar_row_hover", @"live/static/h_sb_row", KeyOfKind(shell, SNSidebarItemConversation, 1), 438, NO, @[
        [SNRegion region:@"hovered row start" rect:NSMakeRect(139, 438, 24, 28) budget:3],
        [SNRegion ignored:@"icon and name (made-up)" rect:NSMakeRect(163, 438, 237, 28)],
        [SNRegion region:@"hovered row end" rect:NSMakeRect(400, 438, 34, 28) budget:3],
    ]);
    CompareHover(@"sidebar_add_hover", @"live/static/h_sb_row_add", KeyOfKind(shell, SNSidebarItemAdd, 0), 634, NO, @[
        [SNRegion region:@"hovered add" rect:Row(634) budget:4],
    ]);
    NSString *firstDM = nil;
    for (SNSidebarItem *item in Pane(shell).list.items)
        if (!firstDM && item.kind == SNSidebarItemConversation && [item.section.type isEqualToString:SNSectionDirectMessages]) firstDM = item.key;
    CompareHover(@"sidebar_dm_hover", @"live/static/h_sb_dm_row", firstDM ?: @"", 700, NO, @[
        [SNRegion region:@"hovered dm start" rect:NSMakeRect(139, 700, 22, 28) budget:3],
        [SNRegion ignored:@"avatar and name (made-up person)" rect:NSMakeRect(161, 700, 239, 28)],
        [SNRegion region:@"close" rect:NSMakeRect(404, 700, 30, 28) budget:10],
    ]);
    CompareHover(@"sidebar_heading_hover", @"live/static/h_sb_heading_channels", HeadingKey(shell, SNSectionChannels), 382, NO, @[
        [SNRegion region:@"hovered heading" rect:Row(382) budget:5],
        [SNRegion region:@"caret" rect:NSMakeRect(147, 382, 16, 28) budget:8],
        [SNRegion region:@"add, filter and menu" rect:NSMakeRect(354, 382, 80, 28) budget:10],
    ]);
    CompareHover(@"sidebar_heading_pressed", @"live/click/p_sb_heading_pressed", HeadingKey(shell, SNSectionChannels), 382, YES, @[
        [SNRegion region:@"pressed heading" rect:Row(382) budget:5],
    ]);
    CompareHover(@"sidebar_dms_heading_hover", @"live/static/h_sb_heading_dms", HeadingKey(shell, SNSectionDirectMessages), 672, NO, @[
        [SNRegion region:@"hovered heading" rect:Row(672) budget:5],
    ]);
    CompareHover(@"sidebar_stars_heading_hover", @"live/static/h_sb_heading_fav", HeadingKey(shell, SNSectionStarred), 300, NO, @[
        [SNRegion region:@"hovered heading" rect:Row(300) budget:5],
    ]);
}

SN_SNAPSHOT(SidebarHeaderStates) {
    NSArray *cases = @[
        @[ @"sidebar_title_hover", @"live/static/h_sb_title", @"title" ],
        @[ @"sidebar_title_pressed", @"live/click/p_sb_title_pressed", @"title-pressed" ],
        @[ @"sidebar_settings_hover", @"live/static/h_sb_gear", @"settings" ],
        @[ @"sidebar_compose_hover", @"live/static/h_sb_compose", @"compose" ],
    ];
    for (NSArray *entry in cases) {
        SNShell *shell = LiveShell();
        SNSidebarHeaderView *header = Pane(shell).header;
        NSString *which = entry[2];
        if ([which hasPrefix:@"title"]) header.titleButton.hovered = YES;
        if ([which isEqualToString:@"title-pressed"]) header.titleButton.pressed = YES;
        if ([which isEqualToString:@"settings"]) header.settingsButton.hovered = YES;
        if ([which isEqualToString:@"compose"]) header.composeButton.hovered = YES;
        SNSettle(0.2);
        SNPixels *window = SNRenderWindow(shell.window);
        CompareBlock(entry[0], window, entry[1], 41, 90, 0, @[
            // The fill spans the made-up name; its left part and the caret's height are compared.
            [SNRegion region:@"title fill" rect:NSMakeRect(139, 50, 8, 31) budget:4],
            [SNRegion ignored:@"workspace name (made-up)" rect:NSMakeRect(147, 50, 160, 31)],
            [SNRegion region:@"settings and compose" rect:NSMakeRect(372, 52, 62, 28) budget:25],
            [SNRegion ignored:@"tooltip (overlay)" rect:NSMakeRect(131, 82, 311, 8)],
        ]);
    }
}

SN_SNAPSHOT(SidebarCollapsedSection) {
    SNShell *shell = LiveShell();
    SNSidebarPane *pane = Pane(shell);
    NSString *heading = HeadingKey(shell, SNSectionChannels);
    SNSidebarRowView *row = [pane.list rowForKey:heading];
    [pane.list hoverKey:heading];
    row.action(row);
    SNSettle(0.2);
    // The open channel stays under its collapsed section, as in Slack; the capture's open
    // channel was in it too.
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"sidebar_collapsed_window", window);
    CompareBlock(@"sidebar_collapsed", window, @"live/click/c_section_collapsed", 382, 410, TopOf(shell, heading) - 382, @[
        [SNRegion region:@"collapsed heading" rect:Row(382) budget:5],
    ]);
}

/// States the captures have none of (unread, mention badges, a draft, a status emoji, a group
/// DM, the list scrolled with its scrollbar), from the public fixture; saved for review.
SN_SNAPSHOT(SidebarUncapturedStates) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    shell.card.sidebarWidth = kColumn.size.width;
    [shell setWindowActive:YES];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]];
    [source setDraft:@"rascunho" inConversation:@"C02RANDOM" threadTS:nil];
    SNSidebarListView *list = Pane(shell).list;
    [list hoverKey:[SNSidebarPane keyForConversation:@"G07MPDM" inSection:@"L04DMS"]];
    SNSaveSnapshot(@"sidebar_states", SNRenderView(Pane(shell).view, Pane(shell).view.bounds.size));

    NSClipView *clip = list.scrollView.contentView;
    list.frame = NSMakeRect(0, 89, list.frame.size.width, 200);
    [clip scrollToPoint:NSMakePoint(0, 60)];
    [list.scrollView reflectScrolledClipView:clip];
    [list mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSZeroPoint modifierFlags:0 timestamp:0
                                          windowNumber:0 context:nil eventNumber:0 trackingNumber:0 userData:NULL]];
    SNSaveSnapshot(@"sidebar_scrolled", SNRenderView(Pane(shell).view, NSMakeSize(311, 289)));
    [source setDraft:nil inConversation:@"C02RANDOM" threadTS:nil];
}

/// The header's filter (not captured live: focusing it would put a caret where keystrokes land):
/// typed text with its clear button, the results with the keyboard's ring on a row, then nothing
/// found.
SN_SNAPSHOT(SidebarFilterStates) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    shell.card.sidebarWidth = kColumn.size.width;
    [shell setWindowActive:YES];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]];
    SNSidebarPane *pane = Pane(shell);
    NSTextView *editor;
    for (NSString *text in @[ @"e", @"zzz" ]) {
        [pane.header.filterField focus];
        editor = (NSTextView *)pane.header.filterField.textField.currentEditor;
        [editor selectAll:nil];
        [editor insertText:text replacementRange:editor.selectedRange];
        SNSettle(0.25);
        if ([text isEqualToString:@"e"]) {
            [editor doCommandBySelector:@selector(moveDown:)];
            [pane.list keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                                                 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:125]];
            SNSaveSnapshot(@"sidebar_filter_results", SNRenderView(pane.view, NSMakeSize(311, 400)));
        } else {
            SNSaveSnapshot(@"sidebar_filter_empty", SNRenderView(pane.view, NSMakeSize(311, 300)));
        }
    }
}

/// The capture's list is 966 pt long (its thumb is 662.5 of a 796 pt track); the fixture's is
/// padded at the end to that length, so the thumb should cover the same pixels.
SN_SNAPSHOT(SidebarScrollbar) {
    SNShell *shell = LiveShell();
    SNSidebarListView *list = Pane(shell).list;
    CGFloat length = list.topInset + SNSpace2;
    for (SNSidebarItem *item in list.items) length += item.height;
    SNSidebarItem *padding = [SNSidebarItem new];
    padding.kind = SNSidebarItemGap;
    padding.key = @"padding";
    padding.height = 966 - length;
    [list showItems:[list.items arrayByAddingObject:padding]];
    [list mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSZeroPoint modifierFlags:0 timestamp:0
                                          windowNumber:0 context:nil eventNumber:0 trackingNumber:0 userData:NULL]];
    [list hoverKey:nil];
    SNPixels *window = SNRenderWindow(shell.window);
    CompareBlock(@"sidebar_scrollbar", window, @"live/static/h_sb_row_selected", 130, 934, 0, @[
        [SNRegion ignored:@"the list (compared elsewhere)" rect:NSMakeRect(131, 130, 303, 804)],
        [SNRegion region:@"thumb and track" rect:NSMakeRect(434, 130, 8, 804) budget:2],
    ]);
}

/// The workspace menu opened from the title, where the capture has it: its box from x 119,
/// y 91 (the menu itself is the shell's, compared in tests/shell).
SN_SNAPSHOT(SidebarTitleOpensTheWorkspaceMenu) {
    SNShell *shell = LiveShell();
    SNHoverView *title = Pane(shell).header.titleButton;
    // A click comes after the window is laid out; the menu is placed from the title's frame.
    [shell.window.contentView layoutSubtreeIfNeeded];
    title.hovered = YES;
    title.action(title);
    SNPixels *window = SNRenderWindow(shell.window);
    // The capture's column starts at x 131 and ours at 71; the menu overhangs the rail by 12 pt.
    NSMutableArray *regions = [NSMutableArray arrayWithArray:@[
        [SNRegion ignored:@"window above" rect:NSMakeRect(0, 0, 1434, 82)],
        [SNRegion ignored:@"window below" rect:NSMakeRect(0, 112, 1434, 826)],
        [SNRegion ignored:@"window left" rect:NSMakeRect(0, 82, 108, 30)],
        [SNRegion ignored:@"window right" rect:NSMakeRect(160, 82, 1274, 30)],
        // Left of and above the box: the capture's rail column and the menu's ring (the shell's).
        [SNRegion ignored:@"around the box" rect:NSMakeRect(108, 82, 11, 30)],
        [SNRegion ignored:@"ring above the box" rect:NSMakeRect(119, 82, 41, 9)],
        [SNRegion region:@"menu box corner" rect:NSMakeRect(119, 91, 41, 21) budget:2],
        [SNRegion region:@"no title fill while open" rect:NSMakeRect(139, 50, 8, 31) budget:4],
    ]];
    // No slack: the box must start exactly where the capture's does.
    SNCompareWithReference(@"sidebar_workspace_menu", window, @"live/click/m_ws_open", NSMakePoint(kOurColumnX - NSMinX(kColumn), 0), 0, regions);
    [SNPopover.current close];
}
