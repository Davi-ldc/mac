// Slack's buttons (components.json "button"): a glyph and/or a label on a fill, with per-state
// content and fill colours, the interaction overlay and an optional glyph scale on hover.
#import "render/icon.h"
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNButton : SNHoverView
@property (nonatomic, readonly) SNIconLayer *icon;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic) NSFont *font;
/// Glyph and label colour at rest, hovered and pressed.
@property (nonatomic) SNColorToken contentColor, hoverContentColor, pressedContentColor;
/// The fill under the overlay at rest and hovered (0 is clear).
@property (nonatomic) SNColorToken fillColor, hoverFillColor;
@property (nonatomic) CGFloat cornerRadius;
/// A 1 pt border inside the fill's edge (0 for none).
@property (nonatomic) SNColorToken borderColor;
/// The glyph's scale while hovered (rail tabs 1.15, action bar 1.2); 1 by default.
@property (nonatomic) CGFloat hoverScale;
/// The whole button's scale while hovered (the rail's circle buttons, 1.1); 1 by default.
@property (nonatomic) CGFloat hoverButtonScale;
/// Space between the glyph and the label.
@property (nonatomic) CGFloat spacing;
/// The whole button's opacity while disabled (history buttons 0.45).
@property (nonatomic) CGFloat disabledAlpha;

/// Slack's default icon button: a `size` square, radius 8, the icon (an `iconSize` box) #b9babd
/// turning #f8f8f8 on a #212428 fill when hovered, an 18% overlay when pressed.
+ (instancetype)iconButtonNamed:(NSString *)name size:(CGFloat)size iconSize:(CGFloat)iconSize;
/// The green primary button (medium: 36 tall, 15 pt bold, radius 8).
+ (instancetype)primaryButtonWithTitle:(NSString *)title;
/// The outline button (medium).
+ (instancetype)outlineButtonWithTitle:(NSString *)title;
@property (nonatomic, readonly) NSSize fittingContentSize;
@end

NS_ASSUME_NONNULL_END
