// What the composer must never do to the user's account: turn text into mentions, post a slash
// command as a message, tell Slack the user is typing when they are not; and its keystrokes
// staying cheap in a long text.
#import "app/launch.h"
#import "render/emoji.h"
#import "store/store.h"
#import "test.h"
#import "ui/composer/composer.h"
#import "ui/composer/richtext.h"
#import "ui/composer/textview.h"
#import "ui/kit/overlay.h"

static void Append(NSMutableAttributedString *document, NSString *text, NSDictionary *attributes) {
    [document appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
}

/// The semantic attributes at every character agree.
static BOOL SameDocument(NSAttributedString *a, NSAttributedString *b) {
    if (![a.string isEqualToString:b.string]) return NO;
    for (NSUInteger i = 0; i < a.length; i++) {
        NSDictionary *x = [a attributesAtIndex:i effectiveRange:NULL], *y = [b attributesAtIndex:i effectiveRange:NULL];
        SNRichEntity *e = x[SNRichEntityAttribute], *f = y[SNRichEntityAttribute];
        BOOL entity = (!e && !f) || (e && f && e.kind == f.kind && [e.value isEqual:f.value] && (e.unicode == f.unicode || [e.unicode isEqual:f.unicode]));
        BOOL block = x[SNRichBlockAttribute] == y[SNRichBlockAttribute] || [x[SNRichBlockAttribute] isEqual:y[SNRichBlockAttribute]];
        BOOL link = x[SNRichLinkAttribute] == y[SNRichLinkAttribute] || [x[SNRichLinkAttribute] isEqual:y[SNRichLinkAttribute]];
        if (!entity || !block || !link || [x[SNRichStyleAttribute] unsignedIntegerValue] != [y[SNRichStyleAttribute] unsignedIntegerValue]) {
            printf("    differs at %lu\n", (unsigned long)i);
            return NO;
        }
    }
    return YES;
}

static BOOL HasEntity(NSAttributedString *document, SNRichEntityKind kind, NSString *value) {
    __block BOOL found = NO;
    [document enumerateAttribute:SNRichEntityAttribute inRange:NSMakeRange(0, document.length) options:0 usingBlock:^(SNRichEntity *entity, NSRange range, BOOL *stop) {
        if (entity.kind == kind && [entity.value isEqualToString:value]) found = *stop = YES;
    }];
    return found;
}

SN_TEST(ComposerDraftsComeBackExactly) {
    SNRichBlock *bullet = [SNRichBlock blockWithKind:SNRichBlockBullet indent:0], *code = [SNRichBlock blockWithKind:SNRichBlockCode indent:0];
    SNRichBlock *quote = [SNRichBlock blockWithKind:SNRichBlockQuote indent:0];
    NSMutableAttributedString *document = [NSMutableAttributedString new];
    Append(document, @"  lead ", @{});
    Append(document, @"<!channel>", @{SNRichStyleAttribute : @(SNInlineCode)});
    Append(document, @" and ", @{});
    Append(document, @"@Robin", @{SNRichEntityAttribute : [SNRichEntity entityWithKind:SNRichEntityUser value:@"U1"]});
    Append(document, @" ", @{});
    Append(document, @"under", @{SNRichStyleAttribute : @(SNInlineUnderline | SNInlineBold)});
    Append(document, @" &lt;3 www.example.com\n", @{});
    Append(document, @"one\n\nthree\n", @{SNRichBlockAttribute : bullet});
    Append(document, @"<!here> <@U2>\n", @{SNRichBlockAttribute : code});
    Append(document, @"\n", @{});
    Append(document, @"q ", @{SNRichBlockAttribute : quote});
    Append(document, SNRichCustomEmojiText, @{SNRichBlockAttribute : quote, SNRichEntityAttribute : [SNRichEntity emojiWithName:@"partyparrot" unicode:nil]});
    Append(document, @"\n", @{SNRichBlockAttribute : quote});

    NSString *draft = SNRichDraftFromDocument(document);
    NSMutableAttributedString *restored = SNRichDocumentFromDraft(draft, ^NSString *(SNRichEntityKind kind, NSString *value) {
        return kind == SNRichEntityUser ? @"Robin" : nil;
    });
    SNExpect(SameDocument(document, restored), "a draft comes back character for character: spaces, blank lines, an empty item, underline, a custom emoji");
    SNExpect(!HasEntity(restored, SNRichEntityBroadcast, @"channel") && !HasEntity(restored, SNRichEntityBroadcast, @"here") &&
                 !HasEntity(restored, SNRichEntityUser, @"U2"),
             "text in code never comes back as a mention");
    SNExpect(HasEntity(restored, SNRichEntityUser, @"U1"), "the real mention stays one");

    NSString *fallback = SNRichMessageFromDocument(document).text;
    SNExpect([fallback containsString:@"`&lt;!channel&gt;`"] && [fallback containsString:@"```&lt;!here&gt; &lt;@U2&gt;```"], "code is escaped in the fallback text");
    SNExpect(![fallback containsString:@"<!channel>"] && ![fallback containsString:@"<!here>"] && ![fallback containsString:@"<@U2>"], "so it mentions no one");
    SNExpect([fallback containsString:@"<@U1>"] && [fallback containsString:@"&amp;lt;3"], "the real mention is a mention and typed escapes stay text");

    SNExpect(SNRichDraftFromDocument([[NSAttributedString alloc] initWithString:@"  \n "]) == nil, "a blank document leaves no draft");
    SNExpect([SNRichDocumentFromDraft(@"plain words", nil).string isEqualToString:@"plain words"], "a draft that is not rich_text is shown as text");
}

SN_TEST(ComposerKnowsSlashCommands) {
    NSAttributedString * (^text)(NSString *, NSDictionary *) = ^(NSString *string, NSDictionary *attributes) {
        return [[NSAttributedString alloc] initWithString:string attributes:attributes];
    };
    SNExpect(SNRichStartsWithCommand(text(@"/msg @kim the password", @{})) && SNRichStartsWithCommand(text(@"/remind me", @{})), "a leading / is a command");
    SNExpect(!SNRichStartsWithCommand(text(@" /msg @kim", @{})) && !SNRichStartsWithCommand(text(@"a/b", @{})), "a space before it makes it text");
    SNExpect(!SNRichStartsWithCommand(text(@"/usr/bin", @{SNRichStyleAttribute : @(SNInlineCode)})) &&
                 !SNRichStartsWithCommand(text(@"/usr/bin", @{SNRichBlockAttribute : [SNRichBlock blockWithKind:SNRichBlockCode indent:0]})),
             "so does code");
}

/// A composer in an offscreen window on a fixture's first channel.
static SNComposer *ComposerOn(SNFixtureSource *source, NSString **channel) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 500) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    SNComposer *composer = [[SNComposer alloc] initWithSource:source];
    composer.frame = NSMakeRect(0, 0, 800, 200);
    [window.contentView addSubview:composer];
    *channel = source.sections.firstObject.conversationIDs.firstObject;
    [composer showConversation:*channel threadTS:nil];
    return composer;
}

static SNComposerTextView *TextOf(NSView *view) {
    if ([view isKindOfClass:SNComposerTextView.class]) return (SNComposerTextView *)view;
    for (NSView *subview in view.subviews) {
        SNComposerTextView *found = TextOf(subview);
        if (found) return found;
    }
    return nil;
}

SN_TEST(ComposerRunsSlashCommandsInsteadOfPostingThem) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    SNComposer *composer = ComposerOn(source, &channel);
    [composer focus];
    SNComposerTextView *text = TextOf(composer);
    NSUInteger before = [source messagesInConversation:channel].count;
    [text insertText:@"/msg @kim the password" replacementRange:text.selectedRange];
    [text insertNewline:nil];
    NSArray *sent = source.calls.lastObject;
    SNMessage *last = [source messagesInConversation:channel].lastObject;
    SNExpect(last.isEphemeral && [last.userID isEqualToString:@"USLACKBOT"] && composer.text.length == 0,
             "Return runs a slash command: nothing is posted, the answer shows to the user only");
    SNExpect(![sent[0] isEqualToString:@"chat.postMessage"], "least of all as chat.postMessage");
    [text insertText:@"/remind me to stretch in 5 minutes" replacementRange:text.selectedRange];
    [text insertNewline:nil];
    sent = source.calls.lastObject;
    SNExpect([sent[0] isEqualToString:@"chat.command"] && [sent[1][@"command"] isEqualToString:@"/remind"] && [sent[1][@"channel"] isEqualToString:channel],
             "a server command goes to chat.command");
    [text insertText:@" /msg as text" replacementRange:text.selectedRange];
    [text insertNewline:nil];
    SNExpect([source messagesInConversation:channel].count == before + 1 && [[source messagesInConversation:channel].lastObject.text hasPrefix:@"/msg"],
             "with a space before it, it is sent as text");
}

SN_TEST(ComposerRestoresDraftsWithoutTyping) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    __block NSUInteger typing = 0;
    source.frameSender = ^(NSDictionary *frame) {
        if ([frame[@"type"] isEqual:@"typing"]) typing++;
    };
    NSString *channel;
    SNComposer *composer = ComposerOn(source, &channel);
    [composer focus];
    SNComposerTextView *text = TextOf(composer);
    [text insertText:@"half a thought" replacementRange:text.selectedRange];
    SNExpect(typing == 1, "typing tells Slack");
    NSString *other = source.directMessages.firstObject.conversationID;
    [source setDraft:SNRichDraftFromDocument([[NSAttributedString alloc] initWithString:@"waiting"]) inConversation:other threadTS:nil];
    [composer showConversation:other threadTS:nil];
    [composer focus];
    [composer showConversation:channel threadTS:nil];
    SNExpect(typing == 1 && [composer.text isEqualToString:@"half a thought"], "putting drafts back into a focused composer does not");
}

SN_TEST(ComposerAutocompleteFollowsTheCaret) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    SNComposer *composer = ComposerOn(source, &channel);
    [composer focus];
    SNComposerTextView *text = TextOf(composer);
    SNOverlayHost *host = [SNOverlayHost hostForWindow:composer.window];
    [text insertText:@"hi @" replacementRange:text.selectedRange];
    SNExpect(host.subviews.count == 1, "@ opens the list");
    text.selectedRange = NSMakeRange(0, 0);
    SNExpect(host.subviews.count == 0, "moving the caret away closes it");
}

SN_TEST(ComposerKeystrokesStayCheap) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    SNComposer *composer = ComposerOn(source, &channel);
    NSMutableString *markdown = [NSMutableString new];
    for (int i = 0; i < 500; i++) [markdown appendFormat:@"%@line %d with *bold* and `code` see https://example.com/%d\n", i % 7 ? @"" : @"- ", i, i];
    composer.text = markdown;
    [composer focus];
    SNComposerTextView *text = TextOf(composer);
    text.selectedRange = NSMakeRange([text.string rangeOfString:@"line 250 "].location, 0);
    NSMutableArray<NSNumber *> *times = [NSMutableArray new];
    for (int i = 0; i < 41; i++) {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        [text insertText:@"x" replacementRange:text.selectedRange];
        [composer layoutSubtreeIfNeeded];
        [times addObject:@((CFAbsoluteTimeGetCurrent() - start) * 1000)];
    }
    [times sortUsingSelector:@selector(compare:)];
    printf("    keystroke at 500 lines: median %.2f ms, slowest %.2f ms\n", times[20].doubleValue, times.lastObject.doubleValue);
    SNExpect(times[20].doubleValue < 1, "a keystroke in 500 lines takes under 1 ms");
}

SN_TEST(ComposerShowsCustomEmojiAsPictures) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSetCustomEmoji(@{@"partyparrot" : @"https://emoji.example/chart.png"});
    NSString *channel;
    SNComposer *composer = ComposerOn(source, &channel);
    [composer focus];
    SNComposerTextView *text = TextOf(composer);
    for (NSUInteger i = 0; i < @"ok :partyparrot:".length; i++) [text insertText:[@"ok :partyparrot:" substringWithRange:NSMakeRange(i, 1)] replacementRange:text.selectedRange];
    SNExpect([text.string isEqualToString:[@"ok " stringByAppendingString:SNRichCustomEmojiText]] &&
                 [text.textStorage attribute:NSAttachmentAttributeName atIndex:3 effectiveRange:NULL] != nil,
             "a custom :name: becomes one character drawn as its picture");
    NSArray *elements = [SNRichMessageFromDocument(text.document).blocks.firstObject[@"elements"] firstObject][@"elements"];
    SNExpect([[elements.lastObject valueForKey:@"name"] isEqual:@"partyparrot"], "and is sent as the emoji");
    // Drawn before and after the picture arrives.
    NSBitmapImageRep *bitmap = [text bitmapImageRepForCachingDisplayInRect:text.bounds];
    [text cacheDisplayInRect:text.bounds toBitmapImageRep:bitmap];
    SNSettle(0.2);
    [text cacheDisplayInRect:text.bounds toBitmapImageRep:bitmap];
    NSRect glyph = [text.layoutManager boundingRectForGlyphRange:NSMakeRange(3, 1) inTextContainer:text.textContainer];
    NSColor *middle = [bitmap colorAtX:(NSInteger)(NSMidX(glyph) * bitmap.pixelsWide / NSWidth(text.bounds))
                                     y:(NSInteger)((NSMidY(glyph) + text.textContainerOrigin.y) * bitmap.pixelsHigh / NSHeight(text.bounds))];
    SNExpect(middle.alphaComponent > 0.5, "its picture fills its place in the line");
    SNSetCustomEmoji(@{});
}
