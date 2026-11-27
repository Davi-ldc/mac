// The base of everything that reacts to the pointer. It tracks hover and press, paints Slack's
// interaction overlay (tokens.json: 8% hover, 18% pressed, lighter than any surface it covers,
// so plain compositing matches CSS 'lighten') and animates it, and shows its tooltip.
//
// Lists that hover their rows themselves (one tracking area for many rows is cheaper) turn
// `tracksMouse` off and set `hovered` on the row.
//
// The cursor is not set by the views: the main window asks SNCursorAtPoint on every pointer
// event, so rows that never see the pointer themselves get it as well.
#import <AppKit/AppKit.h>

#import "theme/theme.h"
#import "ui/kit/overlay.h"

NS_ASSUME_NONNULL_BEGIN

/// A view whose cursor is not the arrow somewhere: the pointing hand over what is clickable
/// (Slack's buttons, rows and links all say cursor: pointer).
@protocol SNCursorProvider
/// `point` in the view's coordinates; nil leaves it to the superview.
- (nullable NSCursor *)cursorAtPoint:(NSPoint)point;
@end

/// The cursor at `point` (window coordinates): the first answer of the views under it, deepest
/// first. nil where none answers (the arrow) and over text views, which keep AppKit's I-beam.
NSCursor *_Nullable SNCursorAtPoint(NSWindow *window, NSPoint point);

@interface SNHoverView : NSView <SNCursorProvider>
@property (nonatomic, getter=isHovered) BOOL hovered;
@property (nonatomic, getter=isPressed) BOOL pressed;
/// A disabled view neither hovers nor presses nor acts.
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic) BOOL tracksMouse;
/// Painted over the view while hovered or pressed; SNOverlayHover and SNOverlayPressed by default.
/// A clear colour (0) paints nothing.
@property (nonatomic) SNColorToken hoverColor, pressedColor;
/// The overlay's rounding and its inset from the view's edges.
@property (nonatomic) CGFloat overlayRadius;
@property (nonatomic) NSEdgeInsets overlayInsets;
/// How state changes animate: 80 ms with the default easing (Slack's buttons) unless set.
@property (nonatomic) CFTimeInterval transitionDuration;
@property (nonatomic) CAMediaTimingFunction *transitionTiming;
/// Called on a click: a press released over the view.
@property (nonatomic, copy, nullable) void (^action)(__kindof SNHoverView *view);
/// Shown after SNTooltipDelay of hovering, on the `tooltipPlacement` side (above by default).
@property (nonatomic, copy, nullable) NSString *tooltip;
/// The keys of the tooltip's shortcut, each in a chip under the text ("⌘ [", "F1").
@property (nonatomic, copy, nullable) NSString *tooltipShortcut;
@property (nonatomic) SNPlacement tooltipPlacement;
/// The tooltip's target is the view's bounds inset by this (negative reaches beyond the view:
/// the top bar's buttons point their tooltips from the bar's full height).
@property (nonatomic) NSEdgeInsets tooltipInsets;
/// The pointer over the view while enabled; nil for the pointing hand. Disabled, the arrow
/// (Slack's disabled buttons say cursor: default).
@property (nonatomic, nullable) NSCursor *cursor;

/// Subclasses restyle themselves for the current state here; it runs inside the transition, so
/// layer changes animate with it. Call super.
- (void)stateDidChange;
/// The overlay layer, for subclasses that lay out their own layers around it.
@property (nonatomic, readonly) CALayer *overlayLayer;
@end

NS_ASSUME_NONNULL_END
