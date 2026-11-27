// Owns the overlay layer of a window and the shared panel surface.
#import <objc/runtime.h>

#import "ui/kit/overlay.h"

@implementation SNOverlayHost

+ (instancetype)hostForWindow:(NSWindow *)window {
    if (!window) return nil;
    static char key;
    SNOverlayHost *host = objc_getAssociatedObject(window, &key);
    NSView *content = window.contentView;
    if (!host) {
        host = [[SNOverlayHost alloc] initWithFrame:content.bounds];
        host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        host.wantsLayer = YES;
        objc_setAssociatedObject(window, &key, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (host.superview != content || content.subviews.lastObject != host) {
        host.frame = content.bounds;
        [content addSubview:host positioned:NSWindowAbove relativeTo:nil];
    }
    return host;
}

- (BOOL)isFlipped { return YES; }

- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if (hit && hit != self) return hit;
    return self.outsideClick ? self : nil;
}

- (void)mouseDown:(NSEvent *)event {
    void (^outsideClick)(void) = self.outsideClick;
    if (outsideClick) outsideClick();
}

@end

@implementation SNPanelView {
    CALayer *_surface;
    SNShadowStack _shadow;
}

- (instancetype)initWithFill:(SNColorToken)fill radius:(CGFloat)radius shadow:(SNShadowStack)shadow {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.wantsLayer = YES;
    // The ring and the shadow lie outside the bounds. They are drawn by a layer of the panel's
    // own: AppKit manages the shadow and clipping of a view's backing layer itself.
    self.clipsToBounds = NO;
    _shadow = shadow;
    _surface = [CALayer layer];
    _surface.cornerRadius = radius;
    _surface.backgroundColor = SNCGColor(fill);
    [self.layer addSublayer:_surface];
    _contentView = [[NSView alloc] initWithFrame:self.bounds];
    _contentView.wantsLayer = YES;
    _contentView.layer.cornerRadius = radius;
    _contentView.layer.masksToBounds = YES;
    _contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_contentView];
    return self;
}

- (BOOL)isFlipped { return YES; }

// Frame changes do not always lay a view out, and the shadow follows the size.
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _surface.frame = self.bounds;
    SNApplyShadow(_surface, _shadow);
    [CATransaction commit];
}

@end

NSRect SNPlaceOverlay(NSSize size, NSRect target, SNPlacement placement, CGFloat gap, BOOL centred, NSRect bounds) {
    NSRect (^place)(SNPlacement) = ^NSRect(SNPlacement side) {
        NSRect frame = {NSZeroPoint, size};
        if (side == SNPlacementAbove || side == SNPlacementBelow) {
            frame.origin.y = side == SNPlacementAbove ? NSMinY(target) - gap - size.height : NSMaxY(target) + gap;
            frame.origin.x = centred ? NSMidX(target) - size.width / 2 : NSMinX(target);
        } else {
            frame.origin.x = side == SNPlacementLeft ? NSMinX(target) - gap - size.width : NSMaxX(target) + gap;
            frame.origin.y = centred ? NSMidY(target) - size.height / 2 : NSMinY(target);
        }
        return frame;
    };
    // Only the placement's own axis decides the side; the other axis is clamped below.
    BOOL (^fits)(NSRect, SNPlacement) = ^BOOL(NSRect frame, SNPlacement side) {
        return side == SNPlacementAbove || side == SNPlacementBelow ? NSMinY(frame) >= NSMinY(bounds) && NSMaxY(frame) <= NSMaxY(bounds)
                                                                    : NSMinX(frame) >= NSMinX(bounds) && NSMaxX(frame) <= NSMaxX(bounds);
    };
    static const SNPlacement opposite[] = {SNPlacementBelow, SNPlacementAbove, SNPlacementRight, SNPlacementLeft};
    NSRect frame = place(placement);
    if (!fits(frame, placement)) {
        NSRect flipped = place(opposite[placement]);
        if (fits(flipped, opposite[placement])) frame = flipped;
    }
    frame.origin.x = MAX(NSMinX(bounds), MIN(frame.origin.x, NSMaxX(bounds) - size.width));
    frame.origin.y = MAX(NSMinY(bounds), MIN(frame.origin.y, NSMaxY(bounds) - size.height));
    frame.origin = NSMakePoint(round(frame.origin.x), round(frame.origin.y));
    return frame;
}

SNPlacement SNPlacementOf(NSRect frame, NSRect target) {
    if (NSMaxY(frame) <= NSMinY(target)) return SNPlacementAbove;
    if (NSMinY(frame) >= NSMaxY(target)) return SNPlacementBelow;
    return NSMaxX(frame) <= NSMinX(target) ? SNPlacementLeft : SNPlacementRight;
}
