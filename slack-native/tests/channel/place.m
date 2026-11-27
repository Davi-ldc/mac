// The list keeps the reader's place through every change at any offset, pages older history
// once per visit to the top, lays out only the messages that changed and bounds its caches.
#import <QuartzCore/QuartzCore.h>

#import "app/launch.h"
#import "model/json.h"
#import "render/strings.h"
#import "snapshot.h"
#import "store/internal.h"
#import "test.h"
#import "ui/channel/list.h"
#import "ui/channel/reaction.h"
#import "ui/channel/replybar.h"
#import "ui/files/fileview.h"

static SNMessageListView *PlaceList(id<SNSource> source, NSSize size) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    SNMessageListView *list = [[SNMessageListView alloc] initWithSource:source mode:SNMessageListChannel];
    list.frame = (NSRect){NSZeroPoint, size};
    window.contentView = [[NSView alloc] initWithFrame:list.frame];
    [window.contentView addSubview:list];
    [list layoutSubtreeIfNeeded];
    return list;
}

/// Message `i` of a made-up conversation, one every 20 minutes; `text` sets its length.
static SNMessage *Made(NSString *conversationID, NSUInteger i, NSString *text) {
    return [SNMessage messageWithJSON:@{@"ts" : [NSString stringWithFormat:@"%lu.000100", 1790000000 + (unsigned long)i * 1200],
                                        @"user" : i % 3 ? @"U02SAM" : @"U01ALEX", @"text" : text ?: [NSString stringWithFormat:@"message %lu", (unsigned long)i]}
                       conversationID:conversationID];
}

static NSArray<SNMessage *> *MadeRange(NSString *conversationID, NSUInteger from, NSUInteger to) {
    NSMutableArray *messages = [NSMutableArray new];
    for (NSUInteger i = from; i < to; i++) [messages addObject:Made(conversationID, i, nil)];
    return messages;
}

/// How far below the list's top the row of `ts` starts.
static CGFloat Offset(SNMessageListView *list, NSString *ts) {
    SNMessageRowView *row = [list rowForTS:ts];
    return row ? NSMinY(row.frame) - NSMinY(list.scrollView.contentView.bounds) : CGFLOAT_MAX;
}

/// The first message row whose top is in view.
static NSString *TopTS(SNMessageListView *list) {
    NSString *best = nil;
    CGFloat top = CGFLOAT_MAX, visible = NSMinY(list.scrollView.contentView.bounds);
    for (NSView *view in list.scrollView.documentView.subviews)
        if ([view isKindOfClass:SNMessageRowView.class] && !view.hidden && NSMinY(view.frame) >= visible && NSMinY(view.frame) < top) {
            top = NSMinY(view.frame);
            best = ((SNMessageRowView *)view).message.ts;
        }
    return best;
}

SN_TEST(ChannelListKeepsThePlaceAtAnyOffset) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    NSMutableArray<SNMessage *> *messages = [MadeRange(@"CPLACE", 20, 140) mutableCopy];
    [list showMessages:messages inConversation:@"CPLACE" threadTS:nil lastRead:nil];
    [list scrollToOffset:list.contentHeight / 2];
    NSString *anchor = TopTS(list);
    // The reader's place is the row at the top of the view, here exactly at its top.
    [list scrollToOffset:NSMinY([list rowForTS:anchor].frame)];
    CGFloat offset = Offset(list, anchor);
    SNExpect(anchor && offset == 0 && NSMinY(list.scrollView.contentView.bounds) > 1000, "the reader is in the middle of the history");

    [messages addObject:Made(@"CPLACE", 140, nil)];
    [list showMessages:messages inConversation:@"CPLACE" threadTS:nil lastRead:nil];
    SNExpect(fabs(Offset(list, anchor) - offset) < 0.5, "a new message at the end leaves the reader where they were");

    [messages insertObjects:MadeRange(@"CPLACE", 0, 20) atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 20)]];
    [list showMessages:messages inConversation:@"CPLACE" threadTS:nil lastRead:nil];
    SNExpect(fabs(Offset(list, anchor) - offset) < 0.5, "an older page above too");

    NSUInteger above = [[messages valueForKey:@"ts"] indexOfObject:anchor] - 3;
    SNMessage *longer = [messages[above] messageByMergingJSON:@{@"text" : [@"" stringByPaddingToLength:900 withString:@"longer words " startingAtIndex:0]}];
    messages[above] = longer;
    [list applyChange:SNChangeOf(SNChangeMessageKeys, SNMessageKey(longer))];
    [list showMessages:messages inConversation:@"CPLACE" threadTS:nil lastRead:nil];
    SNExpect(fabs(Offset(list, anchor) - offset) < 0.5, "an edit that makes a message above taller too");

    NSUInteger index = [[messages valueForKey:@"ts"] indexOfObject:anchor];
    NSString *next = messages[index + 1].ts;
    CGFloat nextOffset = Offset(list, next);
    [messages removeObjectAtIndex:index];
    [list showMessages:messages inConversation:@"CPLACE" threadTS:nil lastRead:nil];
    SNExpect(fabs(Offset(list, next) - nextOffset) < 0.5, "deleting the message at the top keeps the next one still");

    NSRect frame = list.frame;
    list.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height - 120);
    list.needsLayout = YES;
    [list layoutSubtreeIfNeeded];
    SNExpect(fabs(Offset(list, next) - nextOffset) < 0.5, "a taller composer shortening the list keeps it too");
    [list scrollToBottom];
    list.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height - 200);
    list.needsLayout = YES;
    [list layoutSubtreeIfNeeded];
    SNExpect(list.atBottom, "and at the bottom the newest message stays in view");
}

SN_TEST(ChannelListUpdatesOnlyChangedRows) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    NSMutableArray<SNMessage *> *messages = [MadeRange(@"CROWS", 0, 60) mutableCopy];
    [list showMessages:messages inConversation:@"CROWS" threadTS:nil lastRead:nil];
    SNMessage *last = messages.lastObject, *before = messages[messages.count - 2];
    SNMessageRowView *lastRow = [list rowForTS:last.ts], *beforeRow = [list rowForTS:before.ts];
    SNMessageLayout *beforeLayout = beforeRow.layout;
    [list hoverMessageTS:before.ts];

    // The source decodes the history again (same content, new objects) and one message changes.
    NSMutableArray<SNMessage *> *copies = [NSMutableArray new];
    for (SNMessage *message in messages) [copies addObject:[SNMessage messageWithJSON:message.json conversationID:@"CROWS"]];
    copies[copies.count - 1] = [last messageByMergingJSON:@{@"text" : @"edited"}];
    [list applyChange:SNChangeOf(SNChangeMessageKeys, SNMessageKey(last))];
    [list showMessages:copies inConversation:@"CROWS" threadTS:nil lastRead:nil];
    SNExpect([list rowForTS:before.ts] == beforeRow && beforeRow.layout == beforeLayout, "an unchanged message keeps its row and its layout");
    SNExpect(beforeRow.hovered && !list.actionBar.hidden, "and its hover");
    SNExpect([list rowForTS:last.ts] == lastRow && [lastRow.message.text isEqualToString:@"edited"], "the changed one is laid out again in its row");

    // Presence changes nothing that is drawn.
    [list showMessages:copies inConversation:@"CROWS" threadTS:nil lastRead:nil];
    SNUser *sam = [source userWithID:@"U02SAM"];
    SNExpect(![list applyChange:SNChangeOf(SNChangeUsers, sam.userID)] && beforeRow.layout == beforeLayout,
             "a presence change keeps every layout");
}

SN_TEST(ChannelListChangesInPlace) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel = @"C03DESIGN";
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    NSArray<SNMessage *> *messages = [source messagesInConversation:channel];
    [list showMessages:messages inConversation:channel threadTS:nil lastRead:nil];
    SNMessage *last = messages.lastObject, *before = messages[messages.count - 2];
    SNMessageRowView *beforeRow = [list rowForTS:before.ts];
    SNMessageLayout *beforeLayout = beforeRow.layout;
    __block SNChange *changes = nil;
    id observer = SNObserveChanges(source, ^(SNChange *change) { changes = change; });
    BOOL (^apply)(NSDictionary *) = ^BOOL(NSDictionary *event) {
        [source applyEvent:event];
        SNFlushChanges();
        [list applyChange:changes];
        return [list showChangedMessages:changes];
    };
    /// The list as showing the history anew lays it out.
    BOOL (^same)(void) = ^BOOL {
        SNMessageListView *fresh = PlaceList(source, NSMakeSize(842, 700));
        [fresh showMessages:[source messagesInConversation:channel] inConversation:channel threadTS:nil lastRead:nil];
        return fresh.contentHeight == list.contentHeight;
    };
    SNExpect(apply(@{@"type" : @"reaction_added", @"user" : @"U02SAM", @"reaction" : @"tada", @"item" : @{@"type" : @"message", @"channel" : channel, @"ts" : last.ts}}),
             "a reaction changes the list in place");
    SNExpect([list rowForTS:last.ts].message.reactions.count > last.reactions.count, "its row shows it");
    SNExpect([list rowForTS:before.ts] == beforeRow && beforeRow.layout == beforeLayout && same(), "the other rows keep their layouts");
    NSString *nextDay = [NSString stringWithFormat:@"%.6f", last.ts.doubleValue + 86400 * 2];
    SNExpect(apply(@{@"type" : @"message", @"channel" : channel, @"user" : @"U02SAM", @"text" : @"days later", @"ts" : nextDay}) && same(),
             "a message on another day comes with its divider");
    NSString *grouped = [NSString stringWithFormat:@"%.6f", nextDay.doubleValue + 30];
    SNExpect(apply(@{@"type" : @"message", @"channel" : channel, @"user" : @"U02SAM", @"text" : @"right after", @"ts" : grouped}) &&
                 [list rowForTS:grouped].layout.continuation && same(),
             "one right after it groups under it");
    SNExpect(apply(@{@"type" : @"message", @"subtype" : @"message_deleted", @"channel" : channel, @"deleted_ts" : nextDay}) && same() &&
                 ![list rowForTS:grouped].layout.continuation,
             "taking the first away gives the next the divider and the sender");
    SNStopObserving(observer);
}

SN_TEST(ChannelListBoundsItsLayouts) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    for (NSUInteger c = 0; c < 7; c++) {
        NSString *conversationID = [NSString stringWithFormat:@"CBOUND%lu", (unsigned long)c];
        [list showMessages:MadeRange(conversationID, 0, 50) inConversation:conversationID threadTS:nil lastRead:nil];
    }
    SNExpect(list.cachedLayoutKeys.count == 4 && [list.cachedLayoutKeys.firstObject isEqualToString:@"CBOUND6"],
             "layouts of the shown conversation and the three before it");
    [list showMessages:MadeRange(@"CBOUND6", 40, 50) inConversation:@"CBOUND6" threadTS:nil lastRead:nil];
    NSUInteger count = list.cachedLayoutCount;
    [list showMessages:MadeRange(@"CBOUND5", 0, 50) inConversation:@"CBOUND5" threadTS:nil lastRead:nil];
    SNExpect(count <= 3 * 50 + 10 && list.cachedLayoutCount == count, "only of the messages still shown; switching back lays nothing out");
}

/// A history served a page of five at a time, the way the store answers from its cache: the
/// change arrives before loadOlderMessagesInConversation: returns.
@interface SNPagedSource : SNFixtureSource
@property (nonatomic) NSArray<SNMessage *> *all;
@property (nonatomic) NSUInteger loaded, olderCalls;
@end

@implementation SNPagedSource

- (NSArray<SNMessage *> *)messagesInConversation:(NSString *)conversationID {
    if (![conversationID isEqualToString:@"CPAGED"]) return [super messagesInConversation:conversationID];
    return [self.all subarrayWithRange:NSMakeRange(self.all.count - self.loaded, self.loaded)];
}

- (BOOL)hasOlderMessagesInConversation:(NSString *)conversationID {
    return [conversationID isEqualToString:@"CPAGED"] ? self.loaded < self.all.count : [super hasOlderMessagesInConversation:conversationID];
}

- (BOOL)isLoadingMessagesInConversation:(NSString *)conversationID { return NO; }

- (void)loadOlderMessagesInConversation:(NSString *)conversationID {
    self.olderCalls++;
    self.loaded = MIN(self.all.count, self.loaded + 5);
    [self changed:SNChangeMessages value:@"CPAGED"];
    SNFlushChanges();
}

@end

SN_TEST(ChannelListLoadsOlderPagesOncePerVisit) {
    SNSetLanguage(@"en");
    SNPagedSource *source = [SNPagedSource sourceWithFolder:SNPublicFixture()];
    source.all = MadeRange(@"CPAGED", 0, 200);
    source.loaded = 60;
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    id observer = SNObserveChanges(source, ^(SNChange *change) {
        [list showMessages:[source messagesInConversation:@"CPAGED"] inConversation:@"CPAGED" threadTS:nil lastRead:nil];
    });
    [list showMessages:[source messagesInConversation:@"CPAGED"] inConversation:@"CPAGED" threadTS:nil lastRead:nil];
    SNExpect(source.olderCalls == 0 && list.atBottom, "opening far from the top loads nothing");
    NSString *first = source.all[140].ts;
    [list scrollToOffset:0];
    SNExpect(source.olderCalls == 1 && source.loaded == 65, "reaching the top asks for one page");
    // At the top the first message sat under its day's divider (or at the very top).
    CGFloat offset = Offset(list, first);
    SNExpect(offset >= 0 && offset <= 41 && NSMinY(list.scrollView.contentView.bounds) > 0, "which lands above the reader without moving them");
    SNSettle(0.05);
    SNExpect(source.olderCalls == 1, "and nothing more follows by itself, though the page was short");
    [list scrollToOffset:NSMinY(list.scrollView.contentView.bounds) - 10];
    SNExpect(source.olderCalls == 2, "scrolling up again asks for the next");
    SNStopObserving(observer);
}

SN_TEST(ChannelEditorKeepsTheKeyboard) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    NSMutableArray<SNMessage *> *messages = [MadeRange(@"CEDIT", 0, 40) mutableCopy];
    [list showMessages:messages inConversation:@"CEDIT" threadTS:nil lastRead:nil];
    SNMessage *own = messages[36];
    SNExpect([own.userID isEqualToString:source.me.userID], "the user's own message");
    [list editMessage:own];
    NSResponder *keyboard = list.window.firstResponder;
    SNExpect([keyboard isKindOfClass:NSView.class] && [(NSView *)keyboard isDescendantOf:list.editor], "editing takes the keyboard");
    [messages addObject:Made(@"CEDIT", 40, nil)];
    messages[10] = [messages[10] messageByMergingJSON:@{@"text" : @"edited somewhere else, and longer than it was before by a good few words"}];
    [list applyChange:SNChangeOf(SNChangeMessageKeys, SNMessageKey(messages[10]))];
    [list showMessages:messages inConversation:@"CEDIT" threadTS:nil lastRead:nil];
    [list scrollToOffset:0];
    [list scrollToBottom];
    SNExpect(list.window.firstResponder == keyboard && !list.editor.hidden, "messages arriving, changing and scrolling by keep it");
    [list.editor cancel];
}

SN_TEST(ChannelListBottomAnchorsOnShortAppend) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel = @"CSHORT";
    [source applyConversations:@[ @{@"id" : channel, @"name" : @"short", @"is_channel" : @YES, @"is_member" : @YES} ]];
    [source applyNewestHistory:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400001.000100", @"user" : @"U02SAM", @"text" : @"First short message"} ], @"has_more" : @NO}
                inConversation:channel];
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    list.bottomInset = 18;
    __block SNChange *changes = nil;
    id observer = SNObserveChanges(source, ^(SNChange *change) { changes = change; });
    void (^post)(NSString *, NSString *) = ^(NSString *ts, NSString *text) {
        [source applyEvent:@{@"type" : @"message", @"channel" : channel, @"user" : @"U02SAM", @"text" : text, @"ts" : ts}];
        SNFlushChanges();
    };
    [list showMessages:[source messagesInConversation:channel] inConversation:channel threadTS:nil lastRead:nil];
    SNMessageRowView *firstRow = [list rowForTS:@"1795400001.000100"];
    CGFloat initialTop = NSMinY(firstRow.frame);
    SNExpect(firstRow && initialTop > 400 && fabs(NSMaxY(firstRow.frame) - (700 - 18)) < 1, "short conversation is bottom-anchored");

    // Appending one message in place keeps the list bottom-anchored without blank void.
    post(@"1795400060.000100", @"Second short message");
    [list applyChange:changes];
    SNExpect([list showChangedMessages:changes], "append applies in place");
    firstRow = [list rowForTS:@"1795400001.000100"];
    SNMessageRowView *secondRow = [list rowForTS:@"1795400060.000100"];
    SNExpect(firstRow && secondRow && NSMinY(firstRow.frame) < initialTop && fabs(NSMaxY(secondRow.frame) - (700 - 18)) < 1,
             "in-place append shifts existing rows up and keeps bottom anchoring");

    // Appending enough messages to exceed viewport resets top to 0 (no blank void above first item).
    for (int i = 2; i < 22; i++) {
        NSString *ts = [NSString stringWithFormat:@"%ld.000100", 1795400000L + i * 600L];
        post(ts, @"A multi-line message to push the short conversation past the viewport height so bottom anchoring releases cleanly.");
        [list applyChange:changes];
        SNExpect([list showChangedMessages:changes], "subsequent append applies in place");
    }
    [list scrollToOffset:0];
    firstRow = [list rowForTS:@"1795400001.000100"];
    SNExpect(firstRow && NSMinY(firstRow.frame) <= 50, "overflowing the viewport removes bottom-anchor offset (no blank void)");
    SNStopObserving(observer);
}

static NSView *FindSubviewOfClass(NSView *view, Class kind) {
    if ([view isKindOfClass:kind]) return view;
    for (NSView *subview in view.subviews) {
        NSView *found = FindSubviewOfClass(subview, kind);
        if (found) return found;
    }
    return nil;
}

static BOOL PixelsEqualInRect(SNPixels *a, SNPixels *b, NSRect rect, BOOL *nonEmpty) {
    if (a.width != b.width || a.height != b.height) return NO;
    size_t x0 = (size_t)MAX(0, floor(NSMinX(rect) * SNSnapshotScale)), x1 = (size_t)MIN(a.width, ceil(NSMaxX(rect) * SNSnapshotScale));
    size_t y0 = (size_t)MAX(0, floor(NSMinY(rect) * SNSnapshotScale)), y1 = (size_t)MIN(a.height, ceil(NSMaxY(rect) * SNSnapshotScale));
    BOOL seen = NO;
    for (size_t y = y0; y < y1; y++) {
        for (size_t x = x0; x < x1; x++) {
            size_t off = (y * a.width + x) * 4;
            if (memcmp(a.bytes + off, b.bytes + off, 4) != 0) return NO;
            if (b.bytes[off + 3] > 0) seen = YES;
        }
    }
    if (nonEmpty) *nonEmpty = seen;
    return YES;
}

SN_TEST(ChannelListRecycleReusesLayerBackedSubviews) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = PlaceList(source, NSMakeSize(842, 700));
    list.window.opaque = NO;
    list.window.backgroundColor = NSColor.clearColor;
    list.window.contentView.wantsLayer = YES;
    NSMutableArray<SNMessage *> *messages = [MadeRange(@"CRECYCLE", 0, 39) mutableCopy];
    SNMessage *rich = [SNMessage messageWithJSON:@{
        @"ts" : @"1795500000.000100",
        @"user" : @"U02SAM",
        @"text" : @"Message with reaction, replies and file",
        @"reactions" : @[ @{@"name" : @"tada", @"users" : @[ @"U02SAM" ], @"count" : @1} ],
        @"thread_ts" : @"1795500000.000100",
        @"reply_count" : @2,
        @"reply_users" : @[ @"U01ALEX", @"U02SAM" ],
        @"reply_users_count" : @2,
        @"latest_reply" : @"1795500100.000100",
        @"files" : @[ @{@"id" : @"F01REC", @"name" : @"notes.txt", @"title" : @"notes.txt", @"filetype" : @"text", @"size" : @128} ],
    }
                                  conversationID:@"CRECYCLE"];
    [messages addObject:rich];
    [list showMessages:messages inConversation:@"CRECYCLE" threadTS:nil lastRead:nil];
    SNPixels *before = SNRenderView(list, NSMakeSize(842, 700));
    SNMessageRowView *row = [list rowForTS:rich.ts];
    NSView *beforePill = FindSubviewOfClass(row, SNReactionPill.class);
    NSView *beforeBar = FindSubviewOfClass(row, SNReplyBar.class);
    NSView *beforeFile = FindSubviewOfClass(row, SNFileView.class);
    SNExpect(row && beforePill && beforeBar && beforeFile, "rich row shows reaction pill, reply bar and file view");
    NSRect pillRect = [beforePill convertRect:beforePill.bounds toView:list];
    NSRect barRect = [beforeBar convertRect:beforeBar.bounds toView:list];
    NSRect fileRect = [beforeFile convertRect:beforeFile.bounds toView:list];

    // Scroll far away so the row is recycled (prepareForReuse + ClearLayerContents), then back.
    [list scrollToOffset:0];
    SNExpect([list rowForTS:rich.ts] == nil, "rich row recycled when off screen");
    [list scrollToBottom];
    SNPixels *after = SNRenderView(list, NSMakeSize(842, 700));
    SNMessageRowView *restored = [list rowForTS:rich.ts];
    NSView *pill = FindSubviewOfClass(restored, SNReactionPill.class);
    NSView *bar = FindSubviewOfClass(restored, SNReplyBar.class);
    NSView *file = FindSubviewOfClass(restored, SNFileView.class);
    BOOL pillDrawn = NO, barDrawn = NO, fileDrawn = NO;
    BOOL pillSame = PixelsEqualInRect(before, after, pillRect, &pillDrawn);
    BOOL barSame = PixelsEqualInRect(before, after, barRect, &barDrawn);
    BOOL fileSame = PixelsEqualInRect(before, after, fileRect, &fileDrawn);
    SNExpect(restored && pill && !pill.hidden && bar && !bar.hidden && file && !file.hidden,
             "reused row restores reaction pill, reply bar and file view");
    SNExpect(pillDrawn && pillSame && barDrawn && barSame && fileDrawn && fileSame,
             "reused row redraws reaction pill, reply bar and file view identically without blanking");
}
