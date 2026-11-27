// Owns the right column's flexpanes: their header, the shortcuts list and the feedback form.
#import "render/strings.h"
#import "ui/kit/button.h"
#import "ui/kit/forms.h"
#import "ui/kit/label.h"
#import "ui/right/panels.h"
#import "ui/right/profile.h"
#import "ui/right/thread.h"
#import "ui/shell/pane.h"

/// The thread column's header: the 15 pt black title 16 pt in, the 28 pt close centred 26 pt from
/// the right, #444649 under the pointer.
static const CGFloat kTitleInset = 16, kCloseBox = 28;
static const SNColorToken kCloseHover = 0x444649ff;
/// .p-shortcuts_flexpane: headings 18 pt black 32 pt above (24 for the first) with a rule under
/// them, rows 16 pt in with 12 pt padding around a 22 pt title and a rule; keys 13 pt in chips.
static const CGFloat kInset = 16, kHeadingTop = 32, kFirstHeadingTop = 24, kHeadingLine = 24, kRowPadding = 12, kRowLine = 22;
static const CGFloat kKey = 22, kKeyPadding = 6, kKeyGap = 4, kListTop = 16, kListBottom = 32;

/// The header every panel has.
@interface SNPanelHeader : NSView
@end

@implementation SNPanelHeader
- (BOOL)isFlipped { return YES; }
@end

NSView *SNMakePanelHeader(NSString *title, CGFloat titleSize, void (^close)(void)) {
    SNPanelHeader *header = [[SNPanelHeader alloc] initWithFrame:NSMakeRect(0, 0, 400, SNThreadHeaderHeight)];
    header.autoresizingMask = NSViewWidthSizable;
    SNLabel *label = [SNLabel labelWithText:title font:SNFont(titleSize, SNFontWeightBlack) color:SNColorContentPry];
    label.lineHeight = SNThreadHeaderHeight;
    label.frame = NSMakeRect(kTitleInset, 0, 400 - 100, SNThreadHeaderHeight);
    label.autoresizingMask = NSViewWidthSizable;
    SNButton *button = [SNButton iconButtonNamed:@"close" size:kCloseBox iconSize:20];
    button.hoverFillColor = kCloseHover;
    button.tooltip = SNLocalized(@"panels.close");
    button.tooltipPlacement = SNPlacementBelow;
    button.frame = NSMakeRect(400 - 26 - kCloseBox / 2, (SNThreadHeaderHeight - kCloseBox) / 2, kCloseBox, kCloseBox);
    button.autoresizingMask = NSViewMinXMargin;
    button.action = ^(SNButton *sender) { close(); };
    [header addSubview:label];
    [header addSubview:button];
    return header;
}

#pragma mark - Keyboard Shortcuts

/// A section of rows: @[heading key, @[@[title key, keys]...]]; keys are chips separated by
/// spaces (QS/P's Mac keys).
static NSArray<NSArray *> *ShortcutSections(void) {
    return @[
        @[ @"panels.shortcuts.basics", @[
            @[ @"panels.shortcuts.jump", @"⌘ K" ], @[ @"panels.shortcuts.search", @"⌘ G" ], @[ @"panels.shortcuts.editLast", @"↑" ],
            @[ @"panels.shortcuts.back", @"⌘ [" ], @[ @"panels.shortcuts.forward", @"⌘ ]" ], @[ @"panels.shortcuts.dismiss", @"Esc" ],
            @[ @"panels.shortcuts.help", @"F1" ]
        ] ],
        @[ @"panels.shortcuts.navigation", @[ @[ @"panels.shortcuts.preferences", @"⌘ ," ] ] ],
        @[ @"panels.shortcuts.messaging", @[
            @[ @"panels.shortcuts.newLine", @"⇧ Enter" ], @[ @"panels.shortcuts.autoUser", @"@" ], @[ @"panels.shortcuts.autoChannel", @"#" ],
            @[ @"panels.shortcuts.autoEmoji", @":" ], @[ @"panels.shortcuts.bold", @"⌘ B" ], @[ @"panels.shortcuts.italic", @"⌘ I" ],
            @[ @"panels.shortcuts.underline", @"⌘ U" ], @[ @"panels.shortcuts.strike", @"⇧ ⌘ X" ], @[ @"panels.shortcuts.code", @"⇧ ⌘ C" ],
            @[ @"panels.shortcuts.bullets", @"⇧ ⌘ 8" ], @[ @"panels.shortcuts.numbers", @"⇧ ⌘ 7" ], @[ @"panels.shortcuts.quote", @"⇧ ⌘ 9" ],
            @[ @"panels.shortcuts.codeBlock", @"⌥ ⇧ ⌘ C" ]
        ] ],
        @[ @"panels.shortcuts.files", @[ @[ @"panels.shortcuts.addFile", @"⌘ O" ] ] ],
    ];
}

@interface SNShortcutsList : NSView
@end

@implementation SNShortcutsList
- (BOOL)isFlipped { return YES; }

static CGFloat KeyWidth(NSString *key) {
    return MAX(kKey, ceil(SNTextWidth(key, SNFont(SNFontSizeCaption, SNFontWeightRegular))) + 2 * kKeyPadding);
}

/// The keys' chips, right-aligned at `right`; returns their width.
static CGFloat DrawKeys(NSString *keys, CGFloat right, CGFloat y) {
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    CGFloat x = right;
    for (NSString *key in [keys componentsSeparatedByString:@" "].reverseObjectEnumerator) {
        CGFloat width = KeyWidth(key);
        x -= width;
        NSRect box = NSMakeRect(x, y, width, kKey);
        [SNColor(SNColorBaseTer) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
        SNDrawText(key, font, SNColorContentPry, kKey, NSTextAlignmentCenter, 1, box);
        x -= kKeyGap;
    }
    return right - x - kKeyGap;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat y = kListTop + kRowPadding * 2 + kRowLine + 1;
    NSArray *sections = ShortcutSections();
    for (NSUInteger i = 0; i < sections.count; i++) {
        y += (i ? kHeadingTop : kFirstHeadingTop) + kHeadingLine + 8 + 1;
        y += [sections[i][1] count] * (kRowPadding * 2 + kRowLine + 1);
    }
    return y + kListBottom;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat width = NSWidth(self.bounds), right = width - kInset, y = kListTop;
    NSFont *title = SNFont(SNFontSizeBase, SNFontWeightRegular);
    // "⌘ / to toggle this panel"
    CGFloat toggle = kInset + KeyWidth(@"⌘") + kKeyGap + KeyWidth(@"/");
    DrawKeys(@"⌘ /", toggle, y + kRowPadding);
    SNDrawText(SNLocalized(@"panels.shortcuts.toggle"), title, SNColorContentPry, kRowLine, NSTextAlignmentLeft, 1,
               NSMakeRect(toggle + 8, y + kRowPadding, right - toggle - 8, kRowLine));
    y += kRowPadding * 2 + kRowLine;
    [SNColor(SNColorOtlTer) setFill];
    NSRectFill(NSMakeRect(kInset, y, right - kInset, 1));
    y += 1;
    NSArray *sections = ShortcutSections();
    for (NSUInteger i = 0; i < sections.count; i++) {
        y += i ? kHeadingTop : kFirstHeadingTop;
        SNDrawText(SNLocalized(sections[i][0]), SNFont(SNFontSizeSubtitle, SNFontWeightBlack), SNColorContentPry, kHeadingLine, NSTextAlignmentLeft, 1,
                   NSMakeRect(kInset, y, right - kInset, kHeadingLine));
        y += kHeadingLine + 8;
        [SNColor(SNColorOtlTer) setFill];
        NSRectFill(NSMakeRect(kInset, y, right - kInset, 1));
        y += 1;
        for (NSArray *row in sections[i][1]) {
            CGFloat keys = DrawKeys(row[1], right, y + kRowPadding);
            SNDrawText(SNLocalized(row[0]), title, SNColorContentPry, kRowLine, NSTextAlignmentLeft, 1, NSMakeRect(kInset, y + kRowPadding, right - kInset - keys - 12, kRowLine));
            y += kRowPadding * 2 + kRowLine;
            [SNColor(SNColorOtlTer) setFill];
            NSRectFill(NSMakeRect(kInset, y, right - kInset, 1));
            y += 1;
        }
    }
}
@end

@implementation SNShortcutsPanel {
    SNPanelHeader *_header;
    NSScrollView *_scroll;
    SNShortcutsList *_list;
}

- (instancetype)initWithClose:(void (^)(void))close {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 800)])) return nil;
    _header = (SNPanelHeader *)SNMakePanelHeader(SNLocalized(@"panels.shortcuts.title"), SNFontSizeBase, close);
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _list = [[SNShortcutsList alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _list;
    [self addSubview:_header];
    [self addSubview:_scroll];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _header.frame = NSMakeRect(0, 0, width, SNThreadHeaderHeight);
    _scroll.frame = NSMakeRect(0, SNThreadHeaderHeight, width, MAX(0, NSHeight(self.bounds) - SNThreadHeaderHeight));
    _list.frame = NSMakeRect(0, 0, width, [_list heightForWidth:width]);
}

- (void)focusForTyping {}

- (NSArray<NSString *> *)sectionTitles {
    NSMutableArray *titles = [NSMutableArray new];
    for (NSArray *section in ShortcutSections()) [titles addObject:SNLocalized(section[0])];
    return titles;
}

- (NSArray<NSString *> *)rowTexts {
    NSMutableArray *rows = [NSMutableArray arrayWithObject:[@"⌘ /: " stringByAppendingString:SNLocalized(@"panels.shortcuts.toggle")]];
    for (NSArray *section in ShortcutSections())
        for (NSArray *row in section[1]) [rows addObject:[NSString stringWithFormat:@"%@: %@", SNLocalized(row[0]), row[1]]];
    return rows;
}

@end

#pragma mark - Feedback

/// .p-feedback_flexpane_body: a column at the bottom, 24/16 padding; the box 3 to 8 lines.
static const CGFloat kBodyPadding = 24, kBox = 3 * 22 + 12, kHeadingGap = 8, kBoxGap = 16;

@implementation SNFeedbackPanel {
    id<SNSource> _source;
    SNPanelHeader *_header;
    SNLabel *_heading, *_subheading, *_thanks, *_thanksText;
    SNFormInput *_input;
    SNButton *_send, *_track, *_again;
    BOOL _sending;
}

/// The box's text while the panel is closed, as Slack keeps its draft.
static NSString *draft;

- (instancetype)initWithSource:(id<SNSource>)source close:(void (^)(void))close {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 800)])) return nil;
    _source = source;
    _header = (SNPanelHeader *)SNMakePanelHeader(SNLocalized(@"panels.feedback.title"), SNFontSizeBase, close);
    _heading = [SNLabel labelWithText:SNLocalized(@"panels.feedback.heading") font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNColorContentPry];
    _subheading = [SNLabel labelWithText:SNLocalized(@"panels.feedback.subheading") font:SNFont(SNFontSizeBase, SNFontWeightBold) color:SNColorContentPry];
    _subheading.maximumLines = 0;
    _subheading.lineHeight = 22;
    _input = [[SNFormInput alloc] initMultilineWithPlaceholder:SNLocalized(@"panels.feedback.placeholder") height:kBox];
    __weak SNFeedbackPanel *weakSelf = self;
    _input.changed = ^(NSString *text) {
        draft = [text copy];
        [weakSelf update];
    };
    _input.keyCommand = ^BOOL(SEL command) {
        if (command != @selector(insertNewline:) || NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) return NO;
        [weakSelf send];
        return YES;
    };
    _send = [SNButton primaryButtonWithTitle:SNLocalized(@"panels.feedback.send")];
    _send.font = SNFont(SNFontSizeBase, SNFontWeightBold);
    _send.action = ^(SNButton *button) { [weakSelf send]; };
    _thanks = [SNLabel labelWithText:SNLocalized(@"panels.feedback.thanks") font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNColorContentPry];
    _thanksText = [SNLabel labelWithText:SNLocalized(@"panels.feedback.thanksText") font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNColorContentPry];
    _thanksText.maximumLines = 0;
    _thanksText.lineHeight = 22;
    _track = [SNButton outlineButtonWithTitle:SNLocalized(@"panels.feedback.track")];
    _track.action = ^(SNButton *button) { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://slack.com/help/requests"]]; };
    _again = [SNButton outlineButtonWithTitle:SNLocalized(@"panels.feedback.again")];
    _again.action = ^(SNButton *button) { [weakSelf showForm]; };
    for (NSView *view in @[ _header, _heading, _subheading, _input, _send, _thanks, _thanksText, _track, _again ]) [self addSubview:view];
    NSString *given = SNTakeFeedbackStartText(), *start = given.length ? given : draft;
    _input.text = start ?: @"";
    [self showForm];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)showForm {
    _sent = NO;
    for (NSView *view in @[ _heading, _subheading, _input, _send ]) view.hidden = NO;
    for (NSView *view in @[ _thanks, _thanksText, _track, _again ]) view.hidden = YES;
    [self update];
    self.needsLayout = YES;
    [self focusForTyping];
}

- (void)update {
    BOOL ready = !_sending && [_input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    _send.enabled = ready;
    _send.alphaValue = ready ? 1 : 0.5;
}

- (NSString *)text { return _input.text; }

- (void)setText:(NSString *)text {
    _input.text = text;
    draft = [text copy];
    [self update];
}

- (void)focusForTyping {
    if (!_input.hidden) [_input focus];
}

- (void)send {
    NSString *text = [_input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (_sending || !text.length) return;
    _sending = YES;
    [self update];
    __weak SNFeedbackPanel *weakSelf = self;
    [_source submitFeedback:text completion:^(NSString *error) {
        SNFeedbackPanel *panel = weakSelf;
        if (!panel) return;
        panel->_sending = NO;
        if (error) return [panel update];
        draft = nil;
        panel->_input.text = @"";
        [panel showThanks];
    }];
}

- (void)showThanks {
    _sent = YES;
    for (NSView *view in @[ _heading, _subheading, _input, _send ]) view.hidden = YES;
    for (NSView *view in @[ _thanks, _thanksText, _track, _again ]) view.hidden = NO;
    self.needsLayout = YES;
}

/// Everything sits at the bottom of the column, as Slack's flex-end body.
- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), inner = width - 2 * kInset, bottom = NSHeight(self.bounds) - kBodyPadding;
    _header.frame = NSMakeRect(0, 0, width, SNThreadHeaderHeight);
    CGFloat buttonWidth = MAX(80, ceil(_send.fittingContentSize.width) + 24);
    _send.frame = NSMakeRect(width - kInset - buttonWidth, bottom - 36, buttonWidth, 36);
    _input.frame = NSMakeRect(kInset, NSMinY(_send.frame) - 12 - kBox, inner, kBox);
    CGFloat sub = [_subheading heightForWidth:inner];
    _subheading.frame = NSMakeRect(kInset, NSMinY(_input.frame) - kBoxGap - sub, inner, sub);
    _heading.frame = NSMakeRect(kInset, NSMinY(_subheading.frame) - kHeadingGap - 24, inner, 24);
    CGFloat againWidth = ceil(_again.fittingContentSize.width) + 24, trackWidth = ceil(_track.fittingContentSize.width) + 24;
    _again.frame = NSMakeRect(kInset, bottom - 36, againWidth, 36);
    _track.frame = NSMakeRect(kInset + againWidth + 12, bottom - 36, trackWidth, 36);
    CGFloat text = [_thanksText heightForWidth:inner];
    _thanksText.frame = NSMakeRect(kInset, NSMinY(_again.frame) - kBoxGap - text, inner, text);
    _thanks.frame = NSMakeRect(kInset, NSMinY(_thanksText.frame) - kHeadingGap - 24, inner, 24);
}

@end

NSView<SNPanelView> *SNMakePanel(NSString *panel, id<SNSource> source, void (^close)(void)) {
    if ([panel isEqualToString:SNPanelShortcuts]) return [[SNShortcutsPanel alloc] initWithClose:close];
    if ([panel isEqualToString:SNPanelFeedback]) return [[SNFeedbackPanel alloc] initWithSource:source close:close];
    NSString *userID = SNPanelProfileUserID(panel);
    if (userID) return [[SNProfilePanel alloc] initWithUserID:userID source:source close:close];
    return nil;
}
