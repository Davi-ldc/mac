// Owns drawing the drag overlay.
#import "render/strings.h"
#import "ui/composer/drop.h"
#import "ui/kit/label.h"

/// Title 28/900 at line-height 1.25 and 8 pt over the hint (15/1.5); the thread's has 50 pt sides.
static const CGFloat kTitleLine = 35, kTitleGap = 8, kHintLine = 22.5, kSide = 16, kThreadSide = 50;
/// The Shift chip: 20 pt, 13 pt text, 4 pt corners on base-ter with an otl-ter bottom edge.
static const CGFloat kChip = 20, kChipPadding = 4, kChipGap = 2;
static const CFTimeInterval kFade = 0.12;

@implementation SNComposerDropOverlay {
    BOOL _thread;
}

- (instancetype)initWithTitle:(NSString *)title hint:(NSString *)hint thread:(BOOL)thread {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _title = [title copy];
    _hint = [hint copy];
    _thread = thread;
    self.wantsLayer = YES;
    self.layer.backgroundColor = SNCGColor(SNColorWithAlpha(SNLegacyPrimaryBackground, 0.95));
    if (!thread) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0;
        fade.duration = kFade;
        [self.layer addAnimation:fade forKey:@"fade"];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

// The drop goes to the pane under it.
- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    NSRect bounds = self.bounds;
    CGFloat side = _thread ? kThreadSide : kSide, width = MAX(0, NSWidth(bounds) - 2 * side);
    CGFloat top = round((NSHeight(bounds) - kTitleLine - kTitleGap - kHintLine) / 2);
    SNDrawText(self.title, SNFont(SNFontSizeHeadline, SNFontWeightBlack), SNColorContentPry, kTitleLine, NSTextAlignmentCenter, 1,
               NSMakeRect(side, top, width, kTitleLine));
    NSArray<NSString *> *parts = [self.hint componentsSeparatedByString:@"%@"];
    NSString *before = parts.firstObject ?: @"", *after = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@""] : @"";
    NSFont *font = SNFont(SNFontSizeBase, SNFontWeightRegular), *chipFont = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    NSString *key = SNLocalized(@"composer.drop.shift");
    CGFloat beforeWidth = ceil([before sizeWithAttributes:@{NSFontAttributeName : font}].width);
    CGFloat afterWidth = ceil([after sizeWithAttributes:@{NSFontAttributeName : font}].width);
    CGFloat chipWidth = ceil([key sizeWithAttributes:@{NSFontAttributeName : chipFont}].width) + 2 * kChipPadding;
    CGFloat line = MIN(width, beforeWidth + kChipGap + chipWidth + kChipGap + afterWidth);
    CGFloat x = NSMinX(bounds) + side + (width - line) / 2, y = top + kTitleLine + kTitleGap;
    SNColorToken color = _thread ? SNLegacyForegroundMaxSolid : SNColorContentSec;
    SNDrawText(before, font, color, kHintLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, beforeWidth, kHintLine));
    x += beforeWidth + kChipGap;
    NSRect chip = NSMakeRect(x, y + (kHintLine - kChip) / 2, chipWidth, kChip);
    [SNColor(SNColorOtlTer) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:4 yRadius:4] fill];
    [SNColor(SNColorBaseTer) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(chip), NSMinY(chip), NSWidth(chip), kChip - 1) xRadius:4 yRadius:4] fill];
    SNDrawText(key, chipFont, SNColorContentPry, kChip - 1, NSTextAlignmentCenter, 1, NSMakeRect(NSMinX(chip), NSMinY(chip), NSWidth(chip), kChip - 1));
    x += chipWidth + kChipGap;
    SNDrawText(after, font, color, kHintLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, MAX(0, NSMinX(bounds) + side + width - x), kHintLine));
}

@end
