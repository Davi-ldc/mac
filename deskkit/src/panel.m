// Owns the picker's window: its material, rounded shape and first look at key presses.
#import "drawnview.h"
#import "panel.h"
#import "theme.h"

@implementation DKFlippedView
- (BOOL)isFlipped { return YES; }
@end

/// The rounded shape as a mask image, which is what keeps the window's blur inside the
/// corners (a layer corner radius would not clip the material).
static NSImage *RoundedMask(CGFloat radius) {
    CGFloat side = radius * 2 + 1;
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    mask.resizingMode = NSImageResizingModeStretch;
    return mask;
}

/// A view filling its parent with a flat colour.
static NSView *Fill(NSView *parent, NSColor *color) {
    NSView *fill = [[NSView alloc] initWithFrame:parent.bounds];
    fill.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    fill.wantsLayer = YES;
    fill.layer.backgroundColor = color.CGColor;
    [parent addSubview:fill];
    return fill;
}

/// The panel's material with the shade that brings it to Raycast's colour: #3d3d3e when
/// nothing is behind the window, near black over a dark desktop.
static NSVisualEffectView *Material(void) {
    NSVisualEffectView *material = [NSVisualEffectView new];
    material.material = NSVisualEffectMaterialHeaderView;
    material.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    material.state = NSVisualEffectStateActive;
    Fill(material, [NSColor colorWithWhite:0 alpha:0.1]);
    return material;
}

/// A one-point line along the inside of the glass's outline, lit where the edge runs
/// level (top and bottom) and dark where it runs upright, as on Raycast's glass.
@interface DKGlassEdge : DKDrawnView
@property CGFloat cornerRadius;
@end

@implementation DKGlassEdge

- (void)drawRect:(NSRect)dirty {
    NSRect bounds = self.bounds;
    CGFloat radius = MIN(_cornerRadius, MIN(bounds.size.width, bounds.size.height) / 2) - 0.5;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextAddPath(context, [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:radius
                                                              yRadius:radius].CGPath);
    CGContextSetLineWidth(context, 1);
    CGContextReplacePathWithStrokedPath(context);
    CGContextClip(context);
    NSColor *lit = DKWhite(0.3), *dark = [NSColor colorWithWhite:0 alpha:0.6];
    // Stops in points from the top and bottom, so the lit band stays the same on any height.
    CGFloat band = MIN(0.45, 4 / MAX(bounds.size.height, 1));
    NSGradient *gradient = [[NSGradient alloc] initWithColorsAndLocations:lit, 0.0, dark, band, dark, 1 - band, lit, 1.0, nil];
    [gradient drawInRect:bounds angle:90];
}

@end

NSView *DKGlass(CGFloat lighten, CGFloat cornerRadius) {
    NSVisualEffectView *glass = Material();
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = cornerRadius;
    glass.layer.masksToBounds = YES;
    Fill(glass, DKWhite(lighten));
    DKGlassEdge *edge = [[DKGlassEdge alloc] initWithFrame:glass.bounds];
    edge.cornerRadius = cornerRadius;
    edge.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [glass addSubview:edge];
    return glass;
}

@implementation DKPanel

- (instancetype)init {
    // Not deferred: only a window the window server already knows lays out and draws its
    // views while closed, which is what makes the first show as quick as the later ones.
    if (!(self = [super initWithContentRect:NSMakeRect(0, 0, DKPanelWidth, DKPanelHeight)
                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                    backing:NSBackingStoreBuffered
                                      defer:NO]))
        return nil;
    // The picker owns the panel; closing must not also release it.
    self.releasedWhenClosed = NO;
    self.level = NSFloatingWindowLevel;
    self.opaque = NO;
    self.backgroundColor = NSColor.clearColor;
    self.hasShadow = YES;
    self.hidesOnDeactivate = NO;
    // The system's zoom in and out would hold the panel back for its length on every show,
    // and stall a hide that comes while it runs.
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSVisualEffectView *material = Material();
    material.maskImage = RoundedMask(DKPanelRadius);
    self.contentView = material;

    _canvas = [[DKFlippedView alloc] initWithFrame:material.bounds];
    _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [material addSubview:_canvas];
    return self;
}

// Borderless panels refuse key status by default, and the search field needs it.
- (BOOL)canBecomeKeyWindow { return YES; }

/// The editing action a key press stands for, or NULL. An app with a menu bar gets these
/// from its Edit menu's key equivalents; deskkit has no menu bar, so nothing else would
/// turn ⌘V into a paste.
static SEL EditingAction(NSEvent *event) {
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                                            NSEventModifierFlagOption | NSEventModifierFlagControl);
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    if (modifiers == (NSEventModifierFlagCommand | NSEventModifierFlagShift))
        return [key isEqualToString:@"z"] ? NSSelectorFromString(@"redo:") : NULL;
    if (modifiers != NSEventModifierFlagCommand) return NULL;
    NSString *action = @{@"x" : @"cut:", @"c" : @"copy:", @"v" : @"paste:", @"a" : @"selectAll:", @"z" : @"undo:"}[key];
    return action ? NSSelectorFromString(action) : NULL;
}

- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyUp && self.keyUpHandler) self.keyUpHandler(event);
    if (event.type == NSEventTypeKeyDown) {
        if (self.keyHandler && self.keyHandler(event)) return;
        // Offered from the field with the keyboard up to the panel itself, which does the undoing.
        SEL action = EditingAction(event);
        NSTextView *editor = (NSTextView *)self.firstResponder;
        if (action && [editor tryToPerform:action with:self]) {
            // AppKit undoes a field's text without the notice that typing in it gives, and
            // that notice is how the list follows the search field.
            BOOL undoes = action == NSSelectorFromString(@"undo:") || action == NSSelectorFromString(@"redo:");
            if (undoes && [editor isKindOfClass:NSTextView.class]) [editor didChangeText];
            return;
        }
    }
    [super sendEvent:event];
}

@end
