// Owns the tooltip's delay, bubble and fade.
#import "ui/kit/label.h"
#import "ui/kit/tooltip.h"

static const CGFloat kPaddingX = 12, kPaddingY = 8, kRadius = 8, kMaxWidth = 200, kGap = 8;
/// Shortcut keys (a_tooltip_help): 20 pt black chips 4 pt under the text and 4 pt above the
/// padding, the key in 12 pt #f8f8f8 4.5 pt in, chips 4 pt apart.
static const CGFloat kChipHeight = 20, kChipMargin = 4, kChipPadding = 4.5, kChipGap = 4, kChipRadius = 4;

static NSFont *ChipFont(void) { return SNFont(SNFontSizeMicro, SNFontWeightRegular); }

static CGFloat ChipWidth(NSString *key) { return ceil(SNTextWidth(key, ChipFont())) + 2 * kChipPadding; }

/// The chips' row width, 0 without keys.
static CGFloat ChipsWidth(NSArray<NSString *> *keys) {
    CGFloat width = 0;
    for (NSString *key in keys) width += ChipWidth(key) + (width ? kChipGap : 0);
    return width;
}
/// The arrow is a 9 pt square turned 45° and centred on the bubble's edge, so half its diagonal
/// sticks out.
static const CGFloat kArrow = 9 * M_SQRT1_2;

@interface SNTooltipView : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSArray<NSString *> *keys;
@property (nonatomic) SNPlacement arrowSide;
@property (nonatomic) NSRect bubble;
/// Where the arrow points along the bubble's edge: the target's centre, even when the bubble
/// was pushed aside to stay in the window.
@property (nonatomic) CGFloat arrowCentre;
@end

@implementation SNTooltipView

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bubble = self.bubble;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bubble xRadius:kRadius yRadius:kRadius];
    NSPoint tip, left, right;
    CGFloat along = self.arrowCentre;
    switch (self.arrowSide) {
    case SNPlacementAbove: // the bubble is above its target: arrow on its bottom edge
        tip = NSMakePoint(along, NSMaxY(bubble) + kArrow), left = NSMakePoint(along - kArrow, NSMaxY(bubble));
        right = NSMakePoint(along + kArrow, NSMaxY(bubble));
        break;
    case SNPlacementBelow:
        tip = NSMakePoint(along, NSMinY(bubble) - kArrow), left = NSMakePoint(along - kArrow, NSMinY(bubble));
        right = NSMakePoint(along + kArrow, NSMinY(bubble));
        break;
    case SNPlacementLeft:
        tip = NSMakePoint(NSMaxX(bubble) + kArrow, along), left = NSMakePoint(NSMaxX(bubble), along - kArrow);
        right = NSMakePoint(NSMaxX(bubble), along + kArrow);
        break;
    case SNPlacementRight:
        tip = NSMakePoint(NSMinX(bubble) - kArrow, along), left = NSMakePoint(NSMinX(bubble), along - kArrow);
        right = NSMakePoint(NSMinX(bubble), along + kArrow);
        break;
    }
    [path moveToPoint:left];
    [path lineToPoint:tip];
    [path lineToPoint:right];
    [path closePath];
    // The border is the shape in the border colour under the shape 1 pt smaller in the fill, so
    // the arrow's base, inside the bubble, gets no line.
    [SNColor(SNMeasuredTooltipBorder) setFill];
    [path fill];
    NSBezierPath *inner = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bubble, 1, 1) xRadius:kRadius - 1 yRadius:kRadius - 1];
    NSPoint inward = NSMakePoint((NSMidX(bubble) > tip.x) - (NSMidX(bubble) < tip.x), (NSMidY(bubble) > tip.y) - (NSMidY(bubble) < tip.y));
    if (self.arrowSide == SNPlacementAbove || self.arrowSide == SNPlacementBelow) inward.x = 0;
    else inward.y = 0;
    [inner moveToPoint:NSMakePoint(left.x + inward.x * 2, left.y + inward.y * 2)];
    [inner lineToPoint:NSMakePoint(tip.x + inward.x * M_SQRT2, tip.y + inward.y * M_SQRT2)];
    [inner lineToPoint:NSMakePoint(right.x + inward.x * 2, right.y + inward.y * 2)];
    [inner closePath];
    [SNColor(SNColorCtrPry) setFill];
    [inner fill];
    NSRect content = NSInsetRect(bubble, kPaddingX, kPaddingY);
    if (self.keys.count) content.size.height -= kChipMargin + kChipHeight + kChipMargin;
    SNDrawText(self.text, SNFont(SNFontSizeCaption, SNFontWeightBold), SNColorContentPry, SNFontSizeCaption * SNLeadingSmall,
               NSTextAlignmentCenter, 0, content);
    CGFloat x = NSMidX(bubble) - ChipsWidth(self.keys) / 2, y = NSMaxY(content) + kChipMargin;
    for (NSString *key in self.keys) {
        NSRect chip = NSMakeRect(x, y, ChipWidth(key), kChipHeight);
        [NSColor.blackColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:kChipRadius yRadius:kChipRadius] fill];
        SNDrawText(key, ChipFont(), SNColorContentPry, kChipHeight, NSTextAlignmentCenter, 1, chip);
        x += NSWidth(chip) + kChipGap;
    }
}

@end

@implementation SNTooltip

static SNTooltipView *visible;
static NSUInteger generation;

+ (void)showText:(NSString *)text forRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement delay:(NSTimeInterval)delay {
    [self showText:text shortcut:nil forRect:rect inView:view placement:placement delay:delay];
}

+ (void)showText:(NSString *)text shortcut:(NSString *)shortcut forRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement delay:(NSTimeInterval)delay {
    [self hide];
    NSUInteger shown = ++generation;
    NSArray<NSString *> *keys = [shortcut componentsSeparatedByString:@" "] ?: @[];
    void (^show)(void) = ^{
        if (shown != generation || !view.window) return;
        [self present:text keys:keys forRect:rect inView:view placement:placement];
    };
    if (delay <= 0) show();
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), show);
}

+ (void)present:(NSString *)text keys:(NSArray<NSString *> *)keys forRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement {
    SNOverlayHost *host = [SNOverlayHost hostForWindow:view.window];
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    CGFloat lineHeight = SNFontSizeCaption * SNLeadingSmall, textWidth = kMaxWidth - 2 * kPaddingX;
    CGFloat width = MIN(MAX(ceil(SNTextWidth(text, font)), ChipsWidth(keys)), textWidth);
    NSUInteger lines = MAX(1, SNLineCount(text, font, textWidth, 0));
    CGFloat chips = keys.count ? kChipMargin + kChipHeight + kChipMargin : 0;
    NSSize bubbleSize = NSMakeSize(width + 2 * kPaddingX, ceil(lines * lineHeight) + chips + 2 * kPaddingY);
    NSRect target = [host convertRect:rect fromView:view];
    // Like the web client's, the bubble keeps 8 pt from the window's edges (a_tooltip_help).
    NSRect bubble = SNPlaceOverlay(bubbleSize, target, placement, kGap, YES, NSInsetRect(host.bounds, kGap, kGap));
    SNPlacement side = SNPlacementOf(bubble, target);

    SNTooltipView *tooltip = [[SNTooltipView alloc] initWithFrame:NSInsetRect(bubble, -ceil(kArrow), -ceil(kArrow))];
    tooltip.wantsLayer = YES;
    tooltip.text = text;
    tooltip.keys = keys;
    tooltip.arrowSide = side;
    tooltip.bubble = NSOffsetRect(bubble, -NSMinX(tooltip.frame), -NSMinY(tooltip.frame));
    BOOL vertical = side == SNPlacementAbove || side == SNPlacementBelow;
    CGFloat centre = vertical ? NSMidX(target) - NSMinX(tooltip.frame) : NSMidY(target) - NSMinY(tooltip.frame);
    CGFloat low = (vertical ? NSMinX(tooltip.bubble) : NSMinY(tooltip.bubble)) + kRadius + kArrow;
    CGFloat high = (vertical ? NSMaxX(tooltip.bubble) : NSMaxY(tooltip.bubble)) - kRadius - kArrow;
    tooltip.arrowCentre = MAX(low, MIN(high, centre));
    [host addSubview:tooltip];
    visible = tooltip;
    tooltip.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = SNLiveTooltipFadeIn;
        context.timingFunction = SNEaseLiveTooltipFadeIn();
        tooltip.animator.alphaValue = 1;
    }];
}

+ (void)hide {
    generation++;
    SNTooltipView *tooltip = visible;
    visible = nil;
    [tooltip removeFromSuperview];
}

@end
