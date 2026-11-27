// Which cursor the window shows where (SNCursorAtPoint): the hand over what Slack makes
// clickable, rows hovered by their lists included, the arrow elsewhere and over what is disabled,
// and the composer's text left to AppKit's I-beam.
#import "app/launch.h"
#import "render/document.h"
#import "test.h"
#import "ui/channel/pane.h"
#import "ui/channel/row.h"
#import "ui/composer/composer.h"
#import "ui/dms/list.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/popover.h"
#import "ui/shell/search.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/row.h"

/// Shown views of `kind`, outermost first.
static NSArray *Visible(NSView *view, Class kind) {
    NSMutableArray *found = [NSMutableArray new];
    if (view.isHiddenOrHasHiddenAncestor) return found;
    if ([view isKindOfClass:kind]) [found addObject:view];
    for (NSView *subview in view.subviews) [found addObjectsFromArray:Visible(subview, kind)];
    return found;
}

static NSCursor *CursorAt(NSView *view, NSPoint point) { return SNCursorAtPoint(view.window, [view convertPoint:point toView:nil]); }
static NSCursor *CursorOver(NSView *view) { return CursorAt(view, NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds))); }

static SNMessageRowView *Row(SNChannelPane *pane, NSString *ts) {
    for (SNMessageRowView *row in Visible(pane.list, SNMessageRowView.class))
        if ([row.message.ts isEqualToString:ts]) return row;
    return nil;
}

/// The cursor over the message's text where it has a target (`target` YES) or none; nil when
/// the text has no such point.
static id BodyCursor(SNMessageRowView *row, BOOL target) {
    SNMessageLayout *layout = row.layout;
    for (CGFloat y = 1; y < layout.height - layout.bodyOrigin.y; y += 2)
        for (CGFloat x = 1; x < layout.width - layout.bodyOrigin.x - 40; x += 2)
            if (([layout.body targetAtPoint:CGPointMake(x, y)] != nil) == target)
                return CursorAt(row, NSMakePoint(x + layout.bodyOrigin.x, y + layout.bodyOrigin.y)) ?: NSNull.null;
    return nil;
}

SN_TEST(ShellShowsTheHandOnlyWhereSlackDoes) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    [shell openConversation:@"C01GENERAL"];
    SNSettle(0.3);
    NSView *root = shell.window.contentView;
    [root layoutSubtreeIfNeeded];
    NSCursor *hand = NSCursor.pointingHandCursor, *arrow = NSCursor.arrowCursor;

    SNSidebarRowView *conversation, *heading, *inert;
    for (SNSidebarRowView *row in Visible(root, SNSidebarRowView.class)) {
        SNSidebarItemKind kind = row.item.kind;
        if (kind == SNSidebarItemConversation && !conversation) conversation = row;
        if (kind == SNSidebarItemHeading && !heading) heading = row;
        if ((kind == SNSidebarItemGap || kind == SNSidebarItemDivider) && !inert) inert = row;
    }
    SNExpect(CursorOver(conversation) == hand, "a sidebar conversation, which its list hovers");
    SNExpect(CursorOver(heading) == hand, "a section header");
    SNExpect(CursorOver(inert) == arrow, "not the space between sections");
    SNExpect(CursorOver(shell.rail.tabs.firstObject) == hand, "a rail tab");
    SNExpect(CursorOver(shell.topBar.sidebarButton) == hand && CursorOver(shell.topBar.searchField) == hand, "top bar buttons and the search field");
    SNExpect(!shell.topBar.forwardButton.enabled && CursorOver(shell.topBar.forwardButton) == arrow, "the arrow on a disabled button (cursor: default)");
    SNExpect(CursorOver(Visible(root, NSClassFromString(@"SNResizer")).firstObject) == NSCursor.resizeLeftRightCursor, "the column resizer");

    SNChannelPane *pane = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNExpect(CursorOver(pane.header.more) == hand && CursorOver(pane.header.tabs.firstObject) == hand, "conversation header buttons and tabs");
    NSTextView *text = Visible(pane.composer, NSTextView.class).firstObject;
    SNExpect(text && CursorOver(text) == nil, "the composer's text keeps AppKit's I-beam");
    SNExpect(CursorOver(Visible(pane.composer, NSClassFromString(@"SNComposerSendPart")).firstObject) == arrow, "an empty composer's send button is disabled");

    SNMessageRowView *reacted = Row(pane, @"1795442100.000105"), *threaded = Row(pane, @"1795192800.000103"), *linked;
    for (SNMessageRowView *row in Visible(pane.list, SNMessageRowView.class))
        if (!linked && BodyCursor(row, YES)) linked = row;
    SNExpect(CursorOver(reacted.pills.firstObject) == hand, "a reaction pill inside a message");
    SNExpect(CursorOver(threaded.replyBar) == hand, "the reply bar");
    SNExpect(BodyCursor(linked, YES) == hand, "a link or mention in a message");
    SNExpect(BodyCursor(linked, NO) == NSNull.null, "the arrow over plain message text");
    SNMessageRowView *first;
    for (SNMessageRowView *candidate in Visible(pane.list, SNMessageRowView.class))
        if (!candidate.layout.continuation) first = candidate;
    NSRect avatar = first.layout.avatarRect;
    SNExpect(CursorAt(first, NSMakePoint(NSMidX(avatar), NSMidY(avatar))) == hand, "a message's avatar");
    SNExpect(first && CursorAt(first, NSMakePoint(NSMaxX(first.bounds) - 2, NSMaxY(first.bounds) - 2)) == nil, "the arrow over a message's background");

    SNMenuItem *off = [SNMenuItem itemWithTitle:@"Off" action:^{}];
    off.disabled = YES;
    SNMenu *menu = [[SNMenu alloc] initWithItems:@[ [SNMenuItem itemWithTitle:@"On" action:^{}], [SNMenuItem separator], off ] width:200];
    [menu showForRect:NSMakeRect(600, 300, 10, 10) inView:root placement:SNPlacementBelow];
    // Rows from 12 pt down: 28 pt items, a 16 pt separator.
    SNExpect(CursorAt(menu, NSMakePoint(50, 26)) == hand, "a menu item");
    SNExpect(CursorAt(menu, NSMakePoint(50, 48)) == nil && CursorAt(menu, NSMakePoint(50, 70)) == nil, "not its separator or a disabled item");
    [SNPopover.current close];

    shell.topBar.searchPressed();
    SNSearchModal *modal = SNSearchModal.current;
    SNExpect(modal && CursorOver(modal.queryField) == nil, "the search field keeps the I-beam");
    BOOL row = NO;
    for (CGFloat y = 0; y < NSHeight(modal.bounds) && !row; y += 2) row = CursorAt(modal, NSMakePoint(NSMidX(modal.bounds), y)) == hand;
    SNExpect(modal.rowTitles.count && row, "a search result");
    [modal close];

    [shell selectTab:SNTabDirectMessages];
    SNSettle(0.2);
    [root layoutSubtreeIfNeeded];
    NSView *dmRow = nil;
    for (NSView *view in Visible(root, NSClassFromString(@"SNDMRowView")))
        if (!dmRow && !((SNDMListItem *)[view valueForKey:@"item"]).header) dmRow = view;
    SNExpect(CursorOver(dmRow) == hand, "a row of the DMs list, which its list hovers");
}
