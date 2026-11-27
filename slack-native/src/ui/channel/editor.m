// Owns the inline editor's box, keys and saving.
#import "render/strings.h"
#import "ui/channel/editor.h"
#import "ui/channel/messagelayout.h"
#import "ui/composer/composer.h"
#import "ui/composer/textview.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"

/// The row's padding around the composer's box; the buttons in its footer are Slack's small
/// buttons (28 pt, 13 pt bold, 12 pt padding).
static const CGFloat kPad = 8, kButtonHeight = 28, kButtonPadding = 12, kButtonGap = 8, kButtonMinimum = 56;

static BOOL HasRichText(NSArray<NSDictionary *> *blocks) {
    for (NSDictionary *block in blocks)
        if ([block isKindOfClass:NSDictionary.class] && [block[@"type"] isEqual:@"rich_text"]) return YES;
    return NO;
}

static SNButton *SmallButton(SNButton *button) {
    button.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    button.cornerRadius = SNRadiusBase;
    return button;
}

@interface SNMessageEditor () <SNComposerTextViewDelegate>
@end

@implementation SNMessageEditor {
    id<SNSource> _source;
    SNAvatarView *_avatar;
    NSScrollView *_scroll;
    SNComposerTextView *_textView;
    SNButton *_cancel, *_saveButton;
    NSString *_original;
    CGFloat _textHeight;
    BOOL _done;
}

- (instancetype)initWithMessage:(SNMessage *)message source:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 120)])) return nil;
    _message = message;
    _source = source;

    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(SNMessageGutter, SNMessageAvatarTop, SNMessageAvatarSize, SNMessageAvatarSize)];
    _avatar.imageURL = [[source userWithID:message.userID ?: @""] avatarURLForPixels:SNMessageAvatarSize * 2];
    [self addSubview:_avatar];

    _textView = [[SNComposerTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, SNComposerLineHeight)];
    _textView.composerDelegate = self;
    __weak id<SNSource> weakSource = source;
    NSString * (^name)(SNRichEntityKind, NSString *) = ^NSString *(SNRichEntityKind kind, NSString *value) {
        id<SNSource> named = weakSource;
        if (kind == SNRichEntityUser) return [named userWithID:value].visibleName;
        if (kind == SNRichEntityChannel) return [named conversationWithID:value].name;
        if (kind == SNRichEntityUsergroup) return [named usergroupHandleWithID:value];
        return nil;
    };
    _textView.document = HasRichText(message.blocks) ? SNRichDocumentFromBlocks(message.blocks, name) : SNRichDocumentFromMrkdown(message.text, name);
    _original = SNRichMessageFromDocument(_textView.document).text ?: @"";
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.verticalScrollElasticity = NSScrollElasticityNone;
    _scroll.documentView = _textView;
    [self addSubview:_scroll];

    __weak SNMessageEditor *weakSelf = self;
    _cancel = SmallButton([SNButton outlineButtonWithTitle:SNLocalized(@"channel.edit.cancel")]);
    _cancel.action = ^(SNButton *button) { [weakSelf cancel]; };
    _saveButton = SmallButton([SNButton primaryButtonWithTitle:SNLocalized(@"channel.edit.save")]);
    _saveButton.action = ^(SNButton *button) { [weakSelf save]; };
    [self addSubview:_cancel];
    [self addSubview:_saveButton];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSString *)text { return _textView.string; }
- (void)setText:(NSString *)text { _textView.document = SNRichDocumentFromMrkdown(text, nil); }

- (void)focus { [self.window makeFirstResponder:_textView]; }

- (CGFloat)textWidthFor:(CGFloat)width { return MAX(40, width - SNMessageTextLeft - SNMessageTextRight - 2 * SNComposerTextInset); }

/// The text's height once laid out at `width` (the row's).
- (CGFloat)textHeightForWidth:(CGFloat)width {
    NSRect frame = _textView.frame;
    CGFloat textWidth = [self textWidthFor:width];
    if (frame.size.width != textWidth) [_textView setFrameSize:NSMakeSize(textWidth, frame.size.height)];
    return MAX(SNComposerLineHeight, ceil(_textView.contentHeight));
}

- (CGFloat)heightForWidth:(CGFloat)width { return kPad + 1 + SNComposerTextTop + [self textHeightForWidth:width] + SNComposerTextBottom + SNComposerFooterHeight + 1 + kPad; }

- (NSRect)box {
    NSRect bounds = self.bounds;
    return NSMakeRect(SNMessageTextLeft, kPad, MAX(0, bounds.size.width - SNMessageTextLeft - SNMessageTextRight), MAX(0, bounds.size.height - 2 * kPad));
}

- (void)layout {
    [super layout];
    NSRect box = self.box;
    _textHeight = [self textHeightForWidth:self.bounds.size.width];
    _scroll.frame = NSMakeRect(NSMinX(box) + SNComposerTextInset, NSMinY(box) + 1 + SNComposerTextTop, [self textWidthFor:self.bounds.size.width], _textHeight);
    [_textView setFrameSize:NSMakeSize(_scroll.frame.size.width, _textHeight)];
    CGFloat right = NSMaxX(box) - kButtonGap, y = NSMaxY(box) - 1 - SNComposerFooterHeight + (SNComposerFooterHeight - kButtonHeight) / 2;
    for (SNButton *button in @[ _saveButton, _cancel ]) {
        CGFloat buttonWidth = MAX(kButtonMinimum, ceil(button.fittingContentSize.width) + 2 * kButtonPadding);
        button.frame = NSMakeRect(right - buttonWidth, y, buttonWidth, kButtonHeight);
        right -= buttonWidth + kButtonGap;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    // Slack tints the row being edited like a highlighted message.
    [SNColor(SNColorBaseHgl3) setFill];
    NSRectFill(self.bounds);
    SNDrawComposerBox(self.box, _textView.isFocused);
}

#pragma mark Ending

- (void)save {
    if (_done) return;
    SNRichMessage *edited = SNRichMessageFromDocument(_textView.document);
    if (!edited) {
        [self finish];
        if (self.deleteRequested) self.deleteRequested(self.message);
        return;
    }
    if (![edited.text isEqualToString:_original]) [_source editMessage:self.message text:edited.text blocks:edited.blocks];
    [self finish];
}

- (void)cancel {
    if (!_done) [self finish];
}

- (void)finish {
    _done = YES;
    if (self.finished) self.finished(self);
}

#pragma mark Text view delegate

- (void)composerTextViewDidChange:(SNComposerTextView *)textView {
    if ([self textHeightForWidth:self.bounds.size.width] != _textHeight && self.heightChanged) self.heightChanged(self);
}

- (void)composerTextViewFocusDidChange:(SNComposerTextView *)textView { self.needsDisplay = YES; }
- (void)composerTextViewSend:(SNComposerTextView *)textView { [self save]; }
- (void)composerTextViewEditLastMessage:(SNComposerTextView *)textView {}

- (BOOL)composerTextView:(SNComposerTextView *)textView autocompleteCommand:(SEL)command {
    if (command != @selector(cancelOperation:)) return NO;
    [self cancel];
    return YES;
}

@end
