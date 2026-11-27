// The conversation and thread columns in the shell: the header across both columns, closing the
// conversation, and the wiring between the list, the composer and the source.
#import "../net/stub.h"
#import "app/launch.h"
#import "render/format.h"
#import "render/strings.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/channel/pane.h"
#import "ui/composer/composer.h"
#import "ui/kit/dialog.h"
#import "ui/profile/profilecard.h"
#import "ui/right/thread.h"
#import "ui/shell/shell.h"

static SNShell *Shell(id<SNSource> source, SNLocation *location) {
    SNSetLanguage(@"en");
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:location];
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

/// A view's frame in the window, in points from the top-left.
static NSRect WindowRect(NSView *view) {
    NSRect rect = [view convertRect:view.bounds toView:nil];
    rect.origin.y = view.window.contentView.bounds.size.height - NSMaxY(rect);
    return rect;
}

SN_TEST(ChannelHeaderSpansTheThread) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    NSRect header = WindowRect(channel.header), column = WindowRect(channel.view);
    SNExpect(NSMinY(header) == 41 && header.size.height == SNChannelHeaderHeight, "the header tops the card, 87 pt tall");
    SNExpect(NSMinY(column) == 128 && NSMinX(column) == NSMinX(header) && NSMaxX(column) == NSMaxX(header), "messages under it, as wide");

    NSString *parent = nil;
    for (SNMessage *message in [source messagesInConversation:@"C03DESIGN"])
        if (message.replyCount) parent = message.ts;
    [shell openThread:parent inConversation:@"C03DESIGN"];
    [shell.window.contentView layoutSubtreeIfNeeded];
    header = WindowRect(channel.header), column = WindowRect(channel.view);
    NSRect replies = WindowRect(thread.view);
    SNExpect(NSMinY(replies) == 128 && NSMaxX(replies) == NSMaxX(header), "the thread column starts under the header, which spans it");
    SNExpect(NSMinY(column) == 128 && NSMaxX(column) + 1 == NSMinX(replies), "the messages keep their column, a 1 pt divider apart");
    SNExpect(NSMinY(WindowRect(thread.close)) == 128 + (SNThreadHeaderHeight - 28) / 2, "the thread keeps its own 49 pt row");
}

SN_TEST(ChannelHeaderClosesTheConversation) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    NSString *dm = source.directMessages.firstObject.conversationID;
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabDirectMessages conversation:dm thread:nil]);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNExpect(!channel.header.close.hidden, "a conversation opened from the DMs tab can be closed");
    channel.header.close.action(channel.header.close);
    SNExpect(shell.location.tab == SNTabDirectMessages && !shell.location.conversationID, "closing leaves the tab without a conversation");
    SNExpect(channel.header.hidden && channel.list.hidden && channel.composer.hidden, "and the column empty");
    [shell goBack];
    SNExpect([shell.location.conversationID isEqualToString:dm] && !channel.header.hidden && !channel.list.hidden, "back reopens it");
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]];
    SNExpect(channel.header.close.hidden, "a conversation on Home has no close button");
}

SN_TEST(ChannelThreadParentShowsItsDay) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    // The public fixture's thread with saved replies.
    NSString *parent = @"1795192800.000103";
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:parent]);
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    NSArray<SNMessage *> *messages = [source threadInConversation:@"C01GENERAL" ts:parent];
    SNExpect(messages.count == 3, "the thread is loaded");
    [thread.view layoutSubtreeIfNeeded];
    SNMessageRowView *root = [thread.list rowForTS:parent], *reply = [thread.list rowForTS:messages.lastObject.ts];
    SNExpect([root.layout.time isEqualToString:SNFormatDayAndTime(messages[0].date, thread.list.now)], "the parent's time comes with its day");
    SNExpect([reply.layout.time isEqualToString:SNFormatTime(messages.lastObject.date)], "replies show the time alone");
    SNMessageRowView *inConversation = [((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list rowForTS:parent];
    SNExpect(!inConversation || [inConversation.layout.time isEqualToString:SNFormatTime(messages[0].date)], "the conversation shows the time alone");
}

SN_TEST(ChannelProfileCardOpensTheDM) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]);
    NSString *dm = source.directMessages.firstObject.conversationID;
    SNExpect(SNProfileCard.navigator == shell, "the conversation column handles the card's Mensagem button");
    SNUser *person = [source userWithID:[source conversationWithID:dm].userID];
    [SNProfileCard openDirectMessageWithUser:person.userID source:source];
    SNExpect(SNWaitUntil(2, ^BOOL { return [shell.location.conversationID isEqualToString:dm]; }) && shell.location.tab == SNTabHome, "it opens the DM where the window is");
}

/// The visible spinner views above the history.
static NSArray<NSView *> *Spinners(SNMessageListView *list) {
    NSMutableArray *spinners = [NSMutableArray new];
    for (NSView *view in list.scrollView.documentView.subviews)
        if ([view isKindOfClass:NSClassFromString(@"SNLoadingView")] && !view.hidden) [spinners addObject:view];
    return spinners;
}

static void Answer(SNTestAPI *api) {
    NSArray<dispatch_block_t> *held = [api.held copy];
    [api.held removeAllObjects];
    for (dispatch_block_t answer in held) answer();
}

SN_TEST(ChannelShowsTheHistoryLoading) {
    SNTestAPI *api = [SNTestAPI new];
    api.holds = YES;
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex"}, @{@"id" : @"U02SAM", @"name" : @"sam"} ]];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES} ]];
    }];
    NSMutableArray *page = [NSMutableArray new];
    for (int i = 41; i >= 0; i--)
        [page addObject:@{@"type" : @"message", @"user" : @"U02SAM", @"text" : [NSString stringWithFormat:@"message %d", i],
                          @"ts" : [NSString stringWithFormat:@"%d.000100", 1795400000 + i * 600]}];
    [store applyNewestHistory:@{@"messages" : page, @"has_more" : @YES} inConversation:@"C01GENERAL"];
    SNShell *shell = Shell(store, [SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:nil]);
    SNMessageListView *list = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list;
    SNExpect(list.atBottom && !Spinners(list).count, "nothing loads at first");
    [list scrollToOffset:0];
    SNExpect([api.methods containsObject:@"conversations.history"] && [store isLoadingMessagesInConversation:@"C01GENERAL"],
             "reaching the top asks for the older page");
    NSArray<NSView *> *spinners = Spinners(list);
    SNExpect(spinners.count == 1 && NSMinY(spinners[0].frame) == 0, "a spinner tops the history while a page loads");
    SNExpect(spinners.count && NSMinY([list rowForTS:@"1795400000.000100"].frame) >= NSMaxY(spinners[0].frame), "the history under it");
    SNExpect(spinners.count && spinners[0].layer.sublayers.firstObject.opacity == 0, "it waits 0.4 s before fading in");
    SNSettle(0.7);
    SNExpect(spinners.count && spinners[0].layer.sublayers.firstObject.opacity == 1, "then shows");
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return @{@"ok" : @YES, @"messages" : @[], @"has_more" : @NO}; };
    while (api.held.count) Answer(api);
    SNExpect(![store isLoadingMessagesInConversation:@"C01GENERAL"] && Spinners(list).count == 0, "gone when nothing loads");
}

SN_TEST(ChannelShowsPendingAndFailedSends) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]);
    SNMessageListView *list = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list;
    source.failsRequests = YES;
    SNMessage *sent = [source sendText:@"on its way" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNFlushChanges();
    SNMessageRowView *row = [list rowForTS:sent.ts];
    SNExpect(row.message.sendState == SNMessagePending && NSIsEmptyRect(row.layout.failedRect), "a send shows at once, pending");
    [list hoverMessageTS:sent.ts];
    SNExpect(list.actionBar.hidden, "no actions on a message Slack does not have");
    SNExpect(SNWaitUntil(1, ^BOOL { return [list rowForTS:sent.ts].message.sendState == SNMessageFailed; }), "the failure arrives");
    row = [list rowForTS:sent.ts];
    SNExpect(!NSIsEmptyRect(row.layout.failedRect) && NSMinX(row.layout.discardRect) > NSMaxX(row.layout.retryRect), "Not sent, Retry, Delete");
    [row clickAt:NSMakePoint(NSMidX(row.layout.retryRect), NSMidY(row.layout.retryRect))];
    SNExpect([source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessagePending, "Retry sends again");
    source.failsRequests = NO;
    SNExpect(SNWaitUntil(1, ^BOOL { return [source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessageFailed; }), "still failing then");
    row = [list rowForTS:[source messagesInConversation:@"C03DESIGN"].lastObject.ts];
    [row clickAt:NSMakePoint(NSMidX(row.layout.retryRect), NSMidY(row.layout.retryRect))];
    SNExpect(SNWaitUntil(1, ^BOOL { return [source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessageSent; }), "and sent once Slack answers");
    SNMessageRowView *confirmed = [list rowForTS:[source messagesInConversation:@"C03DESIGN"].lastObject.ts];
    SNExpect(confirmed && NSIsEmptyRect(confirmed.layout.failedRect), "a sent row without the failure line");

    source.failsRequests = YES;
    SNMessage *doomed = [source sendText:@"never arrives" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNExpect(SNWaitUntil(1, ^BOOL { return [list rowForTS:doomed.ts].message.sendState == SNMessageFailed; }), "another failure");
    row = [list rowForTS:doomed.ts];
    NSUInteger calls = source.calls.count;
    [row clickAt:NSMakePoint(NSMidX(row.layout.discardRect), NSMidY(row.layout.discardRect))];
    SNExpect(![list rowForTS:doomed.ts] && ![[source messagesInConversation:@"C03DESIGN"].lastObject.text isEqualToString:@"never arrives"], "Delete drops it");
    SNExpect(source.calls.count == calls, "without asking Slack");
    source.failsRequests = NO;
}

/// Slack's read-only refusal and a lost connection both fail a send at once, so a fast double
/// or triple click on Retry lands on the failed row again: it is still one retry.
SN_TEST(ChannelRetriesOncePerClick) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]);
    SNMessageListView *list = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list;
    source.failsRequests = YES;
    SNMessage *sent = [source sendText:@"flaky" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    BOOL (^failed)(void) = ^BOOL { return [source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessageFailed; };
    SNWaitUntil(1, failed);
    NSUInteger (^posts)(void) = ^NSUInteger {
        NSUInteger count = 0;
        for (NSArray *call in source.calls) count += [call[0] isEqualToString:@"chat.postMessage"];
        return count;
    };
    NSUInteger before = posts();
    for (NSInteger click = 1; click <= 3; click++) {
        SNMessageRowView *row = [list rowForTS:[source messagesInConversation:@"C03DESIGN"].lastObject.ts];
        NSPoint retry = [row convertPoint:NSMakePoint(NSMidX(row.layout.retryRect), NSMidY(row.layout.retryRect)) toView:nil];
        [row mouseUp:[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:retry modifierFlags:0 timestamp:0 windowNumber:shell.window.windowNumber
                                         context:nil eventNumber:0 clickCount:click pressure:0]];
        SNWaitUntil(1, failed);
    }
    SNExpect(posts() == before + 1 && [[source messagesInConversation:@"C03DESIGN"].lastObject.identifier isEqualToString:sent.identifier],
             "a triple click on Retry posts the message once");
    source.failsRequests = NO;
}

static NSEvent *Key(unsigned short code) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                          characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
}

static NSView *Find(NSView *view, Class viewClass) {
    if ([view isKindOfClass:viewClass]) return view;
    for (NSView *subview in view.subviews) {
        NSView *found = Find(subview, viewClass);
        if (found) return found;
    }
    return nil;
}

/// Opens the message's more menu from its action bar and picks the item titled `title`.
static void Choose(SNMessageListView *list, SNMessage *message, NSString *title) {
    [list hoverMessageTS:message.ts];
    list.actionBar.action(SNMessageActionMore, nil, NSMakeRect(list.actionBar.width - 32, 4, 32, 32));
    SNMenu *menu = (SNMenu *)Find(SNPopover.current.content, SNMenu.class);
    NSArray<SNMenuItem *> *items = [list menuItemsForMessage:message];
    for (NSUInteger i = 0; i < items.count; i++)
        if ([items[i].title isEqualToString:title]) menu.highlightedIndex = i;
    [menu keyDown:Key(36)];
    [list hoverMessageTS:nil];
}

static NSArray<NSString *> *CallsTo(SNFixtureSource *source, NSString *method) {
    NSMutableArray *calls = [NSMutableArray new];
    for (NSArray *call in source.calls)
        if ([call[0] isEqualToString:method]) [calls addObject:call[1]];
    return calls;
}

/// The public fixture's design channel with a message of the user's own, sent.
static SNMessage *SendOwn(SNFixtureSource *source, NSString *text) {
    SNMessage *pending = [source sendText:text blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNWaitUntil(1, ^BOOL { return [source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessageSent; });
    SNMessage *sent = [source messagesInConversation:@"C03DESIGN"].lastObject;
    return [sent.identifier isEqualToString:pending.identifier] ? sent : pending;
}

SN_TEST(ChannelEditsInPlace) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNMessageListView *list = channel.list;
    SNMessage *own = SendOwn(source, @"first draft");
    SNExpect(own.sendState == SNMessageSent, "the user's message is on Slack");

    channel.composer.editLastMessage(channel.composer);
    SNMessageEditor *editor = list.editor;
    SNExpect([editor.message.ts isEqualToString:own.ts] && [editor.text isEqualToString:@"first draft"], "Up edits the user's last message, its text in the box");
    SNExpect(editor.superview && !editor.hidden && ![list rowForTS:own.ts], "the editor takes the row's place");
    SNExpect(editor.frame.size.height == [editor heightForWidth:list.bounds.size.width], "at the editor's height");
    [list hoverMessageTS:own.ts];
    SNExpect(list.actionBar.hidden, "no action bar over the message being edited");
    [list hoverMessageTS:nil];

    editor.text = @"second draft";
    [editor save];
    SNExpect(!list.editor && [list rowForTS:own.ts], "saving puts the row back");
    SNExpect(CallsTo(source, @"chat.update").count == 1 && [[source messagesInConversation:@"C03DESIGN"].lastObject.text isEqualToString:@"second draft"],
             "chat.update, shown at once");

    [list editMessage:[source messagesInConversation:@"C03DESIGN"].lastObject];
    list.editor.text = @"thrown away";
    [list.editor cancel];
    [list editMessage:[source messagesInConversation:@"C03DESIGN"].lastObject];
    [list.editor save];
    SNExpect(!list.editor && CallsTo(source, @"chat.update").count == 1, "cancelling or saving unchanged text sends nothing");

    [list editMessage:[source messagesInConversation:@"C03DESIGN"].firstObject];
    SNExpect(!list.editor, "other people's messages are not editable");

    [list editMessage:[source messagesInConversation:@"C03DESIGN"].lastObject];
    list.editor.text = @"";
    [list.editor save];
    SNExpect(!list.editor && SNConfirmDialog.current, "saving it empty asks to delete it");
    [SNConfirmDialog.current cancel];
    SNExpect([[source messagesInConversation:@"C03DESIGN"].lastObject.text isEqualToString:@"second draft"], "cancelled: kept");
}

SN_TEST(ChannelMoreMenuEditsAndDeletes) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSetLanguage(@"en");
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]);
    SNMessageListView *list = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list;
    SNMessage *own = SendOwn(source, @"to be deleted");
    SNMessage *theirs = [source messagesInConversation:@"C03DESIGN"].firstObject;
    NSArray<NSString *> *ownTitles = [[list menuItemsForMessage:own] valueForKey:@"title"];
    NSArray<NSString *> *theirTitles = [[list menuItemsForMessage:theirs] valueForKey:@"title"];
    SNExpect([ownTitles containsObject:@"Edit message"] && [ownTitles containsObject:@"Delete message…"], "the user's messages can be edited and deleted");
    SNExpect(![theirTitles containsObject:@"Edit message"] && ![theirTitles containsObject:@"Delete message…"], "other people's cannot");
    SNMenuItem *remove = [list menuItemsForMessage:own][[ownTitles indexOfObject:@"Delete message…"]];
    SNExpect(remove.danger, "delete is red");

    Choose(list, own, @"Edit message");
    SNExpect([list.editor.message.ts isEqualToString:own.ts], "Edit message opens the editor");
    [list.editor cancel];

    Choose(list, own, @"Delete message…");
    SNConfirmDialog *dialog = SNConfirmDialog.current;
    SNExpect(dialog && dialog.panel.frame.size.width == 520, "Delete message asks first, in Slack's 520 pt dialog");
    SNMessageRowView *preview = (SNMessageRowView *)Find(dialog.panel, SNMessageRowView.class);
    SNExpect([preview.message.ts isEqualToString:own.ts], "showing the message");
    [dialog cancel];
    SNExpect(!SNConfirmDialog.current && [[source messagesInConversation:@"C03DESIGN"].lastObject.ts isEqualToString:own.ts], "Cancel keeps it");

    Choose(list, own, @"Delete message…");
    [SNConfirmDialog.current confirm];
    SNExpect(![[source messagesInConversation:@"C03DESIGN"].lastObject.ts isEqualToString:own.ts] && ![list rowForTS:own.ts], "Delete removes it at once");
    SNExpect(CallsTo(source, @"chat.delete").count == 1, "and asks Slack");
}

SN_TEST(ChannelThreadLinkLiveUnreadDividerSaveAndTallDeleteClamp) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSetLanguage(@"en");
    // 1. Thread reply Copy link includes ?thread_ts=...&cid=...
    NSString *parentTS = @"1795192800.000103";
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:parentTS]);
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    SNMessage *reply = [source threadInConversation:@"C01GENERAL" ts:parentTS].lastObject;
    SNExpect(reply.isReply, "target is a thread reply");
    Choose(thread.list, reply, @"Copy link");
    NSString *copied = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    NSString *expectedQuery = [NSString stringWithFormat:@"?thread_ts=%@&cid=C01GENERAL", parentTS];
    SNExpect([copied containsString:expectedQuery],
             "thread reply Copy link includes thread_ts and cid query parameters");

    // 2. Save for later is wired and toggles to Remove from Later.
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNMessage *first = [source messagesInConversation:@"C01GENERAL"].firstObject;
    SNExpect(![source isMessageSavedWithTS:first.ts inConversation:@"C01GENERAL"], "starts unsaved");
    Choose(channel.list, first, @"Save for later");
    SNExpect([source isMessageSavedWithTS:first.ts inConversation:@"C01GENERAL"], "Save for later marks message saved");
    NSArray<NSString *> *afterTitles = [[channel.list menuItemsForMessage:first] valueForKey:@"title"];
    SNExpect([afterTitles containsObject:@"Remove from Later"], "menu switches to Remove from Later");

    // 3. Mark unread in active channel displays live New divider immediately.
    SNMessage *theirs = nil;
    for (SNMessage *m in [source messagesInConversation:@"C01GENERAL"])
        if (![m.userID isEqualToString:source.me.userID]) theirs = m;
    SNExpect(theirs != nil, "channel has a message from another user");
    Choose(channel.list, theirs, @"Mark unread");
    SNFlushChanges();
    NSView *divider = Find(channel.list, NSClassFromString(@"SNNewDividerView"));
    SNExpect(divider && !divider.hidden, "Mark unread immediately shows the live New divider in the active channel");

    // 4. Tall delete-message confirmation clamps inside window bounds so buttons remain onscreen.
    NSMutableString *tallText = [NSMutableString new];
    for (int i = 0; i < 60; i++) [tallText appendFormat:@"Line %d of a very tall message to delete\n", i];
    SNMessage *tall = SendOwn(source, tallText);
    [shell.window setContentSize:NSMakeSize(1000, 560)];
    [shell.window.contentView layoutSubtreeIfNeeded];
    [channel.list confirmDeleteOfMessage:tall];
    SNConfirmDialog *dialog = SNConfirmDialog.current;
    SNExpect(dialog != nil, "tall delete dialog opens");
    NSRect panelFrame = dialog.panel.frame;
    SNExpect(NSHeight(panelFrame) <= 560 && NSMaxY(panelFrame) <= 560, "tall delete dialog stays clamped inside window height");
    NSScrollView *previewScroll = (NSScrollView *)Find(dialog.panel, NSScrollView.class);
    SNExpect(previewScroll != nil, "tall delete preview wraps in a scroll view");
    [dialog cancel];
}
