// The message list's grouping, dividers, virtualization, anchoring and caches; the row geometry
// measured on the captures; and the bench: switching conversations and scrolling with cached
// layouts, timed offscreen.
#import <QuartzCore/QuartzCore.h>

#import "app/launch.h"
#import "model/json.h"
#import "render/strings.h"
#import "test.h"
#import "ui/channel/list.h"
#import "ui/channel/messagelayout.h"
#import "ui/channel/reaction.h"

/// A list in an offscreen window, like the conversation column at the reference size.
static SNMessageListView *List(id<SNSource> source, NSSize size) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    SNMessageListView *list = [[SNMessageListView alloc] initWithSource:source mode:SNMessageListChannel];
    list.frame = (NSRect){NSZeroPoint, size};
    window.contentView = list;
    [list layoutSubtreeIfNeeded];
    return list;
}

/// `count` messages of the design channel's kinds, one every 20 minutes, in a conversation of
/// their own.
static NSArray<SNMessage *> *History(NSString *conversationID, NSUInteger count) {
    NSData *data = [NSData dataWithContentsOfURL:[SNPublicFixture() URLByAppendingPathComponent:@"conversations.history/C03DESIGN.json"]];
    NSArray *templates = SNJSONArray([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], @"messages");
    NSMutableArray<SNMessage *> *messages = [NSMutableArray new];
    for (NSUInteger i = 0; i < count; i++) {
        NSMutableDictionary *json = [templates[i % templates.count] mutableCopy];
        json[@"ts"] = [NSString stringWithFormat:@"%lu.%06lu", 1790000000 + (unsigned long)i * 1200, (unsigned long)i];
        [json removeObjectForKey:@"thread_ts"];
        if ([json[@"subtype"] isEqualToString:@"thread_broadcast"]) [json removeObjectForKey:@"subtype"];
        [messages addObject:[SNMessage messageWithJSON:json conversationID:conversationID]];
    }
    return messages;
}

static NSString *TSOf(NSArray<SNMessage *> *messages, NSString *prefix) {
    for (SNMessage *message in messages)
        if ([message.text hasPrefix:prefix]) return message.ts;
    return @"";
}

/// What a frame costs the app: layout, then every layer that needs it draws its contents (an
/// offscreen window would otherwise draw only when rendered). Compositing is the GPU's.
static void DisplayLayers(CALayer *layer) {
    [layer displayIfNeeded];
    for (CALayer *sublayer in layer.sublayers) DisplayLayers(sublayer);
}

static void Draw(NSView *view) {
    [view.window displayIfNeeded];
    DisplayLayers(view.layer);
    [CATransaction flush];
}

SN_TEST(ChannelRowGeometryMatchesTheCaptures) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    SNMessage *one = [SNMessage messageWithJSON:@{@"ts" : @"1795000000.000001", @"user" : @"U02SAM", @"text" : @"one line"} conversationID:@"C"];
    SNMessageLayout *first = [SNMessageLayout layoutForMessage:one continuation:NO style:SNMessageRowInConversation width:842 renderer:renderer];
    SNMessageLayout *next = [SNMessageLayout layoutForMessage:one continuation:YES style:SNMessageRowInConversation width:842 renderer:renderer];
    SNExpect(first.height == 52 && next.height == 30, "a one-line message is 52 pt, a grouped one 30 (measured)");
    SNExpect(NSEqualRects(first.avatarRect, NSMakeRect(16, 8, 36, 36)) && first.bodyOrigin.x == 60 && first.bodyOrigin.y == 26,
             "avatar 16 in and 8 down, text at 60 under a 22 pt header 4 pt down");
    SNExpect(fabs(NSMinX(first.timeRect) - (60 + [[NSAttributedString alloc] initWithString:first.senderName
                                                                                  attributes:@{NSFontAttributeName : SNFont(15, 900)}].size.width + 7.75)) < 0.01,
             "the time starts 7.75 pt after the name (measured)");
    SNExpect(NSMaxX(next.compactTimeRect) == 52, "a grouped message's time ends at the avatar column's edge");
    SNMessage *reacted = [SNMessage messageWithJSON:@{@"ts" : @"1795000000.000002", @"user" : @"U02SAM", @"text" : @"x", @"reply_count" : @3,
                                                      @"reactions" : @[ @{@"name" : @"tada", @"users" : @[ @"U01ALEX" ], @"count" : @1} ]}
                                     conversationID:@"C"];
    SNMessageLayout *bar = [SNMessageLayout layoutForMessage:reacted continuation:NO style:SNMessageRowInConversation width:842 renderer:renderer];
    NSRect pill = bar.reactionFrames.firstObject.rectValue;
    SNExpect(bar.reactionFrames.count == 2 && pill.size.height == 24 && NSMinY(pill) == 48 + 6, "reactions 24 pt tall, 6 pt under the text, then the add pill");
    SNExpect(NSMinX(bar.replyBarRect) == 55 && NSMinY(bar.replyBarRect) == NSMaxY(pill) && bar.replyBarRect.size.height == 34,
             "reply bar 34 pt, hanging 5 pt left of the text");
    SNExpect(SNReactionWidth(reacted.reactions.firstObject, YES) > SNReactionWidth(reacted.reactions.firstObject, NO) - 1, "pill fits its count");
}

SN_TEST(ChannelListGroupsAndDivides) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = List(source, NSMakeSize(842, 700));
    NSArray<SNMessage *> *messages = [source messagesInConversation:@"C03DESIGN"];
    [list showMessages:messages inConversation:@"C03DESIGN" threadTS:nil lastRead:messages[3].ts];
    SNExpect(list.atBottom, "a conversation opens at the bottom");
    SNMessageRowView *grouped = [list rowForTS:TSOf(messages, @"grouped one")];
    SNExpect(grouped.layout.continuation, "a message right after the same sender's groups under it");
    SNExpect(![list rowForTS:TSOf(messages, @"<@U07CASEY>")].layout.continuation, "a join message starts its own group");
    SNExpect(list.visibleRowCount < messages.count + 2, "only rows in view exist");
    CGFloat height = list.contentHeight;
    [list scrollToOffset:0];
    SNExpect(!list.atBottom && [list rowForTS:messages.firstObject.ts], "scrolling to the top shows the first message");
    [list showMessages:[messages arrayByAddingObject:[SNMessage messageWithJSON:@{@"ts" : @"1795400000.000001", @"user" : @"U02SAM", @"text" : @"new"}
                                                                  conversationID:@"C03DESIGN"]]
        inConversation:@"C03DESIGN"
              threadTS:nil
              lastRead:messages[3].ts];
    SNExpect([list rowForTS:messages.firstObject.ts] && !list.atBottom, "a new message keeps a reader who scrolled up in place");
    SNExpect(list.contentHeight > height + 41, "the new message brings a new day's divider");
    [list scrollToBottom];
    [list showMessages:messages inConversation:@"C03DESIGN" threadTS:nil lastRead:nil];
    SNExpect(list.atBottom, "at the bottom it stays at the bottom");
    [list hoverMessageTS:messages.lastObject.ts];
    SNExpect(!list.actionBar.hidden && list.actionBar.buttons.count == 8, "hovering shows the 8-button action bar (no summarize without replies)");
    [list hoverMessageTS:TSOf(messages, @"reacted")];
    SNExpect(list.actionBar.buttons.count == 9, "a message with replies adds summarize");
    [list hoverMessageTS:nil];
    SNExpect(list.actionBar.hidden, "no hover, no bar");
}

SN_TEST(ChannelReactionsToggleThroughTheSource) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSetLanguage(@"en");
    SNMessage *message = nil;
    for (SNMessage *candidate in [source messagesInConversation:@"C03DESIGN"])
        if (candidate.reactions.count) message = candidate;
    SNReaction *tada = message.reactions.firstObject;
    SNExpect([SNReactionTooltipText(tada, source) isEqualToString:@"You and priya reacted with :tada:"], "tooltip names the user first, then the others");
    SNMessageListView *list = List(source, NSMakeSize(842, 700));
    [list showMessages:[source messagesInConversation:@"C03DESIGN"] inConversation:@"C03DESIGN" threadTS:nil lastRead:nil];
    SNMessageRowView *row = [list rowForTS:message.ts];
    SNExpect(row.pills.count == message.reactions.count + 1 && row.replyBar, "a pill per reaction, the add pill and the reply bar");
    [row.delegate messageRow:row toggleReaction:@"tada"];
    SNMessage *after = nil;
    for (SNMessage *candidate in [source messagesInConversation:@"C03DESIGN"])
        if ([candidate.ts isEqualToString:message.ts]) after = candidate;
    SNExpect(after.reactions.firstObject.count == 1, "clicking the user's own reaction removes it");
}

SN_TEST(ChannelBench) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = List(source, NSMakeSize(842, 700));
    NSArray *a = History(@"CBENCHA", 400), *b = History(@"CBENCHB", 400);
    CFTimeInterval start = CACurrentMediaTime();
    [list showMessages:a inConversation:@"CBENCHA" threadTS:nil lastRead:nil];
    Draw(list);
    CFTimeInterval cold = CACurrentMediaTime() - start;
    [list showMessages:b inConversation:@"CBENCHB" threadTS:nil lastRead:nil];
    Draw(list);
    // Switching between two conversations whose layouts are cached, drawn as a frame would be.
    CFTimeInterval worst = 0, total = 0;
    for (int i = 0; i < 20; i++) {
        start = CACurrentMediaTime();
        [list showMessages:i % 2 ? b : a inConversation:i % 2 ? @"CBENCHB" : @"CBENCHA" threadTS:nil lastRead:nil];
        Draw(list);
        CFTimeInterval elapsed = CACurrentMediaTime() - start;
        worst = MAX(worst, elapsed), total += elapsed;
    }
    printf("bench: first open of 400 messages %.1f ms; cached switch avg %.2f ms, worst %.2f ms\n", cold * 1000, total / 20 * 1000, worst * 1000);
    SNExpect(total / 20 < 1.0 / 120, "a cached switch takes less than a 120 Hz frame");

    // Scrolling the whole history up at 24 pt per frame (a brisk trackpad flick at 120 Hz).
    CGFloat offset = list.contentHeight;
    NSMutableArray<NSNumber *> *frames = [NSMutableArray new];
    while (offset > 0) {
        offset -= 24;
        start = CACurrentMediaTime();
        [list scrollToOffset:offset];
        Draw(list);
        [frames addObject:@(CACurrentMediaTime() - start)];
    }
    NSArray *sorted = [frames sortedArrayUsingSelector:@selector(compare:)];
    double average = [[frames valueForKeyPath:@"@avg.self"] doubleValue], p99 = [sorted[(NSUInteger)(sorted.count * 0.99)] doubleValue];
    printf("bench: scroll %lu frames, avg %.2f ms, p99 %.2f ms, worst %.2f ms\n", (unsigned long)frames.count, average * 1000, p99 * 1000,
           [sorted.lastObject doubleValue] * 1000);
    SNExpect(p99 < 1.0 / 120, "99% of scroll frames fit in a 120 Hz frame");
}
