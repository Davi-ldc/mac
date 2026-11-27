// Owns the reaction pills and their tooltip.
#import "render/document.h"
#import "render/emoji.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/channel/reaction.h"
#import "ui/kit/label.h"
#import "ui/kit/tooltip.h"

/// The reaction tooltip (components.json reaction_tooltip): the tooltip's bubble around a 64 pt
/// emoji on a white tile padded 4 pt, and the names line in 13 pt.
static const CGFloat kTile = 72, kTipWidth = 180, kTipPadX = 12, kTipPadY = 8, kTipGap = 8, kTipRadius = 8;
static const CGFloat kArrow = 9 * M_SQRT1_2;

NSString *SNReactionTooltipText(SNReaction *reaction, id<SNSource> source) {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    BOOL me = NO;
    for (NSString *userID in reaction.userIDs) {
        if ([userID isEqualToString:source.me.userID]) me = YES;
        else [names addObject:[source userWithID:userID].visibleName ?: userID];
    }
    if (me) [names insertObject:SNLocalized(@"channel.reaction.you") atIndex:0];
    NSInteger others = reaction.count - (NSInteger)reaction.userIDs.count;
    if (others > 0) [names addObject:SNLocalizedFormat(@"channel.reaction.others", @(others).stringValue)];
    NSString *who = names.lastObject ?: @"";
    if (names.count > 1)
        who = [NSString stringWithFormat:@"%@%@%@", [[names subarrayWithRange:NSMakeRange(0, names.count - 1)] componentsJoinedByString:@", "],
                                         SNLocalized(@"channel.reaction.and"), names.lastObject];
    BOOL plural = names.count > 1 || others > 0;
    return SNLocalizedFormat(plural ? @"channel.reaction.other" : @"channel.reaction.one", who, [NSString stringWithFormat:@":%@:", SNEmojiBaseName(reaction.name)]);
}

#pragma mark Tooltip

@interface SNReactionTip : NSView
@property (nonatomic, copy) NSString *emoji, *text;
@property (nonatomic) SNPlacement arrowSide;
@property (nonatomic) NSRect bubble;
@property (nonatomic) CGFloat arrowCentre;
@end

@implementation SNReactionTip

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

+ (CGFloat)textHeight:(NSString *)text {
    return SNLineCount(text, SNFont(SNFontSizeCaption, SNFontWeightBold), kTipWidth - 2 * kTipPadX, 0) * SNFontSizeCaption * SNLeadingSmall;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bubble = self.bubble;
    BOOL below = self.arrowSide == SNPlacementBelow;
    NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:bubble xRadius:kTipRadius yRadius:kTipRadius];
    if (below) {
        [outer moveToPoint:NSMakePoint(self.arrowCentre - kArrow, NSMinY(bubble))];
        [outer lineToPoint:NSMakePoint(self.arrowCentre, NSMinY(bubble) - kArrow)];
        [outer lineToPoint:NSMakePoint(self.arrowCentre + kArrow, NSMinY(bubble))];
    } else {
        [outer moveToPoint:NSMakePoint(self.arrowCentre - kArrow, NSMaxY(bubble))];
        [outer lineToPoint:NSMakePoint(self.arrowCentre, NSMaxY(bubble) + kArrow)];
        [outer lineToPoint:NSMakePoint(self.arrowCentre + kArrow, NSMaxY(bubble))];
    }
    [SNColor(SNMeasuredTooltipBorder) setFill];
    [outer fill];
    NSBezierPath *inner = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bubble, 1, 1) xRadius:kTipRadius - 1 yRadius:kTipRadius - 1];
    if (below) {
        [inner moveToPoint:NSMakePoint(self.arrowCentre - kArrow + 2, NSMinY(bubble) + 1)];
        [inner lineToPoint:NSMakePoint(self.arrowCentre, NSMinY(bubble) - kArrow + M_SQRT2)];
        [inner lineToPoint:NSMakePoint(self.arrowCentre + kArrow - 2, NSMinY(bubble) + 1)];
    } else {
        [inner moveToPoint:NSMakePoint(self.arrowCentre - kArrow + 2, NSMaxY(bubble) - 1)];
        [inner lineToPoint:NSMakePoint(self.arrowCentre, NSMaxY(bubble) + kArrow - M_SQRT2)];
        [inner lineToPoint:NSMakePoint(self.arrowCentre + kArrow - 2, NSMaxY(bubble) - 1)];
    }
    [SNColor(SNColorCtrPry) setFill];
    [inner fill];
    NSRect tile = NSMakeRect(NSMidX(bubble) - kTile / 2, NSMinY(bubble) + kTipPadY, kTile, kTile);
    [SNColor(0xffffffff) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:tile xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
    SNDrawEmoji(self.emoji, 64, tile, self.imageHolder);
    SNDrawText(self.text, SNFont(SNFontSizeCaption, SNFontWeightBold), SNColorContentPry, SNFontSizeCaption * SNLeadingSmall, NSTextAlignmentCenter, 0,
               NSMakeRect(NSMinX(bubble) + kTipPadX, NSMaxY(tile) + 4, bubble.size.width - 2 * kTipPadX, bubble.size.height));
}

@end

static SNReactionTip *visibleTip;
static NSUInteger tipGeneration;

static void HideTip(void) {
    tipGeneration++;
    [visibleTip removeFromSuperview];
    visibleTip = nil;
}

static void ShowTip(NSString *emoji, NSString *text, NSView *view) {
    HideTip();
    [SNTooltip hide];
    NSUInteger due = ++tipGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLiveReactionTooltipDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (due != tipGeneration || !view.window) return;
        SNOverlayHost *host = [SNOverlayHost hostForWindow:view.window];
        NSRect target = [host convertRect:view.bounds fromView:view];
        NSSize size = NSMakeSize(kTipWidth, kTipPadY + kTile + 4 + [SNReactionTip textHeight:text] + kTipPadY);
        NSRect bubble = SNPlaceOverlay(size, target, SNPlacementAbove, kTipGap, YES, NSInsetRect(host.bounds, kTipGap, kTipGap));
        SNReactionTip *tip = [[SNReactionTip alloc] initWithFrame:NSInsetRect(bubble, -ceil(kArrow), -ceil(kArrow))];
        tip.wantsLayer = YES;
        tip.emoji = emoji;
        tip.text = text;
        tip.arrowSide = SNPlacementOf(bubble, target);
        tip.bubble = NSOffsetRect(bubble, -NSMinX(tip.frame), -NSMinY(tip.frame));
        tip.arrowCentre = MAX(NSMinX(tip.bubble) + kTipRadius + kArrow, MIN(NSMaxX(tip.bubble) - kTipRadius - kArrow, NSMidX(target) - NSMinX(tip.frame)));
        [host addSubview:tip];
        visibleTip = tip;
        tip.alphaValue = 0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = SNLiveTooltipFadeIn;
            context.timingFunction = SNEaseLiveTooltipFadeIn();
            tip.animator.alphaValue = 1;
        }];
    });
}

#pragma mark Pill

@implementation SNReactionPill {
    id<SNSource> _source;
}

- (instancetype)initWithReaction:(SNReaction *)reaction source:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _reaction = reaction;
    _source = source;
    _mine = reaction && [reaction.userIDs containsObject:source.me.userID ?: @""];
    self.hoverColor = self.pressedColor = 0;
    self.transitionDuration = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    if (!reaction) self.tooltip = SNLocalized(@"channel.reaction.add");
    return self;
}

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
    if (!self.reaction) return;
    if (self.hovered && !self.pressed) ShowTip(self.reaction.name, SNReactionTooltipText(self.reaction, _source), self);
    else HideTip();
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window && self.reaction) HideTip();
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    NSRect bounds = self.bounds;
    if (self.pressed) {
        CGContextTranslateCTM(context, NSMidX(bounds), NSMidY(bounds));
        CGContextScaleCTM(context, 0.94, 0.94);
        CGContextTranslateCTM(context, -NSMidX(bounds), -NSMidY(bounds));
    }
    CGFloat radius = bounds.size.height / 2;
    BOOL ring = self.hovered && !self.mine;
    SNColorToken fill = self.mine ? SNColorBaseInvHgl1 : ring ? 0 : SNColorSurfPry;
    if (fill) {
        [SNColor(fill) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius] fill];
    }
    if (ring) {
        [SNColor(SNMeasuredReactionHoverRing) setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:radius - 0.5 yRadius:radius - 0.5];
        path.lineWidth = 1;
        [path stroke];
    }
    if (!self.reaction) {
        SNColorToken color = self.hovered ? SNColorContentPry : SNColorContentTer;
        // The pill's font size is 18 px, and its face is 1em.
        SNDrawIcon(@"reaction-add", 18, color, bounds);
        return;
    }
    SNDrawEmoji(self.reaction.name, 16, NSMakeRect(8, (bounds.size.height - 16) / 2, 16, 16), self.imageHolder);
    NSFont *font = SNFont(SNFontSizeMicro, self.mine ? SNFontWeightBold : SNFontWeightRegular);
    SNDrawText(@(self.reaction.count).stringValue, font, SNColorContentPry, bounds.size.height, NSTextAlignmentLeft, 1,
               NSMakeRect(8 + 16 + 4, 0, bounds.size.width - 28, bounds.size.height));
}

@end
