// Owns drawing the calculator card. The measures are Raycast's (its split-command-item and
// token styles): 12 points of padding, blocks 8 points from the divider, values in Inter 24
// semibold over 20-point labels, and an arrow at the middle of three equal parts.
#import "calculatorcard.h"
#import "drawnview.h"
#import "theme.h"

static const CGFloat kPadding = 12, kGap = 8, kValueBottom = 88, kLabelTop = 92, kLabelHeight = 20;
static const CGFloat kLabelPadding = 8, kLabelRadius = 6, kArrowSize = 16;

/// Draws the card on the CPU (see DKDrawnView); the cell around it only holds it.
@interface DKCalculatorDrawing : DKDrawnView
@property(strong) DKCalculation *calculation;
@property(copy) NSString *note;
@property(nonatomic) BOOL selected;
@end

@implementation DKCalculatorDrawing

- (BOOL)isFlipped { return YES; }

- (void)setSelected:(BOOL)selected {
    if (_selected == selected) return;
    _selected = selected;
    self.needsDisplay = YES;
}

static NSDictionary *TextStyle(CGFloat size, CGFloat weight, NSColor *color, NSLineBreakMode lineBreak) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = lineBreak;
    return @{NSFontAttributeName : DKFont(size, weight), NSForegroundColorAttributeName : color, NSParagraphStyleAttributeName : paragraph,
             NSKernAttributeName : @(DKTracking(size, weight))};
}

/// One line centred on `centerY` within `width` from `x`, cut short as `text`'s style says.
static void DrawLine(NSAttributedString *text, CGFloat x, CGFloat width, CGFloat centerY) {
    NSFont *font = [text attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    CGFloat height = font.ascender - font.descender;
    [text drawWithRect:NSMakeRect(x, centerY - height / 2, width, height)
               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
}

/// The small rounded label under a value: as wide as its text, at most the block's width.
static void DrawLabel(NSString *label, CGFloat x, CGFloat width, NSLineBreakMode lineBreak) {
    NSDictionary *style = TextStyle(11, 400, DKTextPrimary(), lineBreak);
    CGFloat textWidth = MIN([label sizeWithAttributes:style].width, width - 2 * kLabelPadding);
    NSRect pill = NSMakeRect(x + (width - textWidth) / 2 - kLabelPadding, kLabelTop, textWidth + 2 * kLabelPadding, kLabelHeight);
    [DKWhite(0.1) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:kLabelRadius yRadius:kLabelRadius] fill];
    // Inter sits half a point low in its line box against where Raycast places it.
    DrawLine([[NSAttributedString alloc] initWithString:label attributes:style], NSMinX(pill) + kLabelPadding, textWidth,
             NSMidY(pill) - 0.5);
}

/// Raycast's arrow-right icon, a 16-point stroke drawing, with `origin` its top left.
static void DrawArrow(NSPoint origin, NSColor *color) {
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 1.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;
    [arrow moveToPoint:NSMakePoint(origin.x + 2.75, origin.y + 8)];
    [arrow lineToPoint:NSMakePoint(origin.x + 12.75, origin.y + 8)];
    [arrow moveToPoint:NSMakePoint(origin.x + 9.75, origin.y + 4.75)];
    [arrow lineToPoint:NSMakePoint(origin.x + 13.25, origin.y + 8)];
    [arrow lineToPoint:NSMakePoint(origin.x + 9.75, origin.y + 11.25)];
    [color setStroke];
    [arrow stroke];
}

- (void)drawRect:(NSRect)dirty {
    DKCalculation *calculation = _calculation;
    if (!calculation) return;
    NSRect card = NSInsetRect(self.bounds, DKInset, 0);
    CGFloat height = card.size.height, left = NSMinX(card) + kPadding;
    NSDictionary *noteStyle = TextStyle(11, 400, DKTextTertiary(), NSLineBreakByClipping);
    CGFloat noteWidth = _note.length ? ceil([_note sizeWithAttributes:noteStyle].width) : 0;
    CGFloat dividerWidth = MAX(kArrowSize + 8, noteWidth);
    CGFloat blockWidth = (card.size.width - 2 * kPadding - 2 * kGap - dividerWidth) / 2;
    CGFloat dividerX = left + blockWidth + kGap, rightX = dividerX + dividerWidth + kGap;
    CGFloat valueCenter = kPadding + (kValueBottom - kPadding) / 2;

    // The expression is dim but for its numbers, units and the like.
    NSMutableAttributedString *expression = [[NSMutableAttributedString alloc]
        initWithString:calculation.expression attributes:TextStyle(24, 600, DKTextTertiary(), NSLineBreakByTruncatingTail)];
    for (NSValue *range in calculation.highlights)
        if (NSMaxRange(range.rangeValue) <= expression.length)
            [expression addAttribute:NSForegroundColorAttributeName value:DKTextPrimary() range:range.rangeValue];
    DrawLine(expression, left, blockWidth, valueCenter);
    DrawLabel(calculation.expressionLabel, left, blockWidth, NSLineBreakByTruncatingTail);

    NSAttributedString *answer = [[NSAttributedString alloc]
        initWithString:calculation.answer attributes:TextStyle(24, 600, DKTextPrimary(), NSLineBreakByTruncatingTail)];
    DrawLine(answer, rightX, blockWidth, valueCenter);
    // Raycast shortens long words in the middle, keeping how the number starts and ends.
    DrawLabel(calculation.answerLabel, rightX, blockWidth, NSLineBreakByTruncatingMiddle);

    // The divider: a line, the arrow (and the note), a line, in three equal parts.
    CGFloat third = height / 3, middle = dividerX + dividerWidth / 2;
    [DKWhite(_selected ? 0.1 : 0.05) setFill];
    NSRectFill(NSMakeRect(middle - 0.5, 0, 1, third));
    NSRectFill(NSMakeRect(middle - 0.5, 2 * third, 1, height - 2 * third));
    CGFloat noteHeight = _note.length ? DKFont(11, 400).ascender - DKFont(11, 400).descender : 0;
    CGFloat top = height / 2 - (kArrowSize + noteHeight) / 2;
    DrawArrow(NSMakePoint(middle - kArrowSize / 2, top), _selected ? DKTextPrimary() : DKTextSecondary());
    if (_note.length)
        DrawLine([[NSAttributedString alloc] initWithString:_note attributes:noteStyle], dividerX, dividerWidth,
                 top + kArrowSize + noteHeight / 2);
}

@end

@implementation DKCalculatorCard {
    DKCalculatorDrawing *_drawing;
}

- (instancetype)init {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _drawing = [[DKCalculatorDrawing alloc] initWithFrame:NSZeroRect];
    _drawing.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_drawing];
    return self;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    _drawing.frame = self.bounds;
}

- (void)showCalculation:(DKCalculation *)calculation note:(NSString *)note {
    if (_drawing.calculation == calculation && [_drawing.note isEqualToString:note ?: @""]) return;
    _drawing.calculation = calculation;
    _drawing.note = note ?: @"";
    _drawing.needsDisplay = YES;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    _drawing.selected = selected;
}

- (BOOL)isFlipped { return YES; }

@end
