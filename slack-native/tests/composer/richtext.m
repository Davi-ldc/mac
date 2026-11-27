// Typing markdown into the composer's document, reading Slack's mrkdwn and rich_text back into
// one, and the message it sends (rich_text + mrkdwn).
#import "test.h"
#import "ui/composer/richtext.h"
#import "ui/composer/textview.h"

/// Keys typed into a composer: "\n" is Shift+Return, "\t" Tab.
static SNRichMessage *Typed(NSString *keys) {
    SNComposerTextView *text = [[SNComposerTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
    for (NSUInteger i = 0; i < keys.length;) {
        NSRange character = [keys rangeOfComposedCharacterSequenceAtIndex:i];
        NSString *key = [keys substringWithRange:character];
        if ([key isEqualToString:@"\n"]) [text insertLineBreak];
        else if ([key isEqualToString:@"\t"]) [text insertTab:nil];
        else [text insertText:key replacementRange:text.selectedRange];
        i = NSMaxRange(character);
    }
    return SNRichMessageFromDocument(text.document);
}

static SNRichMessage *Read(NSString *mrkdwn) { return SNRichMessageFromDocument(SNRichDocumentFromMrkdown(mrkdwn, nil)); }
static NSArray *Elements(SNRichMessage *message) { return message.blocks.firstObject[@"elements"]; }
static NSDictionary *Section(NSArray *elements) { return @{@"type" : @"rich_text_section", @"elements" : elements}; }
static NSDictionary *Text(NSString *text) { return @{@"type" : @"text", @"text" : text}; }
static NSDictionary *Styled(NSString *text, NSDictionary *style) { return @{@"type" : @"text", @"text" : text, @"style" : style}; }

static void Expect(SNRichMessage *message, NSArray *elements, NSString *text, const char *what) {
    BOOL blocks = [Elements(message) isEqualToArray:elements] && [message.blocks.firstObject[@"type"] isEqual:@"rich_text"];
    BOOL fallback = [message.text isEqualToString:text];
    if (!blocks) printf("    got %s\n", [message.blocks.description stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
    if (!fallback) printf("    got text %s\n", message.text.UTF8String);
    SNExpect(blocks && fallback, what);
}

SN_TEST(ComposerTypesInlineStyles) {
    Expect(Typed(@"hello *world*"), @[ Section(@[ Text(@"hello "), Styled(@"world", @{@"bold" : @YES}) ]) ], @"hello *world*", "closing * makes bold");
    Expect(Typed(@"_it_ ~st~ `a*b*c`"),
           @[ Section(@[ Styled(@"it", @{@"italic" : @YES}), Text(@" "), Styled(@"st", @{@"strike" : @YES}), Text(@" "), Styled(@"a*b*c", @{@"code" : @YES}) ]) ],
           @"_it_ ~st~ `a*b*c`", "italic, strike, code (no bold inside code)");
    Expect(Typed(@"*_both_*"), @[ Section(@[ Styled(@"both", @{@"bold" : @YES, @"italic" : @YES}) ]) ], @"_*both*_", "nested styles");
    Expect(Typed(@"2*3*4 and * spaced *"), @[ Section(@[ Text(@"2*3*4 and * spaced *") ]) ], @"2*3*4 and * spaced *",
           "no style after a word character or around spaces");
    Expect(Typed(@"a < b & c > d"), @[ Section(@[ Text(@"a < b & c > d") ]) ], @"a &lt; b &amp; c &gt; d", "mrkdwn escapes");
    SNExpect(Typed(@"  \n\n ") == nil, "blank documents send nothing");
    Expect(Typed(@"\n\nhi there\n\n"), @[ Section(@[ Text(@"hi there") ]) ], @"hi there", "blank lines at the ends dropped");
    Expect(Typed(@"one\n\ntwo"), @[ Section(@[ Text(@"one\n\ntwo") ]) ], @"one\n\ntwo", "paragraphs share a section");
}

SN_TEST(ComposerTypesBlocks) {
    NSDictionary *bullets = @{@"type" : @"rich_text_list", @"style" : @"bullet", @"indent" : @0, @"border" : @0, @"elements" : @[ Section(@[ Text(@"one") ]), Section(@[ Text(@"two") ]) ]};
    Expect(Typed(@"- one\ntwo"), @[ bullets ], @"• one\n• two", "bullets");
    Expect(Typed(@"* one\ntwo"), @[ bullets ], @"• one\n• two", "bullets from *");
    Expect(Typed(@"intro\n1. a\n*b*\n\nafter"),
           (@[
               Section(@[ Text(@"intro") ]),
               @{@"type" : @"rich_text_list", @"style" : @"ordered", @"indent" : @0, @"border" : @0,
                 @"elements" : @[ Section(@[ Text(@"a") ]), Section(@[ Styled(@"b", @{@"bold" : @YES}) ]) ]},
               Section(@[ Text(@"after") ]),
           ]),
           @"intro\n1. a\n2. *b*\nafter", "ordered list between text, ended by Shift+Return on an empty item");
    Expect(Typed(@"1. a\n\tb\n\nc"),
           (@[
               @{@"type" : @"rich_text_list", @"style" : @"ordered", @"indent" : @0, @"border" : @0, @"elements" : @[ Section(@[ Text(@"a") ]) ]},
               @{@"type" : @"rich_text_list", @"style" : @"ordered", @"indent" : @1, @"border" : @0, @"elements" : @[ Section(@[ Text(@"b") ]) ]},
               @{@"type" : @"rich_text_list", @"style" : @"ordered", @"indent" : @0, @"offset" : @1, @"border" : @0, @"elements" : @[ Section(@[ Text(@"c") ]) ]},
           ]),
           @"1. a\n    1. b\n2. c", "nested items, and the outer list resumes counting");
    NSDictionary *quote = @{@"type" : @"rich_text_quote", @"elements" : @[ Text(@"quoted\nmore") ]};
    Expect(Typed(@"> quoted\nmore"), @[ quote ], @"&gt; quoted\n&gt; more", "quote");
    Expect(Read(@"&gt; quoted\n&gt; more"), @[ quote ], @"&gt; quoted\n&gt; more", "a quote read back");
    Expect(Typed(@"```let *x* = 1\n  y"), @[ @{@"type" : @"rich_text_preformatted", @"border" : @0, @"elements" : @[ Text(@"let *x* = 1\n  y") ]} ],
           @"```let *x* = 1\n  y```", "code block keeps markers and indentation");
    Expect(Read(@"```\nlet *x* = 1\n  y\n```"),
           @[ @{@"type" : @"rich_text_preformatted", @"border" : @0, @"elements" : @[ Text(@"let *x* = 1\n  y") ]} ], @"```let *x* = 1\n  y```",
           "a fenced block read back without the fences' lines");
    Expect(Read(@"```one line```"), @[ @{@"type" : @"rich_text_preformatted", @"border" : @0, @"elements" : @[ Text(@"one line") ]} ], @"```one line```",
           "one-line code block");
    Expect(Read(@"*bold* &lt;3 :+1: :nope_not_one:"),
           @[ Section(@[ Styled(@"bold", @{@"bold" : @YES}), Text(@" <3 "), @{@"type" : @"emoji", @"name" : @"+1", @"unicode" : @"1f44d"}, Text(@" :nope_not_one:") ]) ],
           @"*bold* &lt;3 :+1: :nope_not_one:", "mrkdwn markers, escapes and emoji read back");
}

SN_TEST(ComposerTypesLinksMentionsEmoji) {
    Expect(Typed(@"see [docs](example.com/a) now"),
           @[ Section(@[ Text(@"see "), @{@"type" : @"link", @"url" : @"http://example.com/a", @"text" : @"docs"}, Text(@" now") ]) ],
           @"see <http://example.com/a|docs> now", "markdown link");
    Expect(Typed(@"go to https://example.com/x?y=1."),
           @[ Section(@[ Text(@"go to "), @{@"type" : @"link", @"url" : @"https://example.com/x?y=1"}, Text(@".") ]) ],
           @"go to <https://example.com/x?y=1>.", "bare URL becomes a link without its trailing period");
    Expect(Typed(@"ok :+1: :not_an_emoji_name:"),
           @[ Section(@[ Text(@"ok "), @{@"type" : @"emoji", @"name" : @"+1", @"unicode" : @"1f44d"}, Text(@" :not_an_emoji_name:") ]) ],
           @"ok :+1: :not_an_emoji_name:", "known :name: becomes an emoji");
    Expect(Typed(@":wave::skin-tone-3:"), @[ Section(@[ @{@"type" : @"emoji", @"name" : @"wave", @"unicode" : @"1f44b-1f3fc", @"skin_tone" : @3} ]) ],
           @":wave::skin-tone-3:", "skin tone");
    NSString * (^names)(SNRichEntityKind, NSString *) = ^NSString *(SNRichEntityKind kind, NSString *value) {
        return kind == SNRichEntityUser ? @"Robin" : @"design";
    };
    NSMutableAttributedString *document = SNRichDocumentFromMrkdown(@"hi <@U1> in <#C1|old> <!here> &lt;3", names);
    SNExpect([document.string isEqualToString:@"hi @Robin in #design @here <3"], "mentions shown by name, escapes undone");
    Expect(SNRichMessageFromDocument(document),
           @[ Section(@[ Text(@"hi "), @{@"type" : @"user", @"user_id" : @"U1"}, Text(@" in "), @{@"type" : @"channel", @"channel_id" : @"C1"}, Text(@" "),
                         @{@"type" : @"broadcast", @"range" : @"here"}, Text(@" <3") ]) ],
           @"hi <@U1> in <#C1> <!here> &lt;3", "mentions round-trip through mrkdwn");
}

SN_TEST(ComposerReadsBlocksBack) {
    NSArray *blocks = @[ @{
        @"type" : @"rich_text",
        @"elements" : @[
            Section(@[ Text(@"Plan "), Styled(@"now", @{@"bold" : @YES}), Text(@":\n") ]),
            @{@"type" : @"rich_text_list", @"style" : @"bullet", @"indent" : @0, @"border" : @0, @"elements" : @[ Section(@[ Text(@"a") ]), Section(@[ @{@"type" : @"user", @"user_id" : @"U9"} ]) ]},
            @{@"type" : @"rich_text_quote", @"elements" : @[ Text(@"q") ]},
        ]
    } ];
    NSMutableAttributedString *document = SNRichDocumentFromBlocks(blocks, ^NSString *(SNRichEntityKind kind, NSString *value) { return @"Kim"; });
    SNExpect([document.string isEqualToString:@"Plan now:\na\n@Kim\nq"], "blocks become text");
    SNRichMessage *message = SNRichMessageFromDocument(document);
    NSArray *expected = @[
        Section(@[ Text(@"Plan "), Styled(@"now", @{@"bold" : @YES}), Text(@":") ]),
        @{@"type" : @"rich_text_list", @"style" : @"bullet", @"indent" : @0, @"border" : @0, @"elements" : @[ Section(@[ Text(@"a") ]), Section(@[ @{@"type" : @"user", @"user_id" : @"U9"} ]) ]},
        @{@"type" : @"rich_text_quote", @"elements" : @[ Text(@"q") ]},
    ];
    Expect(message, expected, @"Plan *now*:\n• a\n• <@U9>\n&gt; q", "and back to the same blocks");
}

SN_TEST(ComposerTextViewEditing) {
    SNComposerTextView *text = [[SNComposerTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
    for (NSString *character in @[ @"-", @" ", @"a" ]) [text insertText:character replacementRange:text.selectedRange];
    [text insertLineBreak];
    [text insertText:@"b" replacementRange:text.selectedRange];
    [text insertLineBreak];
    [text insertLineBreak];
    [text insertText:@"c" replacementRange:text.selectedRange];
    Expect(SNRichMessageFromDocument(text.document),
           (@[
               @{@"type" : @"rich_text_list", @"style" : @"bullet", @"indent" : @0, @"border" : @0, @"elements" : @[ Section(@[ Text(@"a") ]), Section(@[ Text(@"b") ]) ]},
               Section(@[ Text(@"c") ]),
           ]),
           @"• a\n• b\nc", "Shift+Return adds items; on an empty item it ends the list");

    text.document = [NSAttributedString new];
    for (NSString *character in @[ @"*", @"h", @"i", @"*", @" ", @"x" ]) [text insertText:character replacementRange:text.selectedRange];
    Expect(SNRichMessageFromDocument(text.document), @[ Section(@[ Styled(@"hi", @{@"bold" : @YES}), Text(@" x") ]) ], @"*hi* x",
           "typing after a shortcut is plain again");
    SNComposerTextView *other = [[SNComposerTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
    [other insertText:@"kept" replacementRange:other.selectedRange];
    SNSettle(0.01);
    SNExpect(text.undoManager.canUndo && other.undoManager != text.undoManager, "each text view keeps its own undo history");
    text.document = [NSAttributedString new];
    SNExpect(!text.undoManager.canUndo && other.undoManager.canUndo, "replacing one's document clears only its history");
    [other.undoManager undo];
    SNExpect(other.string.length == 0, "and undo takes back its typing");

    text.document = [NSAttributedString new];
    [text insertText:@"hey @" replacementRange:text.selectedRange];
    NSRange range;
    SNExpect([[text autocompleteQueryRange:&range] isEqualToString:@"@"] && range.location == 4, "autocomplete query after @");
    [text insertEntity:[SNRichEntity entityWithKind:SNRichEntityUser value:@"U1"] text:@"@Robin" replacingRange:range];
    SNExpect([text.string isEqualToString:@"hey @Robin "], "mention inserted with a space");
    SNExpect([text autocompleteQueryRange:NULL] == nil, "no query after the space");
    [text deleteBackward:nil];
    [text deleteBackward:nil];
    SNExpect([text.string isEqualToString:@"hey "], "Backspace removes the mention whole");
    [text insertText:@"it's 10:30:" replacementRange:text.selectedRange];
    SNExpect([text autocompleteQueryRange:NULL] == nil, "a colon inside a word starts no emoji query");

    text.document = [NSAttributedString new];
    [text insertText:@"x" replacementRange:text.selectedRange];
    text.selectedRange = NSMakeRange(0, 1);
    [text toggleStyle:SNInlineBold];
    SNExpect([text hasStyle:SNInlineBold], "toolbar bold on the selection");
    [text toggleBlock:SNRichBlockQuote];
    Expect(SNRichMessageFromDocument(text.document), @[ @{@"type" : @"rich_text_quote", @"elements" : @[ Styled(@"x", @{@"bold" : @YES}) ]} ], @"&gt; *x*",
           "toolbar quote on the paragraph");
}
