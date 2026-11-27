// Owns line breaking, truncation and drawing of plain text.
#import <CoreText/CoreText.h>

#import "ui/kit/label.h"

static const unichar kSoftHyphen = 0x00AD;

static NSAttributedString *Styled(NSString *text, NSFont *font, SNColorToken color) {
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName : font,
        (__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)SNCGColor(color),
    }];
}

static CGFloat LineHeight(NSFont *font, CGFloat lineHeight) {
    return lineHeight > 0 ? lineHeight : round(font.ascender) + round(-font.descender);
}

/// CTLines for the text at `width`; the last allowed line ends in an ellipsis when text is left.
static NSArray *Lines(NSString *text, NSFont *font, SNColorToken color, CGFloat width, NSUInteger maximumLines) {
    NSAttributedString *styled = Styled(text, font, color);
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)styled);
    NSMutableArray *lines = [NSMutableArray new];
    CFIndex start = 0, length = (CFIndex)text.length;
    while (start < length) {
        BOOL last = maximumLines && lines.count + 1 == maximumLines;
        CFIndex count = last ? length - start : CTTypesetterSuggestLineBreak(typesetter, start, width);
        if (count <= 0) count = 1;
        NSString *part = [text substringWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)count)];
        if (!last && start + count < length && [part characterAtIndex:part.length - 1] == kSoftHyphen)
            part = [[part substringToIndex:part.length - 1] stringByAppendingString:@"-"];
        part = [part stringByReplacingOccurrencesOfString:[NSString stringWithCharacters:&kSoftHyphen length:1] withString:@""];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)Styled(part, font, color));
        if (last && CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line) > width) {
            CTLineRef ellipsis = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)Styled(@"…", font, color));
            CTLineRef truncated = CTLineCreateTruncatedLine(line, width, kCTLineTruncationEnd, ellipsis);
            CFRelease(ellipsis);
            if (truncated) {
                CFRelease(line);
                line = truncated;
            }
        }
        [lines addObject:CFBridgingRelease(line)];
        start += count;
        if (last) break;
    }
    CFRelease(typesetter);
    return lines;
}

CGFloat SNTextWidth(NSString *text, NSFont *font) {
    if (!text.length || !font) return 0;
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)Styled(text, font, 0));
    CGFloat width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return width;
}

NSUInteger SNLineCount(NSString *text, NSFont *font, CGFloat width, NSUInteger maximumLines) {
    return Lines(text, font, 0, width, maximumLines).count;
}

/// The widest line `text` breaks into at `width`, or 0 when a word has to be split to fit.
static CGFloat WidestLine(NSString *text, NSFont *font, CGFloat width, NSUInteger *count) {
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)Styled(text, font, 0));
    NSCharacterSet *letters = NSCharacterSet.alphanumericCharacterSet;
    CGFloat widest = 0;
    CFIndex start = 0, length = (CFIndex)text.length;
    *count = 0;
    while (start < length) {
        CFIndex used = MAX(1, CTTypesetterSuggestLineBreak(typesetter, start, width));
        CFIndex end = start + used;
        if (end < length && [letters characterIsMember:[text characterAtIndex:(NSUInteger)end - 1]] &&
            [letters characterIsMember:[text characterAtIndex:(NSUInteger)end]]) {
            widest = 0;
            break;
        }
        CTLineRef line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, used));
        widest = MAX(widest, CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line));
        CFRelease(line);
        (*count)++;
        start = end;
    }
    CFRelease(typesetter);
    return widest;
}

CGFloat SNBalancedWidth(NSString *text, NSFont *font, CGFloat width) {
    // Narrows the box to just under its widest line for as long as the text keeps its line count
    // without splitting a word, as CSS text-wrap: balance does.
    NSUInteger lines = 0, count = 0;
    CGFloat widest = WidestLine(text, font, width, &lines), best = width;
    while (lines > 1 && widest > 1) {
        CGFloat narrower = widest - 0.5, next = WidestLine(text, font, narrower, &count);
        if (count != lines || next <= 0) break;
        best = narrower;
        widest = next;
    }
    return best;
}

void SNDrawText(NSString *text, NSFont *font, SNColorToken color, CGFloat lineHeight, NSTextAlignment alignment,
                NSUInteger maximumLines, NSRect rect) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextSetShouldSmoothFonts(context, false);
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
    CGFloat height = LineHeight(font, lineHeight), baseline = SNBaselineOffset(font, height);
    CGFloat top = NSMinY(rect);
    for (id object in Lines(text, font, color, rect.size.width, maximumLines)) {
        CTLineRef line = (__bridge CTLineRef)object;
        CGFloat width = CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line);
        CGFloat x = alignment == NSTextAlignmentCenter  ? NSMinX(rect) + (rect.size.width - width) / 2
                    : alignment == NSTextAlignmentRight ? NSMaxX(rect) - width
                                                        : NSMinX(rect);
        // Browsers put each baseline on a whole device pixel.
        CGPoint origin = CGContextConvertPointToDeviceSpace(context, CGPointMake(x, top + baseline));
        origin = CGContextConvertPointToUserSpace(context, CGPointMake(origin.x, round(origin.y)));
        CGContextSetTextPosition(context, origin.x, origin.y);
        CTLineDraw(line, context);
        top += height;
    }
    CGContextRestoreGState(context);
}

@implementation SNLabel

+ (instancetype)labelWithText:(NSString *)text font:(NSFont *)font color:(SNColorToken)color {
    SNLabel *label = [self new];
    label.text = text;
    label.font = font;
    label.color = color;
    return label;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _text = @"";
    _font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    _color = SNColorContentPry;
    _alignment = NSTextAlignmentLeft;
    _maximumLines = 1;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setText:(NSString *)text {
    if ([text isEqualToString:_text]) return;
    _text = [text copy];
    [self invalidate];
}

- (void)setFont:(NSFont *)font {
    _font = font;
    [self invalidate];
}

- (void)setColor:(SNColorToken)color {
    if (color == _color) return;
    _color = color;
    self.needsDisplay = YES;
}

- (void)setLineHeight:(CGFloat)lineHeight {
    _lineHeight = lineHeight;
    [self invalidate];
}

- (void)setAlignment:(NSTextAlignment)alignment {
    _alignment = alignment;
    self.needsDisplay = YES;
}

- (void)setMaximumLines:(NSUInteger)maximumLines {
    _maximumLines = maximumLines;
    [self invalidate];
}

- (void)invalidate {
    self.needsDisplay = YES;
    [self invalidateIntrinsicContentSize];
}

- (CGFloat)textWidth { return SNTextWidth(self.text, self.font); }

- (CGFloat)heightForWidth:(CGFloat)width {
    return LineHeight(self.font, self.lineHeight) * MAX(1, SNLineCount(self.text, self.font, width, self.maximumLines));
}

- (NSSize)intrinsicContentSize { return NSMakeSize(ceil(self.textWidth), LineHeight(self.font, self.lineHeight)); }

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)setBalanced:(BOOL)balanced {
    _balanced = balanced;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect = self.bounds;
    if (self.balanced) {
        CGFloat width = SNBalancedWidth(self.text, self.font, rect.size.width);
        CGFloat x = self.alignment == NSTextAlignmentCenter ? (rect.size.width - width) / 2 : self.alignment == NSTextAlignmentRight ? rect.size.width - width : 0;
        rect = NSMakeRect(x, 0, width, rect.size.height);
    }
    SNDrawText(self.text, self.font, self.color, self.lineHeight, self.alignment, self.maximumLines, rect);
}

@end
