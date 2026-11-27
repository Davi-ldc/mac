// The search modal: placement, rows, keyboard and opening what is chosen; and its look against
// the official app's capture.
#import "../net/stub.h"
#import "app/launch.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/channel/pane.h"
#import "ui/right/thread.h"
#import "ui/shell/search.h"
#import "ui/shell/shell.h"

static SNShell *SearchShell(NSURL *fixture) {
    id<SNSource> source = SNOpenFixture(fixture);
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell.window.contentView layoutSubtreeIfNeeded];
    shell.topBar.searchPressed();
    return shell;
}

SN_TEST(SearchOpensOverTheFieldWithRecentPlaces) {
    SNShell *shell = SearchShell(SNPublicFixture());
    SNSearchModal *modal = SNSearchModal.current;
    SNExpect(modal != nil, "mouse-down on the field opens the modal");
    NSRect field = [shell.window.contentView convertRect:shell.topBar.searchField.bounds fromView:shell.topBar.searchField];
    NSRect panel = [shell.window.contentView convertRect:modal.bounds fromView:modal];
    SNExpect(fabs(NSMinX(panel) - (NSMinX(field) - 35)) <= 0.5 && NSWidth(panel) == NSWidth(field) + 70, "35 pt wider than the field on each side");
    SNExpect(NSMinY(panel) == 4, "4 pt below the window's top");
    SNExpect(modal.rowTitles.count > 0 && modal.selectedIndex == 0, "recent places, the first selected");
    SNExpect(shell.window.firstResponder == modal.queryField.currentEditor, "the query field has the keyboard");
    [modal close];
    SNExpect(SNSearchModal.current == nil, "closing removes it");
}

SN_TEST(SearchSuggestsAndOpensWithTheKeyboard) {
    SNShell *shell = SearchShell(SNPublicFixture());
    SNSearchModal *modal = SNSearchModal.current;
    modal.queryField.stringValue = @"design";
    [NSNotificationCenter.defaultCenter postNotificationName:NSControlTextDidChangeNotification object:modal.queryField];
    SNExpect([modal.rowTitles.firstObject isEqualToString:@"design"], "the first row searches for the query");
    SNExpect([modal.rowTitles containsObject:@"design"] && modal.rowTitles.count >= 2, "the matching channel follows");
    NSTextView *editor = (NSTextView *)modal.queryField.currentEditor;
    [editor doCommandBySelector:@selector(moveDown:)];
    SNExpect(modal.selectedIndex == 1, "Down moves the selection");
    [editor doCommandBySelector:@selector(moveUp:)];
    [editor doCommandBySelector:@selector(moveUp:)];
    SNExpect(modal.selectedIndex == modal.rowTitles.count - 1, "Up from the top wraps to the bottom");
    // The channel is the last row; people named like it come before.
    [editor doCommandBySelector:@selector(insertNewline:)];
    SNExpect([shell.location.conversationID isEqualToString:@"C03DESIGN"] && SNSearchModal.current == nil, "Return opens the channel and closes");
}

SN_TEST(SearchFindsMessages) {
    SNShell *shell = SearchShell(SNPublicFixture());
    SNSearchModal *modal = SNSearchModal.current;
    modal.queryField.stringValue = @"the";
    [NSNotificationCenter.defaultCenter postNotificationName:NSControlTextDidChangeNotification object:modal.queryField];
    [modal openSelection];
    SNSettle(0.1);
    SNExpect(modal.rowTitles.count > 0 && SNSearchModal.current == modal, "Return on the query lists the matching messages");
    NSString *before = shell.location.conversationID;
    [modal openSelection];
    SNExpect(shell.location.conversationID && (![shell.location.conversationID isEqualToString:before] || shell.location.threadTS || SNSearchModal.current == nil),
             "choosing a message opens its conversation");
}

SN_SNAPSHOT(SearchMatchesTheCapture) {
    SNShell *shell = SearchShell(SNPrivateFixture() ?: SNPublicFixture());
    SNSettle(0.1);
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"search_window", window);
    // The capture is the whole window, whose search field is 31.5 pt narrower (the top bar there
    // has more buttons), so the modal's left and right parts are compared apart, each aligned on
    // its edge. Its recent places are other people.
    NSRect modal = [shell.window.contentView convertRect:SNSearchModal.current.bounds fromView:SNSearchModal.current];
    static const CGFloat kCaptureLeft = 407.5, kCaptureRight = 1047.5;
    SNCompareWithReference(@"search_open_left", window, @"live/click/s_search_open", NSMakePoint(NSMinX(modal) - kCaptureLeft, 0), 0, @[
        [SNRegion region:@"query row" rect:NSMakeRect(408, 4, 400, 48) budget:8],
        [SNRegion region:@"line under the query" rect:NSMakeRect(408, 52, 400, 1) budget:2],
        [SNRegion region:@"ai note" rect:NSMakeRect(428, 65, 400, 71) budget:10],
        [SNRegion region:@"heading" rect:NSMakeRect(408, 136, 400, 48) budget:6],
        [SNRegion ignored:@"recent places (other people)" rect:NSMakeRect(408, 184, 400, 200)],
        [SNRegion region:@"footer" rect:NSMakeRect(408, 395, 400, 46) budget:8],
        [SNRegion region:@"left ring" rect:NSMakeRect(404, 8, 4, 420) budget:10],
    ]);
    SNCompareWithReference(@"search_open_right", window, @"live/click/s_search_open", NSMakePoint(NSMaxX(modal) - kCaptureRight, 0), 0, @[
        [SNRegion region:@"query row's buttons" rect:NSMakeRect(940, 4, 107, 48) budget:10],
        [SNRegion region:@"ai note's end" rect:NSMakeRect(900, 65, 127, 71) budget:10],
        [SNRegion region:@"selected row's end" rect:NSMakeRect(968, 184, 79, 40) budget:8],
        [SNRegion region:@"rows' ends" rect:NSMakeRect(968, 224, 79, 160) budget:3],
        [SNRegion region:@"footer's end" rect:NSMakeRect(900, 395, 147, 46) budget:8],
        [SNRegion region:@"right ring" rect:NSMakeRect(1047, 8, 4, 420) budget:10],
    ]);
    [SNSearchModal.current close];
}

SN_TEST(SearchLetsGoOnceClosed) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    [shell.window.contentView layoutSubtreeIfNeeded];
    __weak SNSearchModal *closed = nil;
    @autoreleasepool {
        shell.topBar.searchPressed();
        closed = SNSearchModal.current;
        [closed close];
    }
    SNExpect(closed == nil, "a closed search modal is freed");
}

SN_TEST(SearchJumpScrollsHighlightsAndStaysOnOlderSliceAndThreadReply) {
    // 1. Recent channel message already in history: scrolls to target and highlights it.
    SNFixtureSource *fixture = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:fixture defaults:nil];
    [shell.window.contentView layoutSubtreeIfNeeded];
    NSArray<SNMessage *> *design = [fixture messagesInConversation:@"C03DESIGN"];
    NSString *olderLoadedTS = design.firstObject.ts;
    [shell go:[[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil] locationWithMessage:olderLoadedTS]];
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNExpect([channel.list rowForTS:olderLoadedTS] != nil, "jumping to an already-loaded earlier message scrolls it into view");
    SNExpect([channel.list.jumpHighlightedTS isEqualToString:olderLoadedTS] && [channel.list rowForTS:olderLoadedTS].highlighted,
             "and transiently highlights the matched row");

    // 2. Thread reply jump: scrolls to and highlights the matched reply inside the thread column.
    NSString *parentTS = @"1795192800.000103";
    NSArray<SNMessage *> *replies = [fixture threadInConversation:@"C01GENERAL" ts:parentTS];
    NSString *replyTS = replies.lastObject.ts;
    [shell go:[[SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:parentTS] locationWithMessage:replyTS]];
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    SNExpect([thread.list rowForTS:replyTS] != nil && [thread.list.jumpHighlightedTS isEqualToString:replyTS] && [thread.list rowForTS:replyTS].highlighted,
             "thread reply jump lands on and highlights the target reply");

    // 3. Older channel slice not yet loaded: stays on target slice without auto-fetching newer messages.
    SNTestAPI *api = [SNTestAPI new];
    NSMutableArray *olderSlice = [NSMutableArray new];
    for (int i = 20; i >= 0; i--)
        [olderSlice addObject:@{@"type" : @"message", @"user" : @"U02SAM", @"text" : [NSString stringWithFormat:@"old %d", i],
                                @"ts" : [NSString stringWithFormat:@"%d.000100", 1790000000 + i * 600]}];
    NSArray *newerSlice = @[ @{@"type" : @"message", @"user" : @"U02SAM", @"text" : @"newest", @"ts" : @"1799999999.000100"} ];
    NSString *targetTS = @"1790012000.000100";
    __block NSInteger newerCalls = 0;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"conversations.history"]) {
            if (params[@"oldest"]) newerCalls++;
            if (params[@"latest"]) return @{@"ok" : @YES, @"messages" : olderSlice, @"has_more" : @YES};
            return @{@"ok" : @YES, @"messages" : newerSlice, @"has_more" : @YES};
        }
        return @{@"ok" : @YES};
    };
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex"}, @{@"id" : @"U02SAM", @"name" : @"sam"} ]];
        [store applyConversations:@[
            @{@"id" : @"C00HOME", @"name" : @"home", @"is_channel" : @YES, @"is_member" : @YES, @"latest" : @"1799999999.000100"},
            @{@"id" : @"C01OLD", @"name" : @"old", @"is_channel" : @YES, @"is_member" : @YES, @"latest" : @"1799999999.000100"},
        ]];
        [store applySections:@[ @{@"channel_section_id" : @"S1", @"name" : @"Channels", @"channel_ids_page" : @{@"channel_ids" : @[ @"C00HOME", @"C01OLD" ]}} ]];
    }];
    SNShell *histShell = [[SNShell alloc] initWithSource:store defaults:nil];
    [histShell.window.contentView layoutSubtreeIfNeeded];
    SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C00HOME"].count > 0; });
    [store loadMessagesAround:targetTS inConversation:@"C01OLD"];
    [histShell go:[[SNLocation locationWithTab:SNTabHome conversation:@"C01OLD" thread:nil] locationWithMessage:targetTS]];
    SNExpect(SNWaitUntil(1, ^BOOL { return [store messagesInConversation:@"C01OLD"].count == olderSlice.count; }),
             "loadMessagesAround delivers the historical slice");
    SNFlushChanges();
    SNSettle(0.05);
    SNChannelPane *histPane = (SNChannelPane *)[histShell paneInSlot:SNPaneSlotPrimary];
    SNExpect([store hasNewerMessagesInConversation:@"C01OLD"], "historical slice knows newer messages exist on server");
    SNExpect(newerCalls == 0, "landing on an older slice does not immediately yank back to newest");
    SNExpect([histPane.list rowForTS:targetTS] != nil && [histPane.list.jumpHighlightedTS isEqualToString:targetTS],
             "target message of historical slice stays visible and highlighted");
}
