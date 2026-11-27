// The composer against the official app's captures, at rest, focused, typed into and hovered.
#import "app/launch.h"
#import "snapshot.h"
#import "test.h"
#import "ui/composer/composer.h"
#import "ui/composer/textview.h"
#import "ui/kit/button.h"
#import "ui/kit/tooltip.h"

/// A borderless offscreen window around a host of `size` filled like the conversation pane, with
/// the composer at `frame` in it (top-left coordinates).
static SNComposer *Composer(id<SNSource> source, NSSize size, NSRect frame) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView *host = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, size}];
    host.wantsLayer = YES;
    host.layer.backgroundColor = SNCGColor(SNMeasuredMessagePaneBg);
    window.contentView = host;
    SNComposer *composer = [[SNComposer alloc] initWithSource:source];
    composer.frame = NSMakeRect(NSMinX(frame), size.height - NSMaxY(frame), NSWidth(frame), NSHeight(frame));
    [host addSubview:composer];
    return composer;
}

static void Resize(SNComposer *composer, CGFloat top, NSSize size) {
    CGFloat height = composer.preferredHeight;
    composer.frame = NSMakeRect(composer.frame.origin.x, size.height - top - height, composer.frame.size.width, height);
}

static SNComposerTextView *ComposerText(NSView *view) {
    if ([view isKindOfClass:SNComposerTextView.class]) return (SNComposerTextView *)view;
    for (NSView *subview in view.subviews) {
        SNComposerTextView *found = ComposerText(subview);
        if (found) return found;
    }
    return nil;
}

/// Keys typed at the end of the composer's text: "\n" is Shift+Return.
static void Type(SNComposer *composer, NSString *keys) {
    SNComposerTextView *text = ComposerText(composer);
    text.selectedRange = NSMakeRange(text.string.length, 0);
    for (NSUInteger i = 0; i < keys.length; i++) {
        NSString *key = [keys substringWithRange:NSMakeRange(i, 1)];
        if ([key isEqualToString:@"\n"]) [text insertLineBreak];
        else [text insertText:key replacementRange:text.selectedRange];
    }
}

/// The DM of the capture with the notice: its person has paused notifications for the hour.
static NSString *PausedDM(SNFixtureSource *source) {
    SNConversation *dm = nil;
    for (SNConversation *conversation in source.directMessages)
        if (!dm && conversation.kind == SNConversationDirect) dm = conversation;
    if (dm.userID) [source applyDoNotDisturb:@{dm.userID : @{@"snooze_enabled" : @YES, @"snooze_endtime" : @(NSDate.date.timeIntervalSince1970 + 3600)}}];
    return dm.conversationID;
}

static NSString *ChannelID(id<SNSource> source) {
    for (SNSection *section in source.sections)
        for (NSString *conversationID in section.conversationIDs)
            if ([source conversationWithID:conversationID].kind == SNConversationPrivateChannel) return conversationID;
    return source.sections.firstObject.conversationIDs.firstObject;
}

static NSArray<SNRegion *> *BoxRegions(CGFloat x, CGFloat y, CGFloat width, NSString *placeholder) {
    return @[
        [SNRegion region:@"border and fill" rect:NSMakeRect(x + 430, y, width - 430 - 80, 41) budget:1],
        [SNRegion region:@"formatting bar" rect:NSMakeRect(x, y, 425, 41) budget:3],
        [SNRegion ignored:placeholder rect:NSMakeRect(x + 12, y + 41, 500, 36)],
        [SNRegion region:@"text area right" rect:NSMakeRect(x + 520, y + 41, width - 520, 36) budget:1],
        [SNRegion region:@"footer buttons" rect:NSMakeRect(x, y + 77, 250, 41) budget:7],
        [SNRegion region:@"send" rect:NSMakeRect(x + width - 75, y + 77, 75, 41) budget:4],
        [SNRegion region:@"footer middle" rect:NSMakeRect(x + 250, y + 77, width - 325, 41) budget:1],
    ];
}

SN_SNAPSHOT(ComposerMatchesTheCaptures) {
    SNFixtureSource *source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    // composer_default_with_notice: the pane starts 1 pt into the crop, the context bar 9.5 pt
    // down, and the card's border closes the pane 193 pt down and 843 pt across.
    NSSize crop = NSMakeSize(848, 198);
    SNComposer *composer = Composer(source, crop, NSMakeRect(1, 9.5, 842, 100));
    [composer showConversation:PausedDM(source) threadTS:nil];
    Resize(composer, 9.5, crop);
    SNPixels *pixels = SNRenderView(composer.superview, crop);
    SNExpect(composer.preferredHeight == 41 + 118.5 + 24, "preferred height: notice, one line box, margin");
    NSMutableArray *regions = [BoxRegions(21, 50.5, 802, @"placeholder (made-up name)") mutableCopy];
    [regions addObjectsFromArray:@[
        [SNRegion region:@"pane above" rect:NSMakeRect(1, 0, 842, 9) budget:1],
        [SNRegion region:@"notice icon" rect:NSMakeRect(21, 9.5, 40, 41) budget:6],
        [SNRegion region:@"notice text" rect:NSMakeRect(61, 9.5, 762, 41) budget:6],
        [SNRegion region:@"pane below" rect:NSMakeRect(1, 170, 842, 22) budget:1],
        [SNRegion ignored:@"card edge (shell)" rect:NSMakeRect(843, 0, 5, 198)],
        [SNRegion ignored:@"card bottom (shell)" rect:NSMakeRect(0, 192, 848, 6)],
    ]];
    SNCompareWithReference(@"composer_notice", pixels, @"composer_default_with_notice", NSZeroPoint, 1, regions);

    // composer_toolbar_and_footer: the box alone, its border 20 pt in and 0.5 pt down.
    NSSize boxCrop = NSMakeSize(847, 125);
    SNComposer *channel = Composer(source, boxCrop, NSMakeRect(0, 0.5, 842, 100));
    [channel showConversation:ChannelID(source) threadTS:nil];
    Resize(channel, 0.5, boxCrop);
    SNCompareWithReference(@"composer_box", SNRenderView(channel.superview, boxCrop), @"composer_toolbar_and_footer", NSZeroPoint, 1,
                           BoxRegions(20, 0.5, 802, @"placeholder (made-up channel)"));
}

SN_SNAPSHOT(ComposerFocusedAndTyped) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    // composer_focused_self_dm: the pane starts 1 pt in, the box 10.5 pt down, 946 pt wide.
    NSSize crop = NSMakeSize(989, 157);
    SNComposer *composer = Composer(source, crop, NSMakeRect(1, 10.5, 986, 100));
    [composer showConversation:ChannelID(source) threadTS:nil];
    Resize(composer, 10.5, crop);
    [composer focus];
    SNExpect(composer.isFocused, "focus takes the text");
    NSMutableArray *regions = [BoxRegions(21, 10.5, 946, @"placeholder and caret (own DM)") mutableCopy];
    [regions addObject:[SNRegion ignored:@"card edge (shell)" rect:NSMakeRect(986, 0, 3, 157)]];
    [regions addObject:[SNRegion ignored:@"card bottom (shell)" rect:NSMakeRect(0, 152, 989, 5)]];
    SNCompareWithReference(@"composer_focused", SNRenderView(composer.superview, crop), @"composer_focused_self_dm", NSZeroPoint, 1, regions);

    // Typed: formatting, a list and a quote; the box grows a line box per line (up to 60% of
    // the window less 80 pt) and the send button turns green.
    [composer.window setContentSize:NSMakeSize(989, 700)];
    composer.text = @"Hello *team*, _see_ ~this~ `code` and https://example.com";
    Type(composer, @"\n- one\ntwo\n\n> quoted");
    Resize(composer, 10.5, NSMakeSize(989, 400));
    SNExpect(composer.preferredHeight == 118.5 + 24 + 3 * SNComposerLineHeight, "grows one line box per line");
    Resize(composer, 10.5, NSMakeSize(989, 700));
    SNSaveSnapshot(@"composer_typed", SNRenderView(composer.superview, NSMakeSize(989, 700)));

    composer.text = [@"" stringByPaddingToLength:5 * 40 withString:@"line\n" startingAtIndex:0];
    SNExpect(composer.preferredHeight == 96 + 700 * 0.6 - 80 + 24, "stops growing at 60% of the window less 80 pt, then scrolls");
}

/// The footer's buttons in the order of the captures' crops (plus, Aa, emoji...).
static NSArray<SNButton *> *FooterButtons(SNComposer *composer) {
    [composer layoutSubtreeIfNeeded];
    NSMutableArray *buttons = [NSMutableArray new];
    NSMutableArray *views = [NSMutableArray arrayWithObject:composer];
    while (views.count) {
        NSView *view = views.firstObject;
        [views removeObjectAtIndex:0];
        [views addObjectsFromArray:view.subviews];
        if ([view isKindOfClass:SNButton.class] && NSMinY(view.frame) > 60) [buttons addObject:view];
    }
    [buttons sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) { return [@(NSMinX(a.frame)) compare:@(NSMinX(b.frame))]; }];
    return buttons;
}

SN_SNAPSHOT(ComposerFooterHover) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    // composer_footer_*: the footer's left part, from the box's left edge, 77.5 pt below its top.
    NSSize crop = NSMakeSize(257, 41);
    NSDictionary *cases = @{@"composer_footer_default" : @(-1), @"composer_footer_plus_hover" : @0, @"composer_footer_emoji_hover" : @2};
    for (NSString *reference in cases) {
        SNComposer *composer = Composer(source, crop, NSMakeRect(-20, -77.5, 986, 160));
        [composer showConversation:ChannelID(source) threadTS:nil];
        Resize(composer, -77.5, crop);
        NSInteger hovered = [cases[reference] integerValue];
        if (hovered >= 0) FooterButtons(composer)[(NSUInteger)hovered].hovered = YES;
        SNSettle(0.2);
        // The tooltip has its own snapshot (CommonOverlays); here it would cover the footer.
        [SNTooltip hide];
        SNCompareWithReference([reference stringByReplacingOccurrencesOfString:@"composer_footer" withString:@"composer_hover"], SNRenderView(composer.superview, crop),
                               reference, NSZeroPoint, 1, @[
                                   [SNRegion region:@"plus" rect:NSMakeRect(6, 6, 29, 29) budget:2],
                                   [SNRegion region:@"Aa, emoji, mention" rect:NSMakeRect(36, 6, 96, 29) budget:8],
                                   [SNRegion region:@"clips and shortcuts" rect:NSMakeRect(132, 6, 120, 29) budget:2],
                               ]);
    }
}

SN_SNAPSHOT(ComposerAutocomplete) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    NSSize size = NSMakeSize(900, 520);
    SNComposer *composer = Composer(source, size, NSMakeRect(0, 360, 900, 100));
    [composer showConversation:ChannelID(source) threadTS:nil];
    Resize(composer, 360, size);
    [composer focus];
    SNComposerTextView *text = ComposerText(composer);
    [text insertText:@"oi @" replacementRange:text.selectedRange];
    SNSaveSnapshot(@"composer_autocomplete_people", SNRenderWindow(composer.window));
    [text moveDown:nil];
    [text insertNewline:nil];
    SNExpect([text.string hasPrefix:@"oi @"] && [text.string hasSuffix:@" "] && text.string.length > 5, "Return picks the highlighted person");
    SNExpect([SNRichMessageFromDocument(text.document).text containsString:@"<@"], "and sends it as a mention");
    [text insertText:@":tad" replacementRange:text.selectedRange];
    SNSaveSnapshot(@"composer_autocomplete_emoji", SNRenderWindow(composer.window));
    [text insertTab:nil];
    SNExpect([SNRichMessageFromDocument(text.document).text containsString:@":tada:"], "Tab picks the first emoji");
    [text insertText:@"#" replacementRange:text.selectedRange];
    SNSaveSnapshot(@"composer_autocomplete_channels", SNRenderWindow(composer.window));
    [text cancelOperation:nil];
}

SN_TEST(ComposerSendsDraftsAndEdits) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    NSString *channel = ChannelID(source);
    SNComposer *composer = Composer(source, NSMakeSize(800, 400), NSMakeRect(0, 200, 800, 160));
    [composer showConversation:channel threadTS:nil];
    __block BOOL editAsked = NO;
    composer.editLastMessage = ^(SNComposer *sender) { editAsked = YES; };
    [composer focus];
    SNComposerTextView *text = ComposerText(composer);
    [text moveUp:nil];
    SNExpect(editAsked, "Up in an empty composer asks to edit the last message");

    [text insertText:@"draft *kept*" replacementRange:text.selectedRange];
    [composer showConversation:source.directMessages.firstObject.conversationID threadTS:nil];
    SNExpect(composer.text.length == 0, "another conversation starts empty");
    NSString *draft = [source draftInConversation:channel threadTS:nil];
    NSArray *blocks = [NSJSONSerialization JSONObjectWithData:[draft dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    SNExpect([blocks isKindOfClass:NSArray.class] && [[blocks.firstObject valueForKey:@"type"] isEqual:@"rich_text"], "the draft is saved as its rich_text");
    [composer showConversation:channel threadTS:nil];
    SNExpect([composer.text isEqualToString:@"draft kept"] && [SNRichMessageFromDocument(text.document).text isEqualToString:@"draft *kept*"],
             "and comes back formatted");

    NSUInteger before = [source messagesInConversation:channel].count;
    [text insertNewline:nil];
    NSArray<SNMessage *> *messages = [source messagesInConversation:channel];
    SNExpect(messages.count == before + 1 && [messages.lastObject.text isEqualToString:@"draft *kept*"] && messages.lastObject.blocks.count == 1,
             "Return sends the text with its rich_text block");
    SNExpect(composer.text.length == 0 && [source draftInConversation:channel threadTS:nil].length == 0, "sending clears the composer and the draft");
}

SN_TEST(ComposerNarrowThreadLayoutHasNoOverflowOrCollision) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    NSString *channel = ChannelID(source);
    for (NSNumber *widthValue in @[ @393, @300 ]) {
        CGFloat width = widthValue.doubleValue;
        SNComposer *composer = Composer(source, NSMakeSize(width, 200), NSMakeRect(0, 20, width, 160));
        [composer showConversation:channel threadTS:@"1795192800.000103"];
        [composer layoutSubtreeIfNeeded];
        NSView *box = nil;
        for (NSView *sub in composer.subviews)
            if ([sub isKindOfClass:NSClassFromString(@"SNComposerBoxView")]) box = sub;
        SNExpect(box != nil, "composer has box view");
        NSView *send = nil;
        for (NSView *sub in box.subviews)
            if ([sub isKindOfClass:NSClassFromString(@"SNComposerSendPart")] && !send) send = sub;
        SNExpect(send != nil, "composer has send button");
        for (NSView *sub in box.subviews) {
            if (sub.hidden || ![sub isKindOfClass:SNButton.class]) continue;
            SNExpect(NSMaxX(sub.frame) <= NSWidth(box.bounds) - 2, "visible composer button stays inside box bounds at narrow widths");
            if (NSMinY(sub.frame) > 50)
                SNExpect(NSMaxX(sub.frame) <= NSMinX(send.frame) - 4, "visible footer button does not collide with Send at narrow widths");
        }
    }
}
