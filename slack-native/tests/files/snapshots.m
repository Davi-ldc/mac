// The files surfaces rendered offscreen from the public fixture's made-up files and links: the
// "Files and links" peek against b4_files_peek's settled frame (its link, file, link rows: the
// panel, the lines between rows and the icon tiles; the words differ), and the tab, the Files
// tab's page and its sidebar with their hover states, saved for review against the client's CSS.
#import "app/launch.h"
#import "render/strings.h"
#import "snapshot.h"
#import "test.h"
#import "ui/channel/pane.h"
#import "ui/files/browser.h"
#import "ui/files/peek.h"
#import "ui/files/rows.h"
#import "ui/files/sidebar.h"
#import "ui/files/tab.h"
#import "ui/shell/shell.h"

static SNShell *FilesShell(SNLocation *location) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    // The captures' language; the fixture's user reads English.
    SNSetLanguage(@"pt-BR");
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:location];
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNSettle(0.1);
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

/// 2x2 pixel boxes averaged: the render at the 1x capture's scale.
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

static NSRect WindowFrame(NSView *view) {
    NSRect rect = [view convertRect:view.bounds toView:nil];
    return NSMakeRect(NSMinX(rect), view.window.contentView.bounds.size.height - NSMaxY(rect), NSWidth(rect), NSHeight(rect));
}

static NSView *Subview(NSView *view, Class kind) {
    for (NSView *subview in view.subviews)
        if ([subview isKindOfClass:kind]) return subview;
    return nil;
}

SN_SNAPSHOT(FilesPeekMatchesTheCapture) {
    SNShell *shell = FilesShell([SNLocation locationWithTab:SNTabHome conversation:@"C02RANDOM" thread:nil]);
    SNChannelPane *pane = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    [pane.header showFilesPreview];
    SNSaveSnapshot(@"files_peek_loading", SNRenderWindow(shell.window));
    SNSettle(0.3);
    NSRect tab = WindowFrame(pane.header.tabs[2]), peek = WindowFrame(SNFilesPeek.current.panel);
    printf("files peek at %.1f,%.1f %.1fx%.1f under the tab at %.1f\n", peek.origin.x, peek.origin.y, peek.size.width, peek.size.height, tab.origin.x);
    SNExpect(NSMinX(peek) == NSMinX(tab) - 8 && NSMinY(peek) == NSMinY(tab) + 31.5, "8 pt left of the tab, 31.5 pt under its top");
    // b4_files_peek is a 1x crop of the window at 680,90 whose tab box starts at 701,90; its rows
    // are a link without an icon, a text file and a link: the fixture's C02RANDOM has the same.
    SNPixels *window = Halved(SNRenderWindow(shell.window));
    NSPoint theirs = NSMakePoint(701, 90), crop = NSMakePoint(680, 90);
    NSRect (^at)(NSRect) = ^NSRect(NSRect rect) { return NSMakeRect((rect.origin.x - crop.x) / 2, (rect.origin.y - crop.y) / 2, rect.size.width / 2, rect.size.height / 2); };
    NSPoint origin = NSMakePoint((NSMinX(tab) - theirs.x + crop.x) / 2, (NSMinY(tab) - theirs.y + crop.y) / 2);
    SNCompareWithReference(@"files_peek", window, @"live/misc/b4_files_peek/f333", origin, 1, @[
        [SNRegion ignored:@"tabs and messages around it" rect:at(NSMakeRect(680, 90, 420, 30))],
        [SNRegion ignored:@"titles and addresses" rect:at(NSMakeRect(750, 125, 300, 190))],
        [SNRegion ignored:@"the second link's site icon" rect:at(NSMakeRect(704, 255, 40, 40))],
        [SNRegion region:@"left ring and corner" rect:at(NSMakeRect(690, 118, 12, 40)) budget:15],
        [SNRegion region:@"first link's tile" rect:at(NSMakeRect(704, 131, 40, 40)) budget:20],
        [SNRegion region:@"the file's type icon" rect:at(NSMakeRect(704, 194, 40, 40)) budget:25],
        [SNRegion region:@"lines between rows" rect:at(NSMakeRect(700, 181, 50, 4)) budget:15],
        [SNRegion region:@"second line" rect:at(NSMakeRect(700, 242, 50, 4)) budget:15],
        [SNRegion region:@"bottom edge" rect:at(NSMakeRect(700, 312, 50, 10)) budget:15],
    ]);
    // Hovered: a link's actions and "Abrir no navegador", a file's actions and what a click does.
    SNHoverView *link = (SNHoverView *)SNFilesPeek.current.list.rows[0], *file = (SNHoverView *)SNFilesPeek.current.list.rows[1];
    link.hovered = YES;
    SNSaveSnapshot(@"files_peek_link_hover", SNRenderView(SNFilesPeek.current.panel, SNFilesPeek.current.panel.frame.size));
    link.hovered = NO;
    file.hovered = YES;
    SNSettle(0.2);
    SNSaveSnapshot(@"files_peek_file_hover", SNRenderView(SNFilesPeek.current.panel, SNFilesPeek.current.panel.frame.size));
    file.hovered = NO;
    [SNFilesPeek.current close];
}

SN_SNAPSHOT(FilesTabInAConversation) {
    SNShell *shell = FilesShell([SNLocation locationWithTab:SNTabHome conversation:@"C02RANDOM" thread:nil page:SNPageConversationFiles panel:nil]);
    SNSaveSnapshot(@"files_tab", SNRenderWindow(shell.window));
    SNChannelPane *pane = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNConversationFilesView *tab = (SNConversationFilesView *)Subview(pane.view, SNConversationFilesView.class);
    for (NSView *item in tab.items)
        if ([item isKindOfClass:SNFileRow.class]) ((SNHoverView *)item).hovered = YES;
    SNSettle(0.2);
    SNSaveSnapshot(@"files_tab_hover", SNRenderWindow(shell.window));
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil page:SNPageConversationFiles panel:nil]];
    SNSettle(0.2);
    [shell.window.contentView layoutSubtreeIfNeeded];
    // The first render starts the pictures loading; the second has them.
    SNRenderWindow(shell.window);
    SNSaveSnapshot(@"files_tab_media", SNRenderWindow(shell.window));
}

SN_SNAPSHOT(FilesBrowserAndSidebar) {
    SNShell *shell = FilesShell([SNLocation locationWithTab:SNTabFiles conversation:nil thread:nil page:SNPageFiles panel:nil]);
    id<SNSource> source = shell.source;
    SNFilesBrowserView *browser = (SNFilesBrowserView *)Subview([shell paneInSlot:SNPaneSlotPrimary].view, SNFilesBrowserView.class);
    [source noteFileViewed:browser.files[0]];
    [source noteFileViewed:browser.files[1]];
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNSaveSnapshot(@"files_browser", SNRenderWindow(shell.window));
    SNFilesSidebarPane *sidebar = (SNFilesSidebarPane *)[shell paneForTab:SNTabFiles];
    ((SNHoverView *)sidebar.rows[1]).hovered = YES;
    ((SNHoverView *)sidebar.rows.lastObject).hovered = YES;
    for (NSView *item in browser.items)
        if ([item isKindOfClass:SNFileRow.class]) {
            ((SNHoverView *)item).hovered = YES;
            break;
        }
    SNSettle(0.2);
    SNSaveSnapshot(@"files_browser_hover", SNRenderWindow(shell.window));
    browser.filter = @"created";
    SNSettle(0.1);
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNSaveSnapshot(@"files_browser_created", SNRenderWindow(shell.window));
    browser.filter = @"all";
    browser.fileTypes = @[ @"emails" ];
    SNSettle(0.1);
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNSaveSnapshot(@"files_browser_empty", SNRenderWindow(shell.window));
}
