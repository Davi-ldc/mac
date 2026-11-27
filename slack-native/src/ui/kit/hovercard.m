// Owns the hover card's delays and its own hover tracking.
#import "ui/kit/hovercard.h"
#import "ui/kit/overlay.h"

static const CGFloat kGap = 11;

@interface SNHoverCardPanel : SNPanelView
@property (nonatomic) BOOL pointerInside;
@end

@implementation SNHoverCardPanel

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event { self.pointerInside = YES; }

- (void)mouseExited:(NSEvent *)event {
    self.pointerInside = NO;
    [SNHoverCard hoverEnded];
}

@end

@implementation SNHoverCard

static SNHoverCardPanel *card;
static NSString *cardKey;
static NSUInteger generation;

+ (NSString *)key { return card ? cardKey : nil; }

+ (void)hoverBeganOverRect:(NSRect)rect inView:(NSView *)view key:(NSString *)key content:(NSView * (^)(void))content {
    NSUInteger due = ++generation;
    // Back on the same person's target before the card closed: it stays. Another person's card
    // replaces it after the usual delay.
    if (card && [key isEqualToString:cardKey]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNHoverCardDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (due != generation || !view.window) return;
        [self close];
        [self present:content() forRect:rect inView:view];
        cardKey = [key copy];
    });
}

+ (void)present:(NSView *)content forRect:(NSRect)rect inView:(NSView *)view {
    SNOverlayHost *host = [SNOverlayHost hostForWindow:view.window];
    SNShadowStack shadow = {2, {{0, 0, 0, 1, SNMeasuredHoverCardRing, NO}, {0, 4, 12, 0, 0x00000014, NO}}};
    SNHoverCardPanel *panel = [[SNHoverCardPanel alloc] initWithFill:SNColorBasePry radius:SNRadiusLarge shadow:shadow];
    NSSize size = NSMakeSize(SNHoverCardWidth, content.frame.size.height);
    content.frame = (NSRect){NSZeroPoint, size};
    [panel.contentView addSubview:content];
    panel.frame = SNPlaceOverlay(size, [host convertRect:rect fromView:view], SNPlacementBelow, kGap, NO, host.bounds);
    [host addSubview:panel];
    card = panel;
    panel.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = SNLiveHoverCardFadeIn;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        panel.animator.alphaValue = 1;
    }];
}

+ (void)hoverEnded {
    NSUInteger ended = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLiveHoverCardCloseDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (ended == generation && !card.pointerInside) [self close];
    });
}

+ (void)close {
    generation++;
    [card removeFromSuperview];
    card = nil;
    cardKey = nil;
}

@end
