// Owns the editor's layout, display styling, drawing and keys; the document's meaning and its
// shortcuts live in richtext.m.
#import "render/document.h"
#import "render/icon.h"
#import "theme/theme.h"
#import "ui/composer/textview.h"
#import "ui/kit/label.h"

/// components.json mrkdwn: list items indent 28 with the marker in a 22 pt box 6 pt before the
/// text; quotes indent 16 behind a 4 pt bar; code blocks are padded 8 inside a 1 pt ring.
static const CGFloat kListIndent = 28, kMarkerBox = 22, kMarkerGap = 6, kQuoteIndent = 16, kQuoteBar = 4, kCodePadding = 8;
/// Emoji are 18 pt on the 22.5 pt lines.
static const CGFloat kEmojiBox = 18;
/// components.json composer: typed text #f8f8f8, placeholder #9a9b9e through a grayscale filter,
/// inline code campfire-60 in the dark composer (messages use #e8912d); mrkdwn's chips and code
/// boxes (render/document.m draws messages' the same way).
static const SNColorToken kTextColor = SNColorContentPry, kPlaceholderColor = 0x9b9b9bff, kInlineCodeColor = SNPaletteCampfire60;
static const SNColorToken kCodeFill = SNLegacyFaintFill, kCodeRing = SNLegacyHairline, kMentionFill = SNColorSurfHgl1, kBroadcastFill = SNColorSurfHgl3;
static const SNColorToken kBroadcastText = SNColorContentHgl3, kSelection = 0x9a9c9eff;
static const unsigned short kKeyReturn = 36, kKey7 = 26, kKey8 = 28, kKey9 = 25;

static NSFont *BaseFont(void) { return SNFont(SNComposerFontSize, SNFontWeightRegular); }
static NSFont *CodeFont(void) { return SNMonoFont(12, SNFontWeightRegular); }
static NSFont *EmojiFont(void) {
    static NSFont *font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ font = SNEmojiFont(kEmojiBox); });
    return font;
}

static NSParagraphStyle *ParagraphStyle(SNRichBlock *block) {
    static NSMutableDictionary<id, NSParagraphStyle *> *styles;
    if (!styles) styles = [NSMutableDictionary new];
    id key = block ?: NSNull.null;
    NSParagraphStyle *cached = styles[key];
    if (cached) return cached;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.minimumLineHeight = style.maximumLineHeight = SNComposerLineHeight;
    CGFloat indent = block.isList ? kListIndent * (block.indent + 1) : block.kind == SNRichBlockQuote ? kQuoteIndent : block.kind == SNRichBlockCode ? kCodePadding : 0;
    style.firstLineHeadIndent = style.headIndent = indent;
    if (block.kind == SNRichBlockCode) style.tailIndent = -kCodePadding;
    return styles[key] = style;
}

/// Draws a custom emoji's picture where its attachment character is.
@interface SNComposerEmojiCell : NSTextAttachmentCell
@property (nonatomic, copy) NSString *name;
@end

@implementation SNComposerEmojiCell

- (NSSize)cellSize { return NSMakeSize(kEmojiBox, kEmojiBox); }

/// Centred on the line box, which the layout gives the base font's baseline.
- (NSPoint)cellBaselineOffset {
    CGFloat baseline = SNBaselineOffset(BaseFont(), SNComposerLineHeight);
    return NSMakePoint(0, -((SNComposerLineHeight + kEmojiBox) / 2 - baseline));
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    SNDrawEmoji(self.name, kEmojiBox, frame, view.imageHolder);
}

@end

static NSTextAttachment *CustomEmojiAttachment(NSString *name) {
    static NSMutableDictionary<NSString *, NSTextAttachment *> *attachments;
    if (!attachments) attachments = [NSMutableDictionary new];
    NSTextAttachment *attachment = attachments[name];
    if (!attachment) {
        attachment = [NSTextAttachment new];
        SNComposerEmojiCell *cell = [SNComposerEmojiCell new];
        cell.name = name;
        attachment.attachmentCell = cell;
        attachments[name] = attachment;
    }
    return attachment;
}

static NSDictionary *DisplayAttributes(SNInlineStyle style, SNRichEntity *entity, NSString *link, SNRichBlock *block) {
    NSFont *font = BaseFont();
    SNColorToken color = kTextColor;
    NSTextAttachment *attachment = nil;
    if (block.kind == SNRichBlockCode) {
        font = CodeFont();
    } else if (style & SNInlineCode) {
        font = CodeFont();
        color = kInlineCodeColor;
    } else if (entity.kind == SNRichEntityEmoji) {
        font = EmojiFont();
        if (!entity.unicode) attachment = CustomEmojiAttachment(entity.value);
    } else {
        CGFloat weight = (style & SNInlineBold) || entity.kind == SNRichEntityBroadcast ? SNFontWeightBold : SNFontWeightRegular;
        font = style & SNInlineItalic ? SNItalicFont(SNComposerFontSize, weight) : SNFont(SNComposerFontSize, weight);
        if (entity.kind == SNRichEntityBroadcast) color = kBroadcastText;
        else if (entity || link) color = SNColorContentHgl1;
    }
    NSMutableDictionary *attributes = [@{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : SNColor(color),
        NSStrikethroughStyleAttributeName : @(style & SNInlineStrike ? NSUnderlineStyleSingle : NSUnderlineStyleNone),
        NSUnderlineStyleAttributeName : @(style & SNInlineUnderline ? NSUnderlineStyleSingle : NSUnderlineStyleNone),
        NSParagraphStyleAttributeName : ParagraphStyle(block),
    } mutableCopy];
    attributes[NSAttachmentAttributeName] = attachment;
    return attributes;
}

static SNRichBlock *BlockAt(NSAttributedString *text, NSUInteger index) {
    return index < text.length ? [text attribute:SNRichBlockAttribute atIndex:index effectiveRange:NULL] : nil;
}

/// "1", "a", "i" by depth, as the web client's ordered lists cycle decimal, alpha and roman.
static NSString *OrderedMarker(NSInteger number, NSInteger indent) {
    switch (indent % 3) {
    case 1: {
        NSMutableString *letters = [NSMutableString new];
        for (NSInteger n = number; n > 0; n = (n - 1) / 26) [letters insertString:[NSString stringWithFormat:@"%c", (char)('a' + (n - 1) % 26)] atIndex:0];
        return [letters stringByAppendingString:@"."];
    }
    case 2: {
        NSArray *numerals = @[ @[ @1000, @"m" ], @[ @900, @"cm" ], @[ @500, @"d" ], @[ @400, @"cd" ], @[ @100, @"c" ], @[ @90, @"xc" ], @[ @50, @"l" ], @[ @40, @"xl" ], @[ @10, @"x" ], @[ @9, @"ix" ], @[ @5, @"v" ], @[ @4, @"iv" ], @[ @1, @"i" ] ];
        NSMutableString *roman = [NSMutableString new];
        NSInteger n = number;
        for (NSArray *pair in numerals)
            while (n >= [pair[0] integerValue]) {
                [roman appendString:pair[1]];
                n -= [pair[0] integerValue];
            }
        return [roman stringByAppendingString:@"."];
    }
    default: return [NSString stringWithFormat:@"%ld.", (long)number];
    }
}

@interface SNComposerTextView () <NSLayoutManagerDelegate, NSTextStorageDelegate>
@end

@implementation SNComposerTextView {
    BOOL _restyling, _focused, _editing;
    /// Entities an edit cut into, as ranges before the edit, waiting for the edit to finish.
    NSMutableArray<NSValue *> *_brokenEntities;
    NSRange _editedRange;
    NSUInteger _replacementLength;
    /// The characters edited since the last restyle (NSNotFound: none).
    NSRange _unstyled;
    /// Each composer (and the inline editor) undoes its own typing, not the window's.
    NSUndoManager *_undo;
}

- (instancetype)initWithFrame:(NSRect)frame {
    NSTextStorage *storage = [NSTextStorage new];
    NSLayoutManager *layout = [NSLayoutManager new];
    [storage addLayoutManager:layout];
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:NSMakeSize(frame.size.width, CGFLOAT_MAX)];
    container.widthTracksTextView = YES;
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];
    if (!(self = [super initWithFrame:frame textContainer:container])) return nil;
    layout.delegate = self;
    layout.allowsNonContiguousLayout = YES;
    storage.delegate = self;
    _placeholder = @"";
    _brokenEntities = [NSMutableArray new];
    _unstyled = NSMakeRange(NSNotFound, 0);
    _undo = [NSUndoManager new];
    self.drawsBackground = NO;
    self.richText = YES;
    self.allowsUndo = YES;
    self.importsGraphics = NO;
    self.usesFontPanel = NO;
    self.textContainerInset = NSZeroSize;
    self.verticallyResizable = YES;
    self.horizontallyResizable = NO;
    self.autoresizingMask = NSViewWidthSizable;
    self.automaticQuoteSubstitutionEnabled = self.automaticDashSubstitutionEnabled = self.automaticTextReplacementEnabled = NO;
    self.automaticLinkDetectionEnabled = self.smartInsertDeleteEnabled = NO;
    self.insertionPointColor = SNColor(kTextColor);
    self.selectedTextAttributes = @{NSBackgroundColorAttributeName : SNColor(kSelection)};
    self.typingAttributes = DisplayAttributes(0, nil, nil, nil);
    return self;
}

#pragma mark Line boxes

/// Every line is a CSS line box: 22.5 pt with the baseline where a browser puts it for 15 pt Lato,
/// whatever the line holds (code, emoji).
- (BOOL)layoutManager:(NSLayoutManager *)layoutManager shouldSetLineFragmentRect:(inout NSRect *)lineFragmentRect
     lineFragmentUsedRect:(inout NSRect *)lineFragmentUsedRect baselineOffset:(inout CGFloat *)baselineOffset
          inTextContainer:(NSTextContainer *)textContainer forGlyphRange:(NSRange)glyphRange {
    lineFragmentRect->size.height = lineFragmentUsedRect->size.height = SNComposerLineHeight;
    *baselineOffset = SNBaselineOffset(BaseFont(), SNComposerLineHeight);
    return YES;
}

- (CGFloat)contentHeight {
    [self.layoutManager ensureLayoutForTextContainer:self.textContainer];
    return MAX(SNComposerLineHeight, ceil([self.layoutManager usedRectForTextContainer:self.textContainer].size.height * 2) / 2);
}

#pragma mark Document

- (NSUndoManager *)undoManager { return _undo; }

- (NSAttributedString *)document { return [self.textStorage copy]; }

/// Replaces the text without telling the delegate: only typing is a change (a draft put back
/// must not tell Slack the user is typing).
- (void)setDocument:(NSAttributedString *)document {
    [self.imageHolder removeAllImages];
    [self.textStorage setAttributedString:document];
    [self restyleEdited];
    self.selectedRange = NSMakeRange(document.length, 0);
    [self resetTypingAttributes];
    [_undo removeAllActions];
}

- (BOOL)isEmpty { return self.textStorage.length == 0; }

- (void)textStorage:(NSTextStorage *)textStorage didProcessEditing:(NSTextStorageEditActions)editedMask range:(NSRange)editedRange changeInLength:(NSInteger)delta {
    if (_restyling || !(editedMask & NSTextStorageEditedCharacters)) return;
    if (_unstyled.location == NSNotFound) {
        _unstyled = editedRange;
        return;
    }
    // The earlier edit's range, moved by this one.
    NSUInteger end = NSMaxRange(_unstyled);
    if (end > editedRange.location) end = (NSUInteger)MAX((NSInteger)editedRange.location, (NSInteger)end + delta);
    NSUInteger start = MIN(_unstyled.location, editedRange.location);
    end = MIN(textStorage.length, MAX(end, NSMaxRange(editedRange)));
    _unstyled = NSMakeRange(start, end - MIN(start, end));
}

/// Fonts, colours and paragraph styles from the semantic attributes, for the paragraphs edited
/// since the last time: a keystroke restyles its paragraph, not the document.
- (void)restyleEdited {
    NSTextStorage *storage = self.textStorage;
    NSRange edited = _unstyled;
    _unstyled = NSMakeRange(NSNotFound, 0);
    if (edited.location == NSNotFound || !storage.length) return;
    NSUInteger location = MIN(edited.location, storage.length - 1);
    NSRange paragraphs = [storage.string paragraphRangeForRange:NSMakeRange(location, MIN(edited.length, storage.length - location))];
    _restyling = YES;
    [storage beginEditing];
    SNRichNormalizeParagraphs(storage, paragraphs);
    NSMutableArray *runs = [NSMutableArray new];
    [storage enumerateAttributesInRange:paragraphs options:0 usingBlock:^(NSDictionary *attributes, NSRange range, BOOL *stop) {
        [runs addObject:@[ [NSValue valueWithRange:range], DisplayAttributes([attributes[SNRichStyleAttribute] unsignedIntegerValue], attributes[SNRichEntityAttribute],
                                                                              attributes[SNRichLinkAttribute], attributes[SNRichBlockAttribute]) ]];
    }];
    for (NSArray *run in runs) {
        NSRange range = [run[0] rangeValue];
        [storage removeAttribute:NSAttachmentAttributeName range:range];
        [storage addAttributes:run[1] range:range];
    }
    // Bare URLs show as links once typed, as they will be sent.
    SNRichEnumerateBareLinks(storage.string, paragraphs, ^(NSRange link) {
        NSDictionary *attributes = [storage attributesAtIndex:link.location effectiveRange:NULL];
        SNRichBlock *block = attributes[SNRichBlockAttribute];
        if (block.kind == SNRichBlockCode || ([attributes[SNRichStyleAttribute] unsignedIntegerValue] & SNInlineCode) || attributes[SNRichEntityAttribute]) return;
        [storage addAttribute:NSForegroundColorAttributeName value:SNColor(SNColorContentHgl1) range:link];
    });
    [storage endEditing];
    _restyling = NO;
}

/// What typing at the caret gets: the paragraph's block and the style of the text before it,
/// never a link or a mention.
- (void)resetTypingAttributes {
    NSTextStorage *storage = self.textStorage;
    NSUInteger caret = self.selectedRange.location;
    SNRichBlock *block = nil;
    SNInlineStyle style = 0;
    if (storage.length) {
        NSRange paragraph = SNRichParagraphRange(storage.string, caret);
        NSUInteger probe = paragraph.length ? paragraph.location : caret - 1;
        if (caret > 0 || paragraph.length) block = [storage attribute:SNRichBlockAttribute atIndex:MIN(probe, storage.length - 1) effectiveRange:NULL];
        if (caret > 0 && caret > paragraph.location) style = [[storage attribute:SNRichStyleAttribute atIndex:caret - 1 effectiveRange:NULL] unsignedIntegerValue];
    }
    [self setTypingStyle:style block:block];
}

- (void)setTypingStyle:(SNInlineStyle)style block:(SNRichBlock *)block {
    NSMutableDictionary *attributes = [DisplayAttributes(style, nil, nil, block) mutableCopy];
    if (style) attributes[SNRichStyleAttribute] = @(style);
    if (block) attributes[SNRichBlockAttribute] = block;
    super.typingAttributes = attributes;
}

- (void)setTypingAttributes:(NSDictionary<NSAttributedStringKey, id> *)typingAttributes {
    NSMutableDictionary *attributes = [typingAttributes mutableCopy];
    [attributes removeObjectsForKeys:@[ SNRichEntityAttribute, SNRichLinkAttribute ]];
    super.typingAttributes = attributes;
}

#pragma mark Editing

- (BOOL)shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)string {
    if (![super shouldChangeTextInRange:range replacementString:string]) return NO;
    // A mention or emoji the edit cuts into or splits becomes plain text.
    [_brokenEntities removeAllObjects];
    NSTextStorage *storage = self.textStorage;
    NSRange around = NSMakeRange(range.location > 0 ? range.location - 1 : 0, MIN(storage.length, NSMaxRange(range) + 1) - (range.location > 0 ? range.location - 1 : 0));
    [storage enumerateAttribute:SNRichEntityAttribute inRange:around options:0 usingBlock:^(id entity, NSRange entityRange, BOOL *stop) {
        if (!entity) return;
        BOOL covered = NSEqualRanges(NSIntersectionRange(entityRange, range), entityRange) && range.length;
        BOOL inside = range.location > entityRange.location && range.location < NSMaxRange(entityRange);
        BOOL overlaps = NSIntersectionRange(entityRange, range).length > 0;
        if (!covered && (inside || overlaps)) [_brokenEntities addObject:[NSValue valueWithRange:entityRange]];
    }];
    _editedRange = range;
    _replacementLength = string.length;
    _editing = YES;
    return YES;
}

- (void)didChangeText {
    NSTextStorage *storage = self.textStorage;
    NSInteger delta = (NSInteger)_replacementLength - (NSInteger)_editedRange.length;
    for (NSValue *value in _brokenEntities) {
        NSRange entity = value.rangeValue;
        if (entity.location < _editedRange.location)
            [storage removeAttribute:SNRichEntityAttribute range:NSMakeRange(entity.location, MIN(_editedRange.location, NSMaxRange(entity)) - entity.location)];
        if (NSMaxRange(entity) > NSMaxRange(_editedRange)) {
            NSUInteger start = (NSUInteger)((NSInteger)NSMaxRange(_editedRange) + delta);
            NSUInteger length = NSMaxRange(entity) - MAX(NSMaxRange(_editedRange), entity.location);
            if (start + length <= storage.length) [storage removeAttribute:SNRichEntityAttribute range:NSMakeRange(start, length)];
        }
    }
    [_brokenEntities removeAllObjects];
    [self restyleEdited];
    _editing = NO;
    [super didChangeText];
    [self.composerDelegate composerTextViewDidChange:self];
}

/// Replaces `range` of the document with `replacement` as one undoable edit.
- (BOOL)replaceRange:(NSRange)range with:(NSAttributedString *)replacement {
    if (![self shouldChangeTextInRange:range replacementString:replacement.string]) return NO;
    [self.textStorage replaceCharactersInRange:range withAttributedString:replacement];
    [self didChangeText];
    return YES;
}

/// Sets the block of the paragraphs in `range` as one undoable edit (an empty last paragraph
/// keeps it in the typing attributes).
- (void)setBlock:(SNRichBlock *)block forParagraphsIn:(NSRange)range {
    NSTextStorage *storage = self.textStorage;
    NSRange paragraphs = [storage.string paragraphRangeForRange:range];
    if (paragraphs.length) {
        NSMutableAttributedString *changed = [[storage attributedSubstringFromRange:paragraphs] mutableCopy];
        if (block) [changed addAttribute:SNRichBlockAttribute value:block range:NSMakeRange(0, changed.length)];
        else [changed removeAttribute:SNRichBlockAttribute range:NSMakeRange(0, changed.length)];
        NSRange selection = self.selectedRange;
        [self replaceRange:paragraphs with:changed];
        self.selectedRange = selection;
    }
    SNInlineStyle style = [self.typingAttributes[SNRichStyleAttribute] unsignedIntegerValue];
    [self setTypingStyle:style block:block];
    self.needsDisplay = YES;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    [super insertText:string replacementRange:replacementRange];
    NSString *plain = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
    NSUInteger end = self.selectedRange.location;
    if (!plain.length || end < plain.length) return;
    NSTextStorage *storage = self.textStorage;
    // Shortcuts end at the last character typed and stay in its paragraph.
    NSUInteger last = end - 1;
    NSRange paragraph = SNRichParagraphRange(storage.string, last);
    NSMutableAttributedString *edited = [[storage attributedSubstringFromRange:paragraph] mutableCopy];
    SNRichBlock *block = nil;
    NSUInteger caret = SNApplyTypingShortcuts(edited, NSMakeRange(last - paragraph.location, 1), &block);
    if (caret == NSNotFound) return;
    [self replaceRange:paragraph with:edited];
    self.selectedRange = NSMakeRange(paragraph.location + caret, 0);
    // What is typed after a shortcut is plain again, in the same block.
    [self setTypingStyle:0 block:block];
}

// Pasted text takes the composer's own formatting, not the styling of wherever it came from.
- (void)paste:(id)sender {
    if ([self.composerDelegate respondsToSelector:@selector(composerTextView:pasteFilesFrom:)] &&
        [self.composerDelegate composerTextView:self pasteFilesFrom:NSPasteboard.generalPasteboard])
        return;
    [self pasteAsPlainText:sender];
}

// Files dropped on the text attach to the message (the pane takes the drop), never as their paths.
- (NSArray<NSPasteboardType> *)acceptableDragTypes { return @[ NSPasteboardTypeString ]; }

- (void)setSelectedRanges:(NSArray<NSValue *> *)ranges affinity:(NSSelectionAffinity)affinity stillSelecting:(BOOL)stillSelecting {
    [super setSelectedRanges:ranges affinity:affinity stillSelecting:stillSelecting];
    if (_restyling) return;
    [self resetTypingAttributes];
    // A caret moved by the user, not by an edit (the change reports those).
    if (!_editing && [self.composerDelegate respondsToSelector:@selector(composerTextViewSelectionDidChange:)])
        [self.composerDelegate composerTextViewSelectionDidChange:self];
}

- (void)insertLineBreak {
    NSTextStorage *storage = self.textStorage;
    NSRange selection = self.selectedRange;
    NSRange paragraph = SNRichParagraphRange(storage.string, selection.location);
    SNRichBlock *block = self.typingAttributes[SNRichBlockAttribute];
    NSString *line = [[storage.string substringWithRange:paragraph] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if (!selection.length && !line.length && block && block.kind != SNRichBlockCode) {
        // An empty item steps out a level; an empty quote line or outermost item ends the block.
        [self setBlock:block.isList && block.indent > 0 ? [SNRichBlock blockWithKind:block.kind indent:block.indent - 1] : nil forParagraphsIn:selection];
        return;
    }
    [self insertText:@"\n" replacementRange:selection];
}

- (void)insertNewline:(id)sender {
    if ([self.composerDelegate composerTextView:self autocompleteCommand:_cmd]) return;
    NSEvent *event = NSApp.currentEvent;
    NSEventModifierFlags flags = event.type == NSEventTypeKeyDown ? event.modifierFlags : 0;
    BOOL shift = flags & NSEventModifierFlagShift, command = flags & NSEventModifierFlagCommand;
    SNRichBlock *block = self.typingAttributes[SNRichBlockAttribute];
    BOOL line = self.returnStartsLine                                       ? !command
              : self.returnStartsLineInCode && block.kind == SNRichBlockCode ? !shift
                                                                             : shift;
    if (line) [self insertLineBreak];
    else [self.composerDelegate composerTextViewSend:self];
}

- (void)insertNewlineIgnoringFieldEditor:(id)sender { [self insertLineBreak]; }

- (void)insertTab:(id)sender {
    if ([self.composerDelegate composerTextView:self autocompleteCommand:_cmd]) return;
    SNRichBlock *block = self.typingAttributes[SNRichBlockAttribute];
    if (block.isList) [self setBlock:[SNRichBlock blockWithKind:block.kind indent:block.indent + 1] forParagraphsIn:self.selectedRange];
    else [super insertTab:sender];
}

- (void)insertBacktab:(id)sender {
    SNRichBlock *block = self.typingAttributes[SNRichBlockAttribute];
    if (block.isList && block.indent > 0) [self setBlock:[SNRichBlock blockWithKind:block.kind indent:block.indent - 1] forParagraphsIn:self.selectedRange];
}

- (void)moveUp:(id)sender {
    if ([self.composerDelegate composerTextView:self autocompleteCommand:_cmd]) return;
    if (self.isEmpty) [self.composerDelegate composerTextViewEditLastMessage:self];
    else [super moveUp:sender];
}

- (void)moveDown:(id)sender {
    if (![self.composerDelegate composerTextView:self autocompleteCommand:_cmd]) [super moveDown:sender];
}

- (void)cancelOperation:(id)sender { [self.composerDelegate composerTextView:self autocompleteCommand:_cmd]; }

- (void)deleteBackward:(id)sender {
    NSTextStorage *storage = self.textStorage;
    NSRange selection = self.selectedRange;
    if (!selection.length) {
        NSRange paragraph = SNRichParagraphRange(storage.string, selection.location);
        SNRichBlock *block = self.typingAttributes[SNRichBlockAttribute];
        if (block && selection.location == paragraph.location) {
            [self setBlock:block.isList && block.indent > 0 ? [SNRichBlock blockWithKind:block.kind indent:block.indent - 1] : nil forParagraphsIn:selection];
            return;
        }
        // A mention goes whole; an emoji is one character anyway.
        NSRange entityRange;
        SNRichEntity *entity = selection.location > 0 ? [storage attribute:SNRichEntityAttribute atIndex:selection.location - 1 effectiveRange:&entityRange] : nil;
        if (entity && entity.kind != SNRichEntityEmoji) self.selectedRange = NSMakeRange(entityRange.location, selection.location - entityRange.location);
    }
    [super deleteBackward:sender];
}

#pragma mark Formatting

- (BOOL)hasStyle:(SNInlineStyle)style {
    NSRange selection = self.selectedRange;
    if (!selection.length) return ([self.typingAttributes[SNRichStyleAttribute] unsignedIntegerValue] & style) == style;
    __block BOOL all = YES;
    [self.textStorage enumerateAttribute:SNRichStyleAttribute inRange:selection options:0 usingBlock:^(NSNumber *value, NSRange range, BOOL *stop) {
        if ((value.unsignedIntegerValue & style) != style) all = NO, *stop = YES;
    }];
    return all;
}

- (void)toggleStyle:(SNInlineStyle)style {
    NSRange selection = self.selectedRange;
    BOOL on = ![self hasStyle:style];
    if (!selection.length) {
        SNInlineStyle current = [self.typingAttributes[SNRichStyleAttribute] unsignedIntegerValue];
        [self setTypingStyle:on ? current | style : current & ~style block:self.typingAttributes[SNRichBlockAttribute]];
        return;
    }
    NSMutableAttributedString *changed = [[self.textStorage attributedSubstringFromRange:selection] mutableCopy];
    [changed enumerateAttribute:SNRichStyleAttribute inRange:NSMakeRange(0, changed.length) options:0 usingBlock:^(NSNumber *value, NSRange range, BOOL *stop) {
        SNInlineStyle current = value.unsignedIntegerValue;
        [changed addAttribute:SNRichStyleAttribute value:@(on ? current | style : current & ~style) range:range];
    }];
    [self replaceRange:selection with:changed];
    self.selectedRange = selection;
}

- (void)toggleBlock:(SNRichBlockKind)kind {
    SNRichBlock *block = self.typingAttributes[SNRichBlockAttribute];
    [self setBlock:block.kind == kind ? nil : [SNRichBlock blockWithKind:kind indent:0] forParagraphsIn:self.selectedRange];
}

- (void)beginLink {
    NSRange selection = self.selectedRange;
    NSString *text = [self.textStorage.string substringWithRange:selection];
    [self insertText:[NSString stringWithFormat:@"[%@](", text.length ? text : @""] replacementRange:selection];
    if (!text.length) self.selectedRange = NSMakeRange(self.selectedRange.location - 2, 0);
}

- (void)insertEntity:(SNRichEntity *)entity text:(NSString *)text replacingRange:(NSRange)range {
    NSDictionary *typing = self.typingAttributes;
    NSMutableDictionary *attributes = [NSMutableDictionary new];
    if (typing[SNRichBlockAttribute]) attributes[SNRichBlockAttribute] = typing[SNRichBlockAttribute];
    if (typing[SNRichStyleAttribute] && entity.kind == SNRichEntityEmoji) attributes[SNRichStyleAttribute] = typing[SNRichStyleAttribute];
    NSMutableAttributedString *inserted = [[NSMutableAttributedString alloc] initWithString:text attributes:attributes];
    [inserted addAttribute:SNRichEntityAttribute value:entity range:NSMakeRange(0, text.length)];
    [inserted appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:attributes]];
    if (![self replaceRange:range with:inserted]) return;
    self.selectedRange = NSMakeRange(range.location + inserted.length, 0);
}

- (NSString *)autocompleteQueryRange:(NSRangePointer)range {
    NSTextStorage *storage = self.textStorage;
    NSRange selection = self.selectedRange;
    if (selection.length || !storage.length) return nil;
    NSString *string = storage.string;
    NSRange paragraph = SNRichParagraphRange(string, selection.location);
    SNRichBlock *block = [storage attribute:SNRichBlockAttribute atIndex:MIN(paragraph.location, storage.length - 1) effectiveRange:NULL];
    if (block.kind == SNRichBlockCode) return nil;
    for (NSUInteger i = selection.location; i > paragraph.location; i--) {
        unichar c = [string characterAtIndex:i - 1];
        if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]) return nil;
        if ([storage attribute:SNRichEntityAttribute atIndex:i - 1 effectiveRange:NULL]) return nil;
        if (c != '@' && c != '#' && c != ':') continue;
        if (i - 1 > paragraph.location && ![NSCharacterSet.whitespaceCharacterSet characterIsMember:[string characterAtIndex:i - 2]] &&
            [string characterAtIndex:i - 2] != '(') {
            if (c == ':') return nil;
            continue;
        }
        if ([[storage attribute:SNRichStyleAttribute atIndex:i - 1 effectiveRange:NULL] unsignedIntegerValue] & SNInlineCode) return nil;
        NSRange found = NSMakeRange(i - 1, selection.location - i + 1);
        NSString *query = [string substringWithRange:found];
        // Emoji wait for two letters after the colon, like the web client.
        if (c == ':' && query.length < 3) return nil;
        if (range) *range = found;
        return query;
    }
    return nil;
}

#pragma mark Keys and focus

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.window.firstResponder != self) return [super performKeyEquivalent:event];
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(flags & NSEventModifierFlagCommand)) return [super performKeyEquivalent:event];
    BOOL shift = flags & NSEventModifierFlagShift, option = flags & NSEventModifierFlagOption;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    if (!shift && !option && [key isEqualToString:@"b"]) [self toggleStyle:SNInlineBold];
    else if (!shift && !option && [key isEqualToString:@"i"]) [self toggleStyle:SNInlineItalic];
    else if (!shift && !option && [key isEqualToString:@"u"]) [self toggleStyle:SNInlineUnderline];
    else if (shift && !option && [key isEqualToString:@"x"]) [self toggleStyle:SNInlineStrike];
    else if (shift && !option && [key isEqualToString:@"c"]) [self toggleStyle:SNInlineCode];
    else if (shift && option && event.keyCode == 8) [self toggleBlock:SNRichBlockCode];
    else if (shift && [key isEqualToString:@"u"]) [self beginLink];
    else if (shift && event.keyCode == kKey7) [self toggleBlock:SNRichBlockOrdered];
    else if (shift && event.keyCode == kKey8) [self toggleBlock:SNRichBlockBullet];
    else if (shift && event.keyCode == kKey9) [self toggleBlock:SNRichBlockQuote];
    else if (event.keyCode == kKeyReturn) return NO;
    else return [super performKeyEquivalent:event];
    return YES;
}

- (BOOL)becomeFirstResponder {
    if (![super becomeFirstResponder]) return NO;
    _focused = YES;
    [self.composerDelegate composerTextViewFocusDidChange:self];
    return YES;
}

- (BOOL)resignFirstResponder {
    if (![super resignFirstResponder]) return NO;
    _focused = NO;
    [self.composerDelegate composerTextViewFocusDidChange:self];
    return YES;
}

- (BOOL)isFocused { return _focused; }

#pragma mark Drawing

- (void)setPlaceholder:(NSString *)placeholder {
    _placeholder = [placeholder copy];
    self.needsDisplay = YES;
}

- (void)setPlaceholderLock:(BOOL)placeholderLock {
    _placeholderLock = placeholderLock;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    // Slack's text is antialiased without font smoothing, like SNLabel.
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    [super drawRect:dirtyRect];
}

- (void)drawViewBackgroundInRect:(NSRect)rect {
    [super drawViewBackgroundInRect:rect];
    if (self.isEmpty) [self drawPlaceholder];
    else [self drawDecorationsInRect:rect];
}

- (void)drawPlaceholder {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetShouldSmoothFonts(context, false);
    NSFont *font = BaseFont();
    NSRect line = NSMakeRect(0, self.textContainerOrigin.y, self.bounds.size.width, SNComposerLineHeight);
    NSString *text = self.placeholder;
    NSRange lastSpace = [text rangeOfString:@" " options:NSBackwardsSearch];
    if (!self.placeholderLock || lastSpace.location == NSNotFound) {
        SNDrawText(text, font, kPlaceholderColor, SNComposerLineHeight, NSTextAlignmentLeft, 1, line);
        return;
    }
    // "Enviar mensagem para 🔒name": the lock glyph stands where the channel's '#' would.
    NSString *prefix = [text substringToIndex:NSMaxRange(lastSpace)];
    CGFloat prefixWidth = [prefix sizeWithAttributes:@{NSFontAttributeName : font}].width;
    SNDrawText(prefix, font, kPlaceholderColor, SNComposerLineHeight, NSTextAlignmentLeft, 1, line);
    CGFloat lock = 13;
    SNDrawIcon(@"lock", lock, kPlaceholderColor, NSMakeRect(prefixWidth, NSMinY(line) + (SNComposerLineHeight - lock) / 2, lock, lock));
    CGFloat x = prefixWidth + lock + 2;
    SNDrawText([text substringFromIndex:NSMaxRange(lastSpace)], font, kPlaceholderColor, SNComposerLineHeight, NSTextAlignmentLeft, 1,
               NSMakeRect(x, NSMinY(line), MAX(0, line.size.width - x), SNComposerLineHeight));
}

/// The characters' bounds in the view (the container sits textContainerOrigin into it).
- (NSRect)rectForCharacters:(NSRange)range {
    NSRange glyphs = [self.layoutManager glyphRangeForCharacterRange:range actualCharacterRange:NULL];
    NSPoint origin = self.textContainerOrigin;
    return NSOffsetRect([self.layoutManager boundingRectForGlyphRange:glyphs inTextContainer:self.textContainer], origin.x, origin.y);
}

/// Whether the paragraph at `index` belongs with the one before: the same code block or quote,
/// or the same run of lists (whose numbers count on).
static BOOL Continues(SNRichBlock *previous, SNRichBlock *block) {
    if (block.isList) return previous.isList;
    return block && previous.kind == block.kind && (block.kind == SNRichBlockCode || block.kind == SNRichBlockQuote);
}

- (void)drawBox:(NSRect)box code:(BOOL)code {
    if (code) {
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:4 yRadius:4];
        [SNColor(kCodeFill) setFill];
        [path fill];
        [SNColor(kCodeRing) setStroke];
        [path stroke];
    } else {
        [SNColor(SNColorContentSec) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:box xRadius:kQuoteBar / 2 yRadius:kQuoteBar / 2] fill];
    }
}

/// Code blocks, quote bars, list markers, inline code boxes and mention chips under the text in
/// `dirty`. Boxes and bars are drawn whole and list numbers count from the list's start, so the
/// paragraphs drawn reach out to the blocks around the dirty ones.
- (void)drawDecorationsInRect:(NSRect)dirty {
    NSTextStorage *storage = self.textStorage;
    NSString *string = storage.string;
    NSLayoutManager *layout = self.layoutManager;
    NSPoint origin = self.textContainerOrigin;
    CGFloat width = self.textContainer.size.width;
    NSRange glyphs = [layout glyphRangeForBoundingRect:NSOffsetRect(dirty, -origin.x, -origin.y) inTextContainer:self.textContainer];
    NSRange shown = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
    if (shown.location >= string.length) return;
    shown = [string paragraphRangeForRange:NSMakeRange(shown.location, MIN(shown.length, string.length - shown.location))];
    NSUInteger start = shown.location, end = NSMaxRange(shown);
    while (start > 0) {
        NSUInteger previous = SNRichParagraphRange(string, start - 1).location;
        if (!Continues(BlockAt(storage, previous), BlockAt(storage, start))) break;
        start = previous;
    }
    while (end < string.length && Continues(BlockAt(storage, end - 1), BlockAt(storage, end)) && !BlockAt(storage, end).isList)
        end = NSMaxRange(SNRichParagraphRange(string, end));

    __block NSUInteger runStart = NSNotFound;
    __block SNRichBlockKind runKind = 0;
    void (^flush)(NSUInteger) = ^(NSUInteger runEnd) {
        if (runStart == NSNotFound) return;
        NSRect rect = [self rectForCharacters:NSMakeRange(runStart, runEnd - runStart)];
        if (runKind == SNRichBlockCode) [self drawBox:NSMakeRect(0, NSMinY(rect), width, NSHeight(rect)) code:YES];
        else [self drawBox:NSMakeRect(0, NSMinY(rect), kQuoteBar, NSHeight(rect)) code:NO];
        runStart = NSNotFound;
    };
    NSMutableDictionary<NSNumber *, NSNumber *> *numbers = [NSMutableDictionary new];
    [string enumerateSubstringsInRange:NSMakeRange(start, end - start) options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
                            usingBlock:^(NSString *substring, NSRange line, NSRange paragraph, BOOL *stop) {
        SNRichBlock *block = BlockAt(storage, paragraph.location);
        BOOL boxed = block.kind == SNRichBlockCode || block.kind == SNRichBlockQuote;
        if (runStart != NSNotFound && (!boxed || block.kind != runKind)) flush(paragraph.location);
        if (boxed && runStart == NSNotFound) runStart = paragraph.location, runKind = block.kind;
        if (!block.isList) {
            [numbers removeAllObjects];
            return;
        }
        for (NSNumber *indent in numbers.allKeys)
            if (indent.integerValue > block.indent) [numbers removeObjectForKey:indent];
        NSInteger number = numbers[@(block.indent)].integerValue + 1;
        numbers[@(block.indent)] = @(block.kind == SNRichBlockOrdered ? number : 0);
        if (paragraph.location < shown.location) return;
        NSRect rect = [self rectForCharacters:paragraph];
        NSArray *bullets = @[ @"•", @"◦", @"▪" ];
        NSString *marker = block.kind == SNRichBlockOrdered ? OrderedMarker(number, block.indent) : bullets[(NSUInteger)block.indent % 3];
        CGFloat x = kListIndent * (block.indent + 1) - kMarkerGap - kMarkerBox;
        SNDrawText(marker, BaseFont(), kTextColor, SNComposerLineHeight, NSTextAlignmentCenter, 1, NSMakeRect(x, NSMinY(rect), kMarkerBox, SNComposerLineHeight));
    }];
    flush(end);
    [storage enumerateAttributesInRange:shown options:0 usingBlock:^(NSDictionary *attributes, NSRange range, BOOL *stop) {
        SNRichEntity *entity = attributes[SNRichEntityAttribute];
        SNRichBlock *block = attributes[SNRichBlockAttribute];
        BOOL code = ([attributes[SNRichStyleAttribute] unsignedIntegerValue] & SNInlineCode) && block.kind != SNRichBlockCode;
        if (!code && (!entity || entity.kind == SNRichEntityEmoji)) return;
        NSRange glyphRange = [layout glyphRangeForCharacterRange:range actualCharacterRange:NULL];
        [layout enumerateEnclosingRectsForGlyphRange:glyphRange withinSelectedGlyphRange:NSMakeRange(NSNotFound, 0) inTextContainer:self.textContainer
                                          usingBlock:^(NSRect container, BOOL *stopRects) {
            NSRect rect = NSOffsetRect(container, origin.x, origin.y);
            if (code) {
                // padding 2px 3px 1px around 12 pt mono on an 18 pt line, centred on the 22.5 pt line.
                NSRect box = NSMakeRect(NSMinX(rect) - 3, NSMidY(rect) - 9 - 2 + 0.5, NSWidth(rect) + 6, 18 + 3);
                NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:3 yRadius:3];
                [SNColor(kCodeFill) setFill];
                [path fill];
                [SNColor(kCodeRing) setStroke];
                [path stroke];
            } else {
                NSRect chip = NSMakeRect(NSMinX(rect) - 2, NSMinY(rect) + 1.5, NSWidth(rect) + 4, NSHeight(rect) - 3);
                [SNColor(entity.kind == SNRichEntityBroadcast ? kBroadcastFill : kMentionFill) setFill];
                [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:2 yRadius:2] fill];
            }
        }];
    }];
}

@end
