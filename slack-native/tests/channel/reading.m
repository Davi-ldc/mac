// Read marks (only while the reader can see the newest message, only through ts Slack gave), the
// thread column forgetting its thread when closed, "Mark unread", the delete dialog's Return and
// a conversation the source does not know yet.
#import <objc/runtime.h>

#import "../net/stub.h"
#import "app/launch.h"
#import "render/strings.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/channel/pane.h"
#import "ui/composer/composer.h"
#import "ui/kit/dialog.h"
#import "ui/right/thread.h"
#import "ui/shell/shell.h"

/// The public fixture, remembering every read mark asked of it ("<conversation or thread key> <ts>").
@interface SNMarkRecorder : SNFixtureSource
@property (nonatomic, readonly) NSMutableArray<NSString *> *readMarks;
@end

@implementation SNMarkRecorder {
    NSMutableArray<NSString *> *_readMarks;
}

- (NSMutableArray<NSString *> *)readMarks { return _readMarks ?: (_readMarks = [NSMutableArray new]); }

- (void)markConversation:(NSString *)conversationID readThrough:(NSString *)ts {
    [self.readMarks addObject:[NSString stringWithFormat:@"%@ %@", conversationID, ts]];
    [super markConversation:conversationID readThrough:ts];
}

- (void)markThread:(NSString *)threadTS inConversation:(NSString *)conversationID readThrough:(NSString *)ts {
    [self.readMarks addObject:[NSString stringWithFormat:@"%@ %@", SNThreadKey(conversationID, threadTS), ts]];
    [super markThread:threadTS inConversation:conversationID readThrough:ts];
}

- (void)markConversation:(NSString *)conversationID unreadFrom:(SNMessage *)message {
    [self.readMarks addObject:[NSString stringWithFormat:@"unread %@ %@", conversationID, message.ts]];
    [super markConversation:conversationID unreadFrom:message];
}

- (void)markThread:(NSString *)threadTS inConversation:(NSString *)conversationID unreadFrom:(SNMessage *)reply {
    [self.readMarks addObject:[NSString stringWithFormat:@"unread %@ %@", SNThreadKey(conversationID, threadTS), reply.ts]];
    [super markThread:threadTS inConversation:conversationID unreadFrom:reply];
}

@end

static SNMarkRecorder *Recorder(void) {
    SNSetLanguage(@"en");
    return [SNMarkRecorder sourceWithFolder:SNPublicFixture()];
}

static SNShell *ShellAt(id<SNSource> source, NSString *conversationID, NSString *threadTS) {
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:conversationID thread:threadTS]];
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

static const char kSeenKey = 0;

/// NSWindow's answer, for windows not pretending.
static BOOL SeenIsKey(NSWindow *window, SEL command) {
    NSNumber *seen = objc_getAssociatedObject(window, &kSeenKey);
    return seen ? seen.boolValue : ((BOOL (*)(id, SEL))class_getMethodImplementation(NSWindow.class, command))(window, command);
}

static NSWindowOcclusionState SeenOcclusion(NSWindow *window, SEL command) {
    NSNumber *seen = objc_getAssociatedObject(window, &kSeenKey);
    if (!seen) return ((NSWindowOcclusionState (*)(id, SEL))class_getMethodImplementation(NSWindow.class, command))(window, command);
    return seen.boolValue ? NSWindowOcclusionStateVisible : 0;
}

/// Makes `window` answer as a key window on screen would (or a background one), without showing
/// it, and tells observers the way AppKit does. Its class gains overrides that only answer
/// differently for windows pretending.
static void PretendSeen(NSWindow *window, BOOL seen) {
    Class windowClass = window.class;
    for (NSValue *pair in @[ [NSValue valueWithPointer:@selector(isKeyWindow)], [NSValue valueWithPointer:@selector(occlusionState)] ]) {
        SEL selector = pair.pointerValue;
        IMP override = selector == @selector(isKeyWindow) ? (IMP)SeenIsKey : (IMP)SeenOcclusion;
        Method method = class_getInstanceMethod(windowClass, selector);
        if (method_getImplementation(method) != override) class_addMethod(windowClass, selector, override, method_getTypeEncoding(method));
    }
    objc_setAssociatedObject(window, &kSeenKey, @(seen), OBJC_ASSOCIATION_RETAIN);
    [NSNotificationCenter.defaultCenter postNotificationName:seen ? NSWindowDidBecomeKeyNotification : NSWindowDidResignKeyNotification object:window];
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeOcclusionStateNotification object:window];
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
    [menu keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                 characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:36]];
    [list hoverMessageTS:nil];
}

static NSString *Newest(id<SNSource> source, NSString *conversationID) {
    for (SNMessage *message in [source messagesInConversation:conversationID].reverseObjectEnumerator)
        if (message.sendState == SNMessageSent && !message.isReply) return message.ts;
    return nil;
}

static void Arrive(SNFixtureSource *source, NSString *conversationID, NSString *ts, NSString *threadTS) {
    NSMutableDictionary *event = [@{@"type" : @"message", @"channel" : conversationID, @"user" : @"U02SAM", @"text" : @"news", @"ts" : ts} mutableCopy];
    if (threadTS) event[@"thread_ts"] = threadTS;
    [source applyEvent:event];
}

SN_TEST(ChannelMarksReadOnlyWhileSeen) {
    SNMarkRecorder *source = Recorder();
    SNShell *shell = ShellAt(source, @"C03DESIGN", nil);
    SNMessageListView *list = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list;
    SNExpect(list.atBottom && !source.readMarks.count, "nothing is marked at launch, before the window is key and on screen");

    PretendSeen(shell.window, YES);
    NSString *first = [@"C03DESIGN " stringByAppendingString:Newest(source, @"C03DESIGN")];
    SNExpect([source.readMarks isEqualToArray:@[ first ]], "once seen at the bottom: read through the newest message, once");

    source.failsRequests = YES;
    SNMessage *pending = [source sendText:@"on its way" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNWaitUntil(1, ^BOOL { return [source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessageFailed; });
    source.failsRequests = NO;
    SNExpect(source.readMarks.count == 1, "never through a pending or failed send's local ts");
    [source deleteMessage:[source messagesInConversation:@"C03DESIGN"].lastObject];
    SNExpect(![source.readMarks.lastObject hasSuffix:pending.ts], "nor after it is dropped");

    [source sendText:@"arrives" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNExpect(SNWaitUntil(1, ^BOOL { return [source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessageSent; }), "sent");
    SNExpect([source.readMarks.lastObject isEqualToString:[@"C03DESIGN " stringByAppendingString:Newest(source, @"C03DESIGN")]],
             "through the ts Slack gave it once it is sent");

    NSUInteger marks = source.readMarks.count;
    [list scrollToOffset:0];
    Arrive(source, @"C03DESIGN", @"1799600000.000100", nil);
    SNExpect(source.readMarks.count == marks && !list.atBottom, "a message arriving while the reader is up the history is not read");
    [list scrollToBottom];
    SNExpect([source.readMarks.lastObject isEqualToString:@"C03DESIGN 1799600000.000100"], "it is once they reach the bottom");
    Arrive(source, @"C03DESIGN", @"1799600100.000100", nil);
    SNExpect([source.readMarks.lastObject isEqualToString:@"C03DESIGN 1799600100.000100"], "and again as messages arrive at the bottom");

    PretendSeen(shell.window, NO);
    marks = source.readMarks.count;
    Arrive(source, @"C03DESIGN", @"1799600200.000100", nil);
    SNExpect(source.readMarks.count == marks, "not while the window is in the background");
    PretendSeen(shell.window, YES);
    SNExpect([source.readMarks.lastObject isEqualToString:@"C03DESIGN 1799600200.000100"], "but when it comes back");
}

SN_TEST(ChannelMarkUnreadHoldsReadMarks) {
    SNMarkRecorder *source = Recorder();
    SNShell *shell = ShellAt(source, @"C03DESIGN", nil);
    PretendSeen(shell.window, YES);
    SNMessageListView *list = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list;
    SNMessage *message = [source messagesInConversation:@"C03DESIGN"][2];
    SNExpect([[[list menuItemsForMessage:message] valueForKey:@"title"] containsObject:@"Mark unread"], "messages can be marked unread");
    Choose(list, message, @"Mark unread");
    SNConversation *conversation = [source conversationWithID:@"C03DESIGN"];
    SNExpect(conversation.hasUnreads && SNCompareTS(conversation.lastRead, message.ts) == NSOrderedAscending, "unread from that message on");
    NSUInteger marks = source.readMarks.count;
    Arrive(source, @"C03DESIGN", @"1799600000.000100", nil);
    SNExpect(source.readMarks.count == marks && [source conversationWithID:@"C03DESIGN"].hasUnreads, "it stays unread while the reader stays");
    [shell openConversation:@"C01GENERAL"];
    [shell openConversation:@"C03DESIGN"];
    SNExpect([source.readMarks.lastObject isEqualToString:@"C03DESIGN 1799600000.000100"], "coming back reads it");
}

SN_TEST(ThreadForgetsItsThreadWhenClosed) {
    SNMarkRecorder *source = Recorder();
    NSString *parent = @"1795192800.000103";
    SNShell *shell = ShellAt(source, @"C01GENERAL", parent);
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    SNExpect(!source.readMarks.count, "a thread restored at launch is not marked");
    PretendSeen(shell.window, YES);
    NSString *key = SNThreadKey(@"C01GENERAL", parent);
    NSString *reply = [source threadInConversation:@"C01GENERAL" ts:parent].lastObject.ts;
    NSString *mark = [NSString stringWithFormat:@"%@ %@", key, reply];
    SNExpect([source.readMarks containsObject:mark], "seen: the thread is read through its newest reply");

    [shell closeThread];
    SNExpect(!thread.list.conversationID && !thread.list.threadTS && !thread.list.visibleRowCount && !thread.composer.conversationID,
             "closing forgets the thread");
    NSUInteger marks = source.readMarks.count;
    Arrive(source, @"C01GENERAL", @"1799600000.000100", parent);
    Arrive(source, @"C01GENERAL", @"1799600100.000100", nil);
    BOOL threadMarked = NO;
    for (NSString *mark in [source.readMarks subarrayWithRange:NSMakeRange(marks, source.readMarks.count - marks)]) threadMarked |= [mark hasPrefix:key];
    SNExpect(!threadMarked && !thread.list.visibleRowCount, "a reply to it afterwards is neither shown nor marked");

    [shell openThread:parent inConversation:@"C01GENERAL"];
    SNExpect([source.readMarks.lastObject isEqualToString:[key stringByAppendingString:@" 1799600000.000100"]], "reopened, the new reply is read");
}

SN_TEST(ThreadIsNotMarkedWhileItsColumnIsHidden) {
    SNMarkRecorder *source = Recorder();
    NSString *parent = @"1795192800.000103";
    SNShell *shell = ShellAt(source, @"C01GENERAL", nil);
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    PretendSeen(shell.window, YES);
    [thread.list showMessages:[source threadInConversation:@"C01GENERAL" ts:parent] inConversation:@"C01GENERAL" threadTS:parent lastRead:nil];
    BOOL threadMarked = NO;
    for (NSString *mark in source.readMarks) threadMarked |= [mark hasPrefix:SNThreadKey(@"C01GENERAL", parent)];
    SNExpect(thread.view.isHiddenOrHasHiddenAncestor && !threadMarked, "a list in a hidden column marks nothing");
}

SN_TEST(ChannelDeleteDialogNeedsAFreshReturn) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSetLanguage(@"en");
    SNShell *shell = ShellAt(source, @"C03DESIGN", nil);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    [source sendText:@"to delete" blocks:nil inConversation:@"C03DESIGN" threadTS:nil broadcast:NO];
    SNWaitUntil(1, ^BOOL { return [source messagesInConversation:@"C03DESIGN"].lastObject.sendState == SNMessageSent; });
    SNMessage *own = [source messagesInConversation:@"C03DESIGN"].lastObject;
    [channel.list editMessage:own];
    channel.list.editor.text = @"";
    [channel.list.editor save];
    SNConfirmDialog *dialog = SNConfirmDialog.current;
    SNExpect(dialog != nil, "an emptied edit asks to delete");
    NSEvent * (^key)(BOOL, NSEventType) = ^NSEvent *(BOOL repeat, NSEventType type) {
        return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"\r"
             charactersIgnoringModifiers:@"\r" isARepeat:repeat keyCode:36];
    };
    SNExpect([dialog handleKeyEvent:key(YES, NSEventTypeKeyDown)] && SNConfirmDialog.current == dialog, "a held Return's repeats are swallowed, not confirmed");
    SNExpect([[source messagesInConversation:@"C03DESIGN"].lastObject.ts isEqualToString:own.ts], "the message stays");
    [dialog handleKeyEvent:key(NO, NSEventTypeKeyUp)];
    [dialog handleKeyEvent:key(NO, NSEventTypeKeyDown)];
    SNExpect(!SNConfirmDialog.current && ![[source messagesInConversation:@"C03DESIGN"].lastObject.ts isEqualToString:own.ts], "a fresh Return deletes");
}

SN_TEST(ChannelWaitsForAnUnknownConversation) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = ShellAt(source, @"C03DESIGN", nil);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNExpect([channel.composer.conversationID isEqualToString:@"C03DESIGN"], "the composer writes to the open conversation");
    [shell openConversation:@"C09LATER"];
    SNExpect(!channel.composer.conversationID && channel.composer.hidden && channel.header.hidden, "an unknown one: no composer to send with, no header");
    BOOL before = NO;
    for (SNMessage *message in [source messagesInConversation:@"C03DESIGN"]) before |= [channel.list rowForTS:message.ts] != nil;
    SNExpect(!channel.list.hidden && !before, "and no messages of the one before");
    [source performChanges:^{
        [source applyConversations:@[ @{@"id" : @"C09LATER", @"name" : @"later", @"is_channel" : @YES, @"is_member" : @YES} ]];
    }];
    SNExpect([channel.composer.conversationID isEqualToString:@"C09LATER"] && !channel.header.hidden &&
                 [channel.header.conversation.conversationID isEqualToString:@"C09LATER"],
             "once it is known the column shows it");
}

SN_TEST(ChannelSaysWhenSlackRefusesAConversation) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = ShellAt(source, @"C03DESIGN", nil);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    [shell openConversation:@"C09GONE"];
    SNExpect(!channel.showsUnavailable && !channel.list.hidden, "while Slack is asked, the history waits");
    // The fixture knows no such conversation: conversations.info answers without one.
    SNExpect(SNWaitUntil(1, ^BOOL { return channel.showsUnavailable; }) && channel.list.hidden && channel.composer.hidden && channel.header.hidden,
             "refused: the unavailable state, with neither history, header nor composer");
    [shell openConversation:@"C03DESIGN"];
    SNExpect(!channel.showsUnavailable && !channel.list.hidden && !channel.composer.hidden, "another conversation shows as before");
}

SN_TEST(ComposerSaysWhoIsTyping) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = ShellAt(source, @"C03DESIGN", nil);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNExpect(!channel.composer.noticeText.length, "no one typing, no line");
    NSString * (^name)(NSString *) = ^NSString *(NSString *userID) { return [source userWithID:userID].visibleName; };
    [source applyEvent:@{@"type" : @"user_typing", @"channel" : @"C03DESIGN", @"user" : @"U02SAM"}];
    SNExpect([channel.composer.noticeText isEqualToString:[name(@"U02SAM") stringByAppendingString:@" is typing"]], "one person by name");
    [source applyEvent:@{@"type" : @"user_typing", @"channel" : @"C03DESIGN", @"user" : @"U03PRIYA"}];
    NSString *two = [NSString stringWithFormat:@"%@ and %@ are typing", name(@"U02SAM"), name(@"U03PRIYA")];
    SNExpect([channel.composer.noticeText isEqualToString:two], "two in the order they started");
    [source applyEvent:@{@"type" : @"user_typing", @"channel" : @"C03DESIGN", @"user" : @"U04JORDAN"}];
    SNExpect([channel.composer.noticeText isEqualToString:@"Several people are typing"], "three or more as several");
    [source applyEvent:@{@"type" : @"user_typing", @"channel" : @"C01GENERAL", @"user" : @"U07CASEY"}];
    [source applyEvent:@{@"type" : @"user_typing", @"channel" : @"C03DESIGN", @"user" : @"U01ALEX"}];
    SNExpect([channel.composer.noticeText isEqualToString:@"Several people are typing"], "typing elsewhere, or the user, changes nothing here");
    [source applyEvent:@{@"type" : @"message", @"channel" : @"C03DESIGN", @"user" : @"U03PRIYA", @"text" : @"sent", @"ts" : @"1799000000.000100"}];
    [source applyEvent:@{@"type" : @"message", @"channel" : @"C03DESIGN", @"user" : @"U04JORDAN", @"text" : @"sent", @"ts" : @"1799000000.000200"}];
    SNExpect([channel.composer.noticeText isEqualToString:[name(@"U02SAM") stringByAppendingString:@" is typing"]], "a message ends its sender's typing");
    [shell openConversation:@"C01GENERAL"];
    SNExpect([channel.composer.noticeText isEqualToString:[name(@"U07CASEY") stringByAppendingString:@" is typing"]], "each conversation its own");
}

SN_TEST(ComposerSaysWhenSlackIsTryingToConnect) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = ShellAt(source, @"C03DESIGN", nil);
    SNComposer *composer = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).composer;
    [source applyEvent:@{@"type" : @"user_typing", @"channel" : @"C03DESIGN", @"user" : @"U02SAM"}];
    source.connectionState = SNConnectionConnecting;
    SNSettle(0.1);
    SNExpect([composer.noticeText hasSuffix:@" is typing"], "a short drop says nothing (Slack waits 10 s)");
    // As if the connection had been down for the grace already.
    [composer setValue:[NSDate dateWithTimeIntervalSinceNow:-11] forKey:@"_disconnectedSince"];
    [composer performSelector:@selector(updateNotice)];
    SNExpect([composer.noticeText isEqualToString:@"Slack is trying to connect."], "past it, Slack is trying to connect, in place of who types");
    composer.text = @"a draft";
    SNExpect([composer.noticeText isEqualToString:@"Slack is trying to connect, so messages can’t be sent yet."], "with a draft, sending has to wait");
    source.connectionState = SNConnectionConnected;
    SNExpect([composer.noticeText hasSuffix:@" is typing"], "connected again, the notice goes at once");
}

SN_TEST(ChannelDMHeaderFollowsItsPerson) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNConversation *dm = nil;
    for (SNConversation *conversation in source.directMessages)
        if (conversation.kind == SNConversationDirect) dm = conversation;
    SNShell *shell = ShellAt(source, dm.conversationID, nil);
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    [source performChanges:^{
        [source applyUsers:@[ @{@"id" : dm.userID, @"name" : @"renamed", @"profile" : @{@"display_name" : @"Renamed Person"}} ]];
    }];
    SNExpect([[channel.header valueForKeyPath:@"title.text"] isEqualToString:@"Renamed Person"], "the DM's title follows its person's name");
}

SN_TEST(ThreadMarkUnreadOfTheParentHoldsTheChannel) {
    SNMarkRecorder *source = Recorder();
    NSString *parent = @"1795192800.000103";
    SNShell *shell = ShellAt(source, @"C01GENERAL", parent);
    PretendSeen(shell.window, YES);
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    Choose(thread.list, [source threadInConversation:@"C01GENERAL" ts:parent].firstObject, @"Mark unread");
    SNExpect([source conversationWithID:@"C01GENERAL"].hasUnreads, "the parent marks the channel unread");
    NSUInteger marks = source.readMarks.count;
    Arrive(source, @"C01GENERAL", @"1799600000.000100", nil);
    SNExpect(source.readMarks.count == marks, "and the conversation column, at its bottom, leaves it so");
}

SN_TEST(ChannelMarksOnceSlackGivesTheReadState) {
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
    for (int i = 9; i >= 0; i--)
        [page addObject:@{@"type" : @"message", @"user" : @"U02SAM", @"text" : @"hello", @"ts" : [NSString stringWithFormat:@"%d.000100", 1795400000 + i * 600]}];
    [store applyNewestHistory:@{@"messages" : page, @"has_more" : @NO} inConversation:@"C01GENERAL"];
    SNShell *shell = ShellAt(store, @"C01GENERAL", nil);
    PretendSeen(shell.window, YES);
    SNExpect(![store conversationWithID:@"C01GENERAL"].lastRead, "nothing is marked while Slack has not said what was read");
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400000.000100", @"latest" : @"1795405400.000100", @"has_unreads" : @YES} ]}];
    SNExpect([[store conversationWithID:@"C01GENERAL"].lastRead isEqualToString:@"1795405400.000100"] && ![store conversationWithID:@"C01GENERAL"].hasUnreads,
             "once it has, the reader at the bottom reads through the newest message");
}

SN_TEST(ThreadMarkUnreadOfAReplyMarksTheThread) {
    SNMarkRecorder *source = Recorder();
    NSString *parent = @"1795192800.000103", *key = SNThreadKey(@"C01GENERAL", parent);
    SNShell *shell = ShellAt(source, @"C01GENERAL", parent);
    PretendSeen(shell.window, YES);
    SNThreadPane *thread = (SNThreadPane *)[shell paneInSlot:SNPaneSlotSecondary];
    SNMessage *reply = [source threadInConversation:@"C01GENERAL" ts:parent].lastObject;
    Choose(thread.list, reply, @"Mark unread");
    NSString *expected = [NSString stringWithFormat:@"unread %@ %@", key, reply.ts];
    SNExpect([source.readMarks.lastObject isEqualToString:expected], "a reply marks its thread unread");
    BOOL channel = NO;
    for (NSString *mark in source.readMarks) channel |= [mark hasPrefix:@"unread C01GENERAL "];
    SNExpect(!channel, "never the channel");
    NSUInteger marks = source.readMarks.count;
    Arrive(source, @"C01GENERAL", @"1799600000.000100", parent);
    SNExpect(source.readMarks.count == marks, "and the thread column, at its bottom, leaves it unread");
}
