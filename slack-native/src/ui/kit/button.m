// Owns the button's layers and its per-state styling.
#import "ui/kit/button.h"
#import "ui/kit/label.h"

/// components.json button.medium: 36 tall, padding 0 12 1, min width 80.
static const CGFloat kMediumHeight = 36, kMediumPadding = 12, kMediumMinWidth = 80;

@implementation SNButton {
    SNLabel *_label;
    CALayer *_fill;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _fill = [SNLayer layer];
    [self.layer insertSublayer:_fill below:self.overlayLayer];
    _icon = [SNIconLayer iconNamed:nil size:20 color:SNColorContentPry];
    [self.layer addSublayer:_icon];
    _font = SNFont(SNFontSizeBase, SNFontWeightBold);
    _contentColor = _hoverContentColor = _pressedContentColor = SNColorContentPry;
    _hoverScale = _hoverButtonScale = 1;
    _spacing = 8;
    _disabledAlpha = 1;
    return self;
}

+ (instancetype)iconButtonNamed:(NSString *)name size:(CGFloat)size iconSize:(CGFloat)iconSize {
    SNButton *button = [[self alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
    button.icon.iconName = name;
    button.icon.iconSize = iconSize;
    button.contentColor = SNColorContentSec;
    button.hoverContentColor = button.pressedContentColor = SNColorContentPry;
    button.hoverFillColor = SNColorCtrPry;
    button.hoverColor = 0;
    button.cornerRadius = SNRadiusLarge;
    return button;
}

+ (instancetype)primaryButtonWithTitle:(NSString *)title {
    SNButton *button = [self new];
    button.title = title;
    button.fillColor = button.hoverFillColor = SNColorBaseInvHgl2;
    button.hoverColor = SNColorBaseInvHgl2Hover;
    button.pressedColor = SNColorBaseInvHgl2Pressed;
    button.cornerRadius = SNRadiusLarge;
    return button;
}

+ (instancetype)outlineButtonWithTitle:(NSString *)title {
    SNButton *button = [self new];
    button.title = title;
    button.fillColor = button.hoverFillColor = SNColorBasePry;
    button.borderColor = SNColorOtlSec;
    button.hoverColor = 0;
    button.cornerRadius = SNRadiusLarge;
    return button;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    if (title && !_label) {
        _label = [SNLabel labelWithText:title font:self.font color:self.contentColor];
        [self addSubview:_label];
    }
    _label.text = title ?: @"";
    _label.hidden = !title;
    self.needsLayout = YES;
    [self invalidateIntrinsicContentSize];
}

- (void)setFont:(NSFont *)font {
    _font = font;
    _label.font = font;
    self.needsLayout = YES;
}

- (void)setContentColor:(SNColorToken)contentColor {
    _contentColor = contentColor;
    [self stateDidChange];
}

- (void)setFillColor:(SNColorToken)fillColor {
    _fillColor = fillColor;
    [self stateDidChange];
}

// The rounding is on the button's own layers: rounding a view's backing layer makes AppKit clip
// to it, which would cut off the hover scale.
- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.overlayRadius = cornerRadius;
    self.needsLayout = YES;
}

- (void)setBorderColor:(SNColorToken)borderColor {
    _borderColor = borderColor;
    _fill.borderWidth = borderColor ? 1 : 0;
    _fill.borderColor = borderColor ? SNCGColor(borderColor) : NULL;
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alphaValue = enabled ? 1 : self.disabledAlpha;
}

- (NSSize)fittingContentSize {
    CGFloat glyph = self.icon.iconName ? self.icon.iconSize : 0;
    CGFloat text = self.title ? ceil(_label.textWidth) : 0;
    return NSMakeSize(glyph + text + (glyph && text ? self.spacing : 0), MAX(glyph, self.title ? _label.intrinsicContentSize.height : 0));
}

- (NSSize)intrinsicContentSize {
    if (!self.title) return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
    return NSMakeSize(MAX(kMediumMinWidth, self.fittingContentSize.width + 2 * kMediumPadding), kMediumHeight);
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSSize content = self.fittingContentSize, size = self.bounds.size;
    CGFloat x = round((size.width - content.width) / 2);
    _fill.frame = self.bounds;
    _fill.cornerRadius = self.cornerRadius;
    if (self.icon.iconName) {
        CGFloat glyph = self.icon.iconSize;
        // Bounds and position rather than frame: the hover scale is a transform.
        self.icon.bounds = CGRectMake(0, 0, glyph, glyph);
        self.icon.position = CGPointMake(x + glyph / 2, size.height / 2);
        x += glyph + self.spacing;
    }
    if (self.title) {
        CGFloat height = _label.intrinsicContentSize.height;
        // Slack's buttons have 1 pt more padding below the label than above it.
        _label.frame = NSMakeRect(x, round((size.height - height - 1) / 2), ceil(_label.textWidth), height);
    }
    [CATransaction commit];
}

- (void)stateDidChange {
    [super stateDidChange];
    SNColorToken content = self.pressed ? self.pressedContentColor : self.hovered ? self.hoverContentColor : self.contentColor;
    self.icon.color = content;
    _label.color = content;
    SNColorToken fill = self.hovered || self.pressed ? self.hoverFillColor : self.fillColor;
    _fill.backgroundColor = fill ? SNCGColor(fill) : NULL;
    CGFloat scale = self.hovered ? self.hoverScale : 1;
    self.icon.affineTransform = CGAffineTransformMakeScale(scale, scale);
    // Scales every layer of the button about its centre; AppKit owns the view's own transform.
    CGFloat whole = self.hovered ? self.hoverButtonScale : 1;
    CGPoint anchor = self.layer.anchorPoint;
    CGSize size = self.bounds.size;
    CGFloat dx = size.width * (0.5 - anchor.x), dy = size.height * (0.5 - anchor.y);
    CATransform3D transform = CATransform3DMakeTranslation(dx, dy, 0);
    transform = CATransform3DScale(transform, whole, whole, 1);
    self.layer.sublayerTransform = CATransform3DTranslate(transform, -dx, -dy, 0);
}

@end
