// Owns drawing shortcut chips.
#import "keycaps.h"
#import "theme.h"

static const CGFloat kCapSize = 18, kCapPadding = 4, kCapGap = 2, kCapRadius = 5;

static NSDictionary *GlyphAttributes(void) {
    return @{NSFontAttributeName : DKFont(10, 500), NSForegroundColorAttributeName : DKTextSecondary()};
}

static CGFloat CapWidth(NSString *glyph) {
    return MAX(kCapSize, ceil([glyph sizeWithAttributes:GlyphAttributes()].width) + 2 * kCapPadding);
}

CGFloat DKKeycapsWidth(DKShortcut *shortcut) {
    CGFloat width = 0;
    for (NSString *glyph in shortcut.keycaps) width += CapWidth(glyph) + kCapGap;
    return width ? width - kCapGap : 0;
}

void DKDrawKeycaps(DKShortcut *shortcut, CGFloat x, CGFloat centerY) {
    CGFloat y = centerY - kCapSize / 2;
    for (NSString *glyph in shortcut.keycaps) {
        CGFloat width = CapWidth(glyph);
        NSRect cap = NSMakeRect(x + 0.5, y + 0.5, width - 1, kCapSize - 1);
        NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:cap xRadius:kCapRadius yRadius:kCapRadius];
        [DKWhite(0.2) setStroke];
        [outline stroke];
        NSSize size = [glyph sizeWithAttributes:GlyphAttributes()];
        [glyph drawAtPoint:NSMakePoint(x + (width - size.width) / 2, y + (kCapSize - size.height) / 2)
            withAttributes:GlyphAttributes()];
        x += width + kCapGap;
    }
}

@implementation DKKeycaps

- (instancetype)initWithShortcut:(DKShortcut *)shortcut {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _shortcut = shortcut;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setShortcut:(DKShortcut *)shortcut {
    _shortcut = shortcut;
    self.needsDisplay = YES;
}

- (CGFloat)width { return DKKeycapsWidth(_shortcut); }

- (void)drawRect:(NSRect)dirty {
    DKDrawKeycaps(_shortcut, 0, self.bounds.size.height / 2);
}

@end
