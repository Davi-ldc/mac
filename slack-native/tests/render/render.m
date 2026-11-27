// Rendering: emoji data, every rich_text, mrkdwn, Block Kit and attachment element of the public
// fixture's design channel, the layout's geometry and hit testing, and the date wording.
#import "app/launch.h"
#import "model/json.h"
#import "render/emoji.h"
#import "render/format.h"
#import "render/message.h"
#import "render/strings.h"
#import "test.h"

static SNFixtureSource *Source(void) { return SNOpenFixture(SNPublicFixture()); }

/// The design channel's messages by their fallback text.
static SNMessage *Message(SNFixtureSource *source, NSString *text) {
    for (SNMessage *message in [source messagesInConversation:@"C03DESIGN"])
        if ([message.text hasPrefix:text]) return message;
    return nil;
}

static NSAttributedString *FirstText(NSArray<SNRenderBlock *> *blocks) {
    for (SNRenderBlock *block in blocks)
        if ([block isKindOfClass:SNParagraphBlock.class]) return ((SNParagraphBlock *)block).text;
    return nil;
}

static id AttributeAt(NSAttributedString *text, NSString *substring, NSString *key) {
    NSRange range = [text.string rangeOfString:substring];
    return range.location == NSNotFound ? nil : [text attribute:key atIndex:range.location effectiveRange:NULL];
}

static NSString *FontNameAt(NSAttributedString *text, NSString *substring) {
    return [AttributeAt(text, substring, NSFontAttributeName) fontName] ?: @"";
}

static SNRenderTarget *TargetAt(NSAttributedString *text, NSString *substring) { return AttributeAt(text, substring, @"SNTarget"); }

SN_TEST(RenderEmojiData) {
    SNExpect([SNEmojiUnicode(@"+1") isEqualToString:@"👍"], "+1 is the thumbs up");
    SNExpect([SNEmojiUnicode(@"thumbsup") isEqualToString:@"👍"], "aliases resolve");
    SNExpect([SNEmojiUnicode(@"+1::skin-tone-3") isEqualToString:@"👍🏼"], "skin tone 3 is the medium-light modifier");
    SNExpect([SNEmojiUnicode(@"thumbsup::skin-tone-6") isEqualToString:@"👍🏿"], "skin tone 6 on an alias");
    SNExpect([SNEmojiUnicode(@"wave::skin-tone-2") isEqualToString:@"👋🏻"], "skin tone 2 is the lightest");
    SNExpect([SNEmojiUnicode(@"smile::skin-tone-4") isEqualToString:@"😄"], "a tone on an emoji without tones is ignored");
    SNExpect(SNEmojiUnicode(@"no_such_emoji") == nil, "unknown names have no text");
    SNExpect(SNEmojiSkinTone(@"x::skin-tone-5") == 5 && [SNEmojiBaseName(@"x::skin-tone-5") isEqualToString:@"x"], "tone suffix parsed");
    SNEmoji *grinning = SNEmojiNamed(@"grinning");
    SNExpect(grinning.category == SNEmojiCategorySmileys && [SNEmojiInCategory(SNEmojiCategorySmileys).firstObject isEqual:grinning],
             "picker order starts the smileys with grinning");
    SNExpect(SNEmojiNamed(@"+1").hasSkinTones && [SNEmojiNamed(@"thumbsup") isEqual:SNEmojiNamed(@"+1")], "one shared object per emoji");
    SNExpect(SNEmojiInCategory(SNEmojiCategoryFlags).count > 200, "flags are listed");
    NSArray<SNEmoji *> *matches = SNEmojiMatching(@"thumb", 10);
    SNExpect(matches.count && [matches.firstObject.names containsObject:@"thumbsup"], "search finds by any name, prefixes first");

    NSString *url = @"https://emoji.example.com/partyparrot.gif";
    SNSetCustomEmoji(@{@"partyparrot" : url, @"parrot" : @"alias:partyparrot", @"yay" : @"alias:tada", @"loop" : @"alias:loop"});
    SNExpect([SNCustomEmojiURL(@"parrot").absoluteString isEqualToString:url], "custom alias chains resolve to the picture");
    SNExpect([SNEmojiUnicode(@"yay") isEqualToString:@"🎉"], "a custom alias of a standard emoji is that emoji");
    SNExpect(SNCustomEmojiURL(@"loop") == nil && SNCustomEmojiURL(@"tada") == nil, "loops and standard names have no picture");
    SNExpect(SNCustomEmojiNames().count == 4, "custom names listed");
    SNSetCustomEmoji(@{});
}

SN_TEST(RenderRichTextInlineStyles) {
    SNFixtureSource *source = Source();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    NSAttributedString *text = FirstText([renderer documentForMessage:Message(source, @"styles")].blocks);
    SNExpect([FontNameAt(text, @"bold") containsString:@"Bold"], "bold is Lato Bold");
    SNExpect([FontNameAt(text, @"italic") containsString:@"Italic"], "italic is Lato Italic");
    SNExpect([AttributeAt(text, @"struck", @"SNLine") unsignedIntegerValue] == 2, "strike is drawn through");
    SNExpect([AttributeAt(text, @"underlined", @"SNLine") unsignedIntegerValue] == 1, "underline is drawn under");
    SNExpect([FontNameAt(text, @"code") containsString:@"Mono"] && AttributeAt(text, @"code", @"SNChip"), "code is Roboto Mono on a chip");
    NSFont *all = AttributeAt(text, @"all", NSFontAttributeName);
    SNExpect([all.fontName containsString:@"BoldItalic"] && [AttributeAt(text, @"all", @"SNLine") unsignedIntegerValue] == 2, "styles combine");
}

SN_TEST(RenderRichTextInlineElements) {
    SNFixtureSource *source = Source();
    SNSetCustomEmoji(@{@"partyparrot" : @"https://emoji.example.com/partyparrot.gif"});
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    NSAttributedString *text = FirstText([renderer documentForMessage:Message(source, @"inline")].blocks);
    NSString *priya = [@"@" stringByAppendingString:[source userWithID:@"U03PRIYA"].visibleName];
    NSString *me = [@"@" stringByAppendingString:source.me.visibleName];
    SNExpect(TargetAt(text, priya).kind == SNRenderTargetUser && [TargetAt(text, priya).value isEqualToString:@"U03PRIYA"], "user mention by name");
    SNExpect([[AttributeAt(text, priya, @"SNChip") valueForKey:@"fill"] unsignedIntValue] == SNColorSurfHgl1, "others' mentions are blue chips");
    SNExpect([[AttributeAt(text, me, @"SNChip") valueForKey:@"fill"] unsignedIntValue] == SNColorSurfHgl3, "the user's own mention is yellow");
    SNExpect(TargetAt(text, @"#general").kind == SNRenderTargetChannel, "channel mention");
    SNExpect(TargetAt(text, @"@design-team").kind == SNRenderTargetUsergroup && [TargetAt(text, @"@design-team").value isEqualToString:@"S01DESIGNERS"],
             "usergroup mention by its handle");
    SNExpect(TargetAt(text, @"@here").kind == SNRenderTargetBroadcast && [FontNameAt(text, @"@here") containsString:@"Bold"], "@here is bold");
    SNExpect([TargetAt(text, @"the docs").value isEqualToString:@"https://example.com/docs"], "link with text");
    SNExpect(TargetAt(text, @"https://example.com/raw").kind == SNRenderTargetLink, "bare link shows its URL");
    SNExpect([text.string containsString:@"#1d9bd1"], "colour element shows its value");
    SNExpect([text.string containsString:@"👋"] && [text.string containsString:@"👍🏽"], "emoji, with the element's skin tone");
    SNExpect([FontNameAt(text, @"👋") containsString:@"Emoji"], "emoji use Apple Color Emoji");
    SNExpect([text.string containsString:@":not_an_emoji_name:"], "unknown emoji stay as text");
    NSRange parrot = [text.string rangeOfString:@"￼" options:NSBackwardsSearch];
    SNExpect(parrot.location != NSNotFound && [text attribute:@"SNImage" atIndex:parrot.location effectiveRange:NULL], "custom emoji are pictures");
    SNExpect(![text.string containsString:@"{date"], "date tokens are replaced");
    SNSetCustomEmoji(@{});
}

SN_TEST(RenderRichTextBlocks) {
    SNFixtureSource *source = Source();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    NSArray<SNRenderBlock *> *blocks = [renderer documentForMessage:Message(source, @"lists")].blocks;
    NSMutableArray<NSString *> *markers = [NSMutableArray new];
    NSMutableArray<NSNumber *> *indents = [NSMutableArray new];
    for (SNRenderBlock *block in blocks)
        if ([block isKindOfClass:SNParagraphBlock.class] && ((SNParagraphBlock *)block).marker) {
            [markers addObject:((SNParagraphBlock *)block).marker];
            [indents addObject:@(((SNParagraphBlock *)block).indent)];
        }
    SNExpect(([markers isEqualToArray:@[ @"•", @"•", @"◦", @"1.", @"2.", @"a." ]]), "bullets and numbers by level");
    SNExpect(([indents isEqualToArray:@[ @28, @28, @56, @28, @28, @56 ]]), "28 pt per level");
    SNParagraphBlock *after = (SNParagraphBlock *)blocks.lastObject;
    SNExpect([after.text.string isEqualToString:@"After the list."] && after.spaceBefore == 8, "a section after a list opens a paragraph");
    SNExpect([FirstText(blocks).string isEqualToString:@"Plan:"], "trailing newline before a list is dropped");

    NSArray<SNRenderBlock *> *quoted = [renderer documentForMessage:Message(source, @"quote")].blocks;
    SNExpect([quoted[0] isKindOfClass:SNGroupBlock.class] && [quoted[1] isKindOfClass:SNCodeBlock.class], "quote then preformatted");
    SNExpect([FontNameAt(((SNCodeBlock *)quoted[1]).text, @"print") containsString:@"Mono"], "preformatted text is monospaced");
    SNRenderLayout *layout = [[SNRenderDocument documentWithBlocks:@[ quoted[2] ]] layoutForWidth:600];
    SNExpect(layout.size.height == 22 + 8 + 22, "an empty line is an 8 pt break between 22 pt lines");

    SNParagraphBlock *jumbo = (SNParagraphBlock *)[renderer documentForMessage:Message(source, @":tada:")].blocks.firstObject;
    SNExpect(jumbo.style.lineHeight == 36, "emoji-only messages are jumbo");
    NSAttributedString *chip = FirstText([renderer documentForMessage:Message(source, @"<https://example.com/pull/42>")].blocks);
    SNExpect([chip.string containsString:@"example.com/pull/42"] && ![chip.string containsString:@"https://"] && AttributeAt(chip, @"example", @"SNChip"),
             "a link-only message is a chip without the scheme");
}

SN_TEST(RenderMrkdwn) {
    SNFixtureSource *source = Source();
    SNSetLanguage(@"en");
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    NSArray<SNRenderBlock *> *blocks = [renderer documentForMessage:Message(source, @"Fallback")].blocks;
    NSAttributedString *text = FirstText(blocks);
    SNExpect([FontNameAt(text, @"bold") containsString:@"Bold"] && [FontNameAt(text, @"italic") containsString:@"Italic"], "*bold* and _italic_");
    SNExpect([AttributeAt(text, @"strike", @"SNLine") unsignedIntegerValue] == 2 && AttributeAt(text, @"code", @"SNChip"), "~strike~ and `code`");
    SNExpect(TargetAt(text, @"#general").kind == SNRenderTargetChannel && TargetAt(text, @"@channel").kind == SNRenderTargetBroadcast, "channel and broadcast entities");
    SNExpect(TargetAt(text, @"@designers").kind == SNRenderTargetUsergroup, "usergroup entity takes its label");
    SNExpect([text.string containsString:@"2026-11-21"] && ![text.string containsString:@"fallback"], "<!date> formatted");
    SNExpect([TargetAt(text, @"a link").value isEqualToString:@"https://example.com"], "<url|label>");
    SNExpect([text.string containsString:@"<escaped> &"], "entities decoded");
    SNExpect([text.string containsString:@"😄"] && [text.string containsString:@"👍🏻"], ":emoji: with skin tones");
    SNExpect(![text.string containsString:@"*"] && ![text.string containsString:@"`"], "markers removed");
    SNExpect(blocks.count == 4 && [blocks[1] isKindOfClass:SNCodeBlock.class] && [blocks[2] isKindOfClass:SNGroupBlock.class], "fence and quote blocks");
    SNExpect([((SNParagraphBlock *)((SNGroupBlock *)blocks[2]).blocks.firstObject).text.string isEqualToString:@"quoted line\nsecond quoted"], "quote lines joined");

    NSArray *edge = [renderer blocksForMrkdwn:@"snake_case_name 2*3*4 a*b ```unclosed" style:SNTextStyleBody];
    NSString *plain = [SNRenderDocument documentWithBlocks:edge].plainText;
    SNExpect([plain isEqualToString:@"snake_case_name 2*3*4 a*b ```unclosed"], "markers inside words and unclosed fences stay text");
}

SN_TEST(RenderAttachmentsAndBlockKit) {
    SNFixtureSource *source = Source();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    SNMessage *bot = nil;
    for (SNMessage *message in [source messagesInConversation:@"C03DESIGN"])
        if (message.attachments.count && message.botID) bot = message;
    NSArray<SNRenderBlock *> *legacy = [renderer documentForMessage:bot].blocks;
    SNExpect(legacy.count == 3 && [FirstText(legacy).string isEqualToString:@"Deploy finished"], "pretext above the attachment");
    SNGroupBlock *attachment = (SNGroupBlock *)legacy[1];
    SNExpect([attachment isKindOfClass:SNGroupBlock.class] && attachment.sideImage && attachment.maximumWidth == 600, "attachment with thumb, 600 pt");
    NSArray *kinds = [attachment.blocks valueForKey:@"className"];
    SNExpect([kinds containsObject:@"SNColumnsBlock"], "fields in columns");
    NSString *plain = [SNRenderDocument documentWithBlocks:@[ attachment ]].plainText;
    SNExpect([plain containsString:@"CI"] && [plain containsString:@"Release 3.2"] && [plain containsString:@"All 312 checks passed"], "author, title, text");

    NSArray<SNRenderBlock *> *shared = [renderer documentForMessage:Message(source, @"shared")].blocks;
    SNGroupBlock *card = (SNGroupBlock *)shared.lastObject;
    SNExpect(card.maximumWidth == 716 && [[SNRenderDocument documentWithBlocks:card.blocks].plainText containsString:@"ship on Friday"], "shared message card");

    NSArray<SNRenderBlock *> *kit = [renderer documentForMessage:Message(source, @"kit")].blocks;
    NSArray<NSString *> *types = [kit valueForKey:@"className"];
    NSArray *expected = @[ @"SNParagraphBlock", @"SNGroupBlock", @"SNColumnsBlock", @"SNDividerBlock", @"SNParagraphBlock", @"SNParagraphBlock", @"SNImageBlock",
                           @"SNButtonsBlock", @"SNTableBlock" ];
    SNExpect([types isEqualToArray:expected], "header, section with accessory, fields, divider, context, image title, image, actions, table");
    SNExpect(((SNParagraphBlock *)kit[0]).style.weight == SNFontWeightBlack && ((SNParagraphBlock *)kit[0]).style.size == 18, "header in 18 pt black");
    NSArray<SNButtonItem *> *buttons = ((SNButtonsBlock *)kit[7]).items;
    SNExpect(buttons.count == 3 && buttons[0].style == SNButtonStylePrimary && buttons[1].style == SNButtonStyleDanger &&
                 [buttons[2].target.value isEqualToString:@"https://example.com/open"],
             "buttons keep styles and URLs");
    SNExpect(((SNTableBlock *)kit[8]).rows.count == 2, "table rows");
    NSAttributedString *context = ((SNParagraphBlock *)kit[4]).text;
    SNExpect([context.string hasPrefix:@"￼"] && [context attribute:@"SNImage" atIndex:0 effectiveRange:NULL], "context picture inline");
    SNRenderLayout *layout = [[SNRenderDocument documentWithBlocks:kit] layoutForWidth:700];
    NSRect approve = [layout rectForTarget:buttons[0].target];
    SNExpect(approve.size.height == 28 && [[layout targetAtPoint:NSMakePoint(NSMidX(approve), NSMidY(approve))] isEqual:buttons[0].target], "buttons are 28 pt and clickable");
}

SN_TEST(RenderMessageKinds) {
    SNFixtureSource *source = Source();
    SNSetLanguage(@"en");
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    SNExpect([[renderer documentForMessage:Message(source, @"<@U07CASEY>")].plainText isEqualToString:@"joined the channel."], "join message wording");
    NSAttributedString *me = FirstText([renderer documentForMessage:Message(source, @"waves")].blocks);
    SNExpect([FontNameAt(me, @"waves") containsString:@"Italic"], "/me messages are italic");
    NSString *broadcast = [renderer documentForMessage:Message(source, @"also sent")].plainText;
    SNExpect([broadcast hasPrefix:@"replied to a thread: Reactions here"], "broadcast names its thread");
    NSString *edited = [renderer documentForMessage:Message(source, @"reacted")].plainText;
    SNExpect([edited isEqualToString:@"Reactions here (edited)"], "edited label after the text");
    SNExpect([[renderer documentForMessage:Message(source, @"files")].plainText isEqualToString:@"Two files"], "files are not part of the body");
}

SN_TEST(RenderLayoutGeometry) {
    SNFixtureSource *source = Source();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    SNRenderDocument *document = [renderer documentForMessage:Message(source, @"inline")];
    SNRenderLayout *wide = [document layoutForWidth:2000], *narrow = [document layoutForWidth:200];
    SNExpect(wide.lineCount == 1 && wide.size.height == 22, "one 22 pt line when wide");
    SNExpect(narrow.lineCount > 3 && narrow.size.height == narrow.lineCount * 22, "wraps into 22 pt lines");
    SNRenderTarget *docs = [SNRenderTarget targetWithKind:SNRenderTargetLink value:@"https://example.com/docs"];
    NSRect rect = [wide rectForTarget:docs];
    SNExpect(!NSIsEmptyRect(rect) && [[wide targetAtPoint:NSMakePoint(NSMidX(rect), NSMidY(rect))] isEqual:docs], "hit testing finds the link");
    SNExpect([wide targetAtPoint:NSMakePoint(1, 11)] == nil, "plain text has no target");
    NSRect chip = [wide rectForTarget:[SNRenderTarget targetWithKind:SNRenderTargetUser value:@"U03PRIYA"]];
    NSString *name = [@"@" stringByAppendingString:[source userWithID:@"U03PRIYA"].visibleName];
    NSFont *font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    CGFloat text = [[NSAttributedString alloc] initWithString:name attributes:@{NSFontAttributeName : font}].size.width;
    SNExpect(fabs(chip.size.width - (text + 4)) < 1, "mention chips are padded 2 pt each side");
}

SN_TEST(RenderDateWording) {
    NSString *language = SNLanguage();
    NSDateComponents *components = [NSDateComponents new];
    components.year = 2026, components.month = 11, components.day = 20, components.hour = 11, components.minute = 44, components.second = 29;
    NSDate *date = [NSCalendar.currentCalendar dateFromComponents:components];
    NSDate *now = [date dateByAddingTimeInterval:3 * 86400];
    SNSetLanguage(@"pt-BR");
    SNExpect([SNFormatTime(date) isEqualToString:@"11h44"], "pt-BR time is 11h44");
    SNExpect([SNFormatTimeTooltip(date) isEqualToString:@"20 nov à(s) 11h44min29s"], "pt-BR timestamp tooltip");
    SNExpect([SNFormatDay(date, now) isEqualToString:@"Sexta-feira, 20 de novembro"], "pt-BR day divider");
    SNExpect([SNFormatDay(date, [date dateByAddingTimeInterval:3600]) isEqualToString:@"Hoje"] &&
                 [SNFormatDay(date, [date dateByAddingTimeInterval:86400]) isEqualToString:@"Ontem"],
             "today and yesterday");
    SNExpect([SNFormatAgo([now dateByAddingTimeInterval:-2 * 86400], now) isEqualToString:@"há 2 dias"], "pt-BR relative days");
    SNExpect([SNFormatReplyCount(17) isEqualToString:@"17 respostas"] && [SNFormatReplyCount(1) isEqualToString:@"1 resposta"], "reply counts");
    SNExpect([SNFormatDayAndTime(date, now) isEqualToString:@"Sexta-feira à(s) 11h44"], "a thread's parent within the week");
    SNExpect([SNFormatDayAndTime(date, [date dateByAddingTimeInterval:3600]) isEqualToString:@"Hoje à(s) 11h44"] &&
                 [SNFormatDayAndTime(date, [date dateByAddingTimeInterval:86400]) isEqualToString:@"Ontem à(s) 11h44"],
             "today and yesterday at");
    SNExpect([SNFormatDayAndTime(date, [date dateByAddingTimeInterval:8 * 86400]) isEqualToString:@"20 de novembro à(s) 11h44"] &&
                 [SNFormatDayAndTime(date, [date dateByAddingTimeInterval:60 * 86400]) isEqualToString:@"20 de novembro de 2026 à(s) 11h44"],
             "older: the date, with the year when it is another");
    SNSetLanguage(@"en");
    SNExpect([SNFormatDayAndTime(date, now) isEqualToString:@"Friday at 11:44 AM"] &&
                 [SNFormatDayAndTime(date, [date dateByAddingTimeInterval:8 * 86400]) isEqualToString:@"November 20th at 11:44 AM"],
             "English parent dates");
    SNExpect([SNFormatTime(date) isEqualToString:@"11:44 AM"], "English time");
    SNExpect([SNFormatDay(date, now) isEqualToString:@"Friday, November 20th"], "English day with ordinal");
    SNExpect([SNFormatSlackDate(date.timeIntervalSince1970, @"{date_num} {date_short_pretty}", now) isEqualToString:@"2026-11-20 Nov 20, 2026"], "date tokens");
    SNSetLanguage(language);
}

SN_TEST(RenderNamesGoStaleOnlyWhenRenamed) {
    SNFixtureSource *source = Source();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    SNMessage *mention = [SNMessage messageWithJSON:@{@"ts" : @"1795000000.000001", @"user" : @"U01ALEX", @"text" : @"hi <@U02SAM> and <@U99LATER> :later_emoji:"}
                                     conversationID:@"C03DESIGN"];
    SNExpect([[renderer documentForMessage:mention].plainText containsString:@"@U99LATER"], "a user not known yet shows by ID");
    SNExpect(![renderer isStaleAfterChange:SNChangeOf(SNChangeUsers, @"U02SAM")], "a presence change of someone shown is not a rename");
    SNExpect(![renderer isStaleAfterChange:SNChangeOf(SNChangeEmoji, nil)], "nor is a frequent emoji change");
    [source performChanges:^{ [source applyUsers:@[ @{@"id" : @"U99LATER", @"name" : @"later"} ]]; }];
    SNExpect([renderer isStaleAfterChange:SNChangeOf(SNChangeUsers, @"U99LATER")], "the user arriving makes it stale");
    SNExpect(![renderer isStaleAfterChange:SNChangeOf(SNChangeUsers, @"U99LATER")], "once: what is remembered starts over");
    [renderer documentForMessage:mention];
    SNSetCustomEmoji(@{@"later_emoji" : @"https://emoji.example/later.png"});
    SNExpect([renderer isStaleAfterChange:SNChangeOf(SNChangeEmoji, nil)], "a custom emoji it showed as text arriving makes it stale");
    SNOpenFixture(SNPublicFixture());
}

SN_TEST(RenderSurvivesNegativeListIndent) {
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:Source()];
    NSDictionary *block = @{@"type" : @"rich_text", @"elements" : @[ @{@"type" : @"rich_text_list", @"style" : @"bullet", @"indent" : @(-2), @"elements" : @[
        @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : @"item"} ]}
    ]} ]};
    SNParagraphBlock *item = (SNParagraphBlock *)[renderer blocksForRichText:block].firstObject;
    SNExpect([item.marker isEqualToString:@"•"] && item.indent == 28, "a negative indent is the first level");
}

SN_TEST(RenderDrawsEmojiInABox) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:64 pixelsHigh:64 bitsPerSample:8 samplesPerPixel:4
                                                                         hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    BOOL standard = SNDrawEmoji(@"thumbsup::skin-tone-3", 32, NSMakeRect(0, 0, 64, 64), nil);
    BOOL unknown = SNDrawEmoji(@"no_such_emoji_name", 32, NSMakeRect(0, 0, 64, 64), nil);
    [NSGraphicsContext restoreGraphicsState];
    NSInteger painted = 0, minX = 64, maxX = 0, minY = 64, maxY = 0;
    for (NSInteger y = 0; y < 64; y++)
        for (NSInteger x = 0; x < 64; x++)
            if ([bitmap colorAtX:x y:y].alphaComponent > 0.5) painted++, minX = MIN(minX, x), maxX = MAX(maxX, x), minY = MIN(minY, y), maxY = MAX(maxY, y);
    SNExpect(standard && !unknown, "standard names draw, unknown ones are left to the caller");
    SNExpect(painted > 200 && maxX - minX <= 33 && fabs((minX + maxX) / 2.0 - 31.5) < 3 && fabs((minY + maxY) / 2.0 - 31.5) < 3,
             "the glyph fills its 32 pt box, centred");
}
