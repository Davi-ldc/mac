// Owns pointer tracking, the interaction overlay and its timing, and which cursor shows where.
#import "ui/kit/hoverview.h"
#import "ui/kit/tooltip.h"

NSCursor *SNCursorAtPoint(NSWindow *window, NSPoint point) {
    NSView *content = window.contentView;
    // Hit-testing follows what the pointer would click: views that let it through (labels,
    // tooltips, an overlay host with nothing open) leave the cursor to what is under them.
    NSView *hit = [content hitTest:content.superview ? [content.superview convertPoint:point fromView:nil] : point];
    for (NSView *view = hit; view; view = view.superview) {
        if ([view isKindOfClass:NSText.class] || [view isKindOfClass:NSTextField.class]) return nil;
        if (![view conformsToProtocol:@protocol(SNCursorProvider)]) continue;
        NSCursor *cursor = [(id<SNCursorProvider>)view cursorAtPoint:[view convertPoint:point fromView:nil]];
        if (cursor) return cursor;
    }
    return nil;
}

@implementation SNHoverView {
    NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    // Hover scales and rings may reach past the bounds.
    self.clipsToBounds = NO;
    _enabled = YES;
    _tracksMouse = YES;
    _hoverColor = SNOverlayHover;
    _pressedColor = SNOverlayPressed;
    _transitionDuration = SNDuration80;
    _transitionTiming = SNEaseDefault();
    _overlayLayer = [SNLayer layer];
    [self.layer addSublayer:_overlayLayer];
    return self;
}

- (BOOL)isFlipped { return YES; }
// Controls in the top bar would otherwise drag the window instead of being pressed.
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSEdgeInsets insets = self.overlayInsets;
    _overlayLayer.frame = CGRectMake(insets.left, insets.top, MAX(0, self.bounds.size.width - insets.left - insets.right),
                                     MAX(0, self.bounds.size.height - insets.top - insets.bottom));
    _overlayLayer.cornerRadius = self.overlayRadius;
    [CATransaction commit];
}

- (void)setOverlayRadius:(CGFloat)overlayRadius {
    _overlayRadius = overlayRadius;
    self.needsLayout = YES;
}

- (void)setOverlayInsets:(NSEdgeInsets)overlayInsets {
    if (NSEdgeInsetsEqual(overlayInsets, _overlayInsets)) return;
    _overlayInsets = overlayInsets;
    self.needsLayout = YES;
}

- (void)setHoverColor:(SNColorToken)hoverColor {
    _hoverColor = hoverColor;
    [self applyState:NO];
}

- (void)setPressedColor:(SNColorToken)pressedColor {
    _pressedColor = pressedColor;
    [self applyState:NO];
}

#pragma mark State

- (NSRect)tooltipTarget {
    NSEdgeInsets insets = self.tooltipInsets;
    NSRect bounds = self.bounds;
    CGFloat bottom = self.isFlipped ? insets.top : insets.bottom;
    return NSMakeRect(NSMinX(bounds) + insets.left, NSMinY(bounds) + bottom, NSWidth(bounds) - insets.left - insets.right,
                      NSHeight(bounds) - insets.top - insets.bottom);
}

- (void)setHovered:(BOOL)hovered {
    hovered = hovered && self.enabled;
    if (hovered == _hovered) return;
    _hovered = hovered;
    if (self.tooltip && hovered)
        [SNTooltip showText:self.tooltip shortcut:self.tooltipShortcut forRect:[self tooltipTarget] inView:self
                  placement:self.tooltipPlacement delay:SNTooltipDelay];
    else if (self.tooltip) [SNTooltip hide];
    [self applyState:YES];
}

- (void)setPressed:(BOOL)pressed {
    pressed = pressed && self.enabled;
    if (pressed == _pressed) return;
    _pressed = pressed;
    if (pressed && self.tooltip) [SNTooltip hide];
    [self applyState:YES];
}

- (void)setEnabled:(BOOL)enabled {
    if (enabled == _enabled) return;
    _enabled = enabled;
    if (!enabled) {
        if (_hovered && self.tooltip) [SNTooltip hide];
        _hovered = _pressed = NO;
    }
    [self applyState:NO];
}

- (void)applyState:(BOOL)animated {
    void (^changes)(void) = ^{
        SNColorToken overlay = self.pressed ? self.pressedColor : self.hovered ? self.hoverColor : 0;
        self->_overlayLayer.backgroundColor = overlay ? SNCGColor(overlay) : NULL;
        [self stateDidChange];
    };
    SNAnimate(animated ? self.transitionDuration : 0, self.transitionTiming, changes);
}

- (void)stateDidChange {}

#pragma mark Pointer

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = nil;
    if (!self.tracksMouse) return;
    // Like the web client, hover works while the window is in the background.
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setTracksMouse:(BOOL)tracksMouse {
    _tracksMouse = tracksMouse;
    [self updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; }

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    self.pressed = NO;
}

- (void)mouseDown:(NSEvent *)event { self.pressed = YES; }

- (void)mouseDragged:(NSEvent *)event {
    self.pressed = NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
}

- (void)mouseUp:(NSEvent *)event {
    BOOL clicked = self.pressed;
    self.pressed = NO;
    if (clicked && self.action) self.action(self);
}

- (NSCursor *)cursorAtPoint:(NSPoint)point {
    if (!self.enabled) return NSCursor.arrowCursor;
    return self.cursor ?: NSCursor.pointingHandCursor;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) self.hovered = self.pressed = NO;
}

- (void)viewDidHide {
    [super viewDidHide];
    self.hovered = self.pressed = NO;
}

@end
