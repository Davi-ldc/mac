// Owns drawing the "also send to the conversation" checkbox.
#import "ui/composer/broadcast.h"
#import "ui/kit/label.h"

/// A 14 pt box with 3 pt corners 2 pt down the 18 pt line, the label 8 pt after it in 13 pt.
static const CGFloat kBox = 14, kBoxTop = 2, kLabelGap = 8, kLine = 18;

@implementation SNComposerBroadcastToggle

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    __weak SNComposerBroadcastToggle *weakSelf = self;
    self.action = ^(SNComposerBroadcastToggle *toggle) { weakSelf.checked = !weakSelf.checked; };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setLabel:(NSString *)label {
    if ([label isEqualToString:_label]) return;
    _label = [label copy];
    self.needsDisplay = YES;
}

- (void)setChecked:(BOOL)checked {
    if (checked == _checked) return;
    _checked = checked;
    self.needsDisplay = YES;
}

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = NSMakeRect(0.5, kBoxTop + 0.5, kBox - 1, kBox - 1);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3];
    if (self.checked) {
        [SNColor(SNColorContentHgl1) setFill];
        [outline fill];
        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:NSMakePoint(3.5, kBoxTop + 7)];
        [tick lineToPoint:NSMakePoint(6, kBoxTop + 9.5)];
        [tick lineToPoint:NSMakePoint(10.5, kBoxTop + 4.5)];
        tick.lineWidth = 1.75;
        tick.lineCapStyle = NSLineCapStyleRound;
        tick.lineJoinStyle = NSLineJoinStyleRound;
        [SNColor(SNColorBasePry) setStroke];
        [tick stroke];
    } else {
        [SNColor(self.hovered ? SNColorContentSec : SNColorContentTer) setStroke];
        [outline stroke];
    }
    SNDrawText(self.label ?: @"", SNFont(SNFontSizeCaption, SNFontWeightRegular), SNColorContentSec, kLine, NSTextAlignmentLeft, 1,
               NSMakeRect(kBox + kLabelGap, 0, MAX(0, self.bounds.size.width - kBox - kLabelGap), kLine));
}

@end
