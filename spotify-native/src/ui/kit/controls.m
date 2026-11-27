// Native macOS Spotifly-styled AppKit controls, DetailHeader, and virtualized TrackTable.
#import "ui/kit/controls.h"
#import "render/images.h"
#import "render/waveform.h"
#import "theme/theme.h"

#import <math.h>

#pragma mark - SPButton

@implementation SPButton {
    NSTrackingArea *_tracking;
    BOOL _hovered;
    BOOL _pressed;
}

+ (instancetype)iconButton:(SPIconName)icon size:(CGFloat)iconSize frame:(NSRect)frame {
    SPButton *b = [[self alloc] initWithFrame:frame];
    b.hasIcon = YES;
    b.icon = icon;
    b.iconSize = iconSize;
    b.style = SPButtonStyleGhost;
    return b;
}

+ (instancetype)pillButtonWithTitle:(NSString *)title style:(SPButtonStyle)style frame:(NSRect)frame {
    SPButton *b = [[self alloc] initWithFrame:frame];
    b.title = title;
    b.style = style;
    return b;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _enabled = YES;
    _iconSize = 15.0;
    _iconWeight = NSFontWeightRegular;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) { _hovered = NO; _pressed = NO; }
    self.needsDisplay = YES;
}

- (void)setIcon:(SPIconName)icon {
    _icon = icon;
    _hasIcon = YES;
    self.needsDisplay = YES;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { (void)event; if (_enabled) { _hovered = YES; self.needsDisplay = YES; } }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; _pressed = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (![self.superview isKindOfClass:SPSearchField.class] &&
        [self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    if (_enabled) { _pressed = YES; self.needsDisplay = YES; }
}

- (void)mouseUp:(NSEvent *)event {
    BOOL fire = _enabled && _pressed && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
    _pressed = NO;
    self.needsDisplay = YES;
    if (fire && _onClick) _onClick();
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    const SPTypographyScale *typo = SPThemeTypography();

    NSRect b = self.bounds;
    BOOL drawBg = NO;
    BOOL drawBorder = NO;
    NSColor *bgColor = nil;
    NSColor *fgColor = _active ? SPAccentColor() : SPLabelColor();
    CGFloat radius = _pillShape ? (b.size.height * 0.5) : 7.0;

    switch (_style) {
        case SPButtonStyleGhost:
            if (_pressed) {
                bgColor = [SPLabelColor() colorWithAlphaComponent:0.14];
                drawBg = YES;
            } else if (_hovered) {
                bgColor = SPHoverFillColor();
                drawBg = YES;
            } else if (_active && !_title.length) {
                // Subtle pill highlight on active toggles (like inspector toggle).
                bgColor = [SPAccentColor() colorWithAlphaComponent:0.14];
                drawBg = NO;
            }
            if (!_enabled) {
                fgColor = SPTertiaryLabelColor();
            } else if (_active) {
                fgColor = SPAccentColor();
            } else if (_hovered || _primaryWhenIdle) {
                fgColor = SPLabelColor();
            } else {
                fgColor = SPSecondaryLabelColor();
            }
            radius = _pillShape ? (b.size.height * 0.5) : 6.0;
            break;

        case SPButtonStyleSecondary:
            bgColor = _pressed
                ? [SPLabelColor() colorWithAlphaComponent:0.16]
                : (_hovered ? [SPLabelColor() colorWithAlphaComponent:0.11] : SPQuaternaryFillColor());
            drawBg = YES;
            drawBorder = YES;
            fgColor = _enabled ? SPLabelColor() : SPTertiaryLabelColor();
            break;

        case SPButtonStylePrimary:
            bgColor = !_enabled
                ? [SPAccentColor() colorWithAlphaComponent:0.45]
                : (_pressed ? SPAccentPressedColor() : (_hovered ? SPAccentHoverColor() : SPAccentColor()));
            drawBg = YES;
            fgColor = NSColor.whiteColor;
            break;

        case SPButtonStyleCirclePlay:
            bgColor = _pressed ? SPAccentPressedColor() : (_hovered ? SPAccentHoverColor() : SPAccentColor());
            drawBg = YES;
            fgColor = NSColor.whiteColor;
            radius = b.size.height * 0.5;
            break;

        case SPButtonStyleLink:
            drawBg = NO;
            fgColor = _enabled
                ? (_pressed ? [NSColor.linkColor colorWithAlphaComponent:0.7] : NSColor.linkColor)
                : SPTertiaryLabelColor();
            break;

        case SPButtonStyleDestructive:
            bgColor = _pressed
                ? [NSColor.systemRedColor colorWithAlphaComponent:0.18]
                : (_hovered ? [NSColor.systemRedColor colorWithAlphaComponent:0.10] : SPQuaternaryFillColor());
            drawBg = YES;
            drawBorder = YES;
            fgColor = _enabled ? NSColor.systemRedColor : SPTertiaryLabelColor();
            break;
    }

    if (drawBg && bgColor) {
        CGContextSetFillColorWithColor(ctx, bgColor.CGColor);
        if (_style == SPButtonStyleCirclePlay) {
            CGContextFillEllipseInRect(ctx, b);
        } else {
            CGFloat r = MIN(radius, MIN(b.size.width, b.size.height) * 0.5);
            CGPathRef path = CGPathCreateWithRoundedRect(b, r, r, NULL);
            CGContextAddPath(ctx, path);
            CGContextFillPath(ctx);
            CGPathRelease(path);
        }
    }

    if (drawBorder) {
        NSRect inset = NSInsetRect(b, 0.5, 0.5);
        CGFloat r = MIN(radius, MIN(inset.size.width, inset.size.height) * 0.5);
        CGPathRef path = CGPathCreateWithRoundedRect(inset, r, r, NULL);
        CGContextSetStrokeColorWithColor(ctx, SPSeparatorColor().CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextAddPath(ctx, path);
        CGContextStrokePath(ctx);
        CGPathRelease(path);
    }

    if (_title.length && _hasIcon) {
        SPTextStyle ts = (_style == SPButtonStyleLink) ? typo->body : typo->bodyMedium;
        NSDictionary *attrs = SPSemanticTextAttributes(ts, fgColor, NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        NSSize textSize = [_title sizeWithAttributes:attrs];
        CGFloat iconBox = _iconSize + 2.0;
        CGFloat gap = 6.0;
        CGFloat totalW = iconBox + gap + textSize.width;
        CGFloat startX = floor((b.size.width - totalW) * 0.5);
        CGRect iconRect = CGRectMake(startX, floor((b.size.height - iconBox) * 0.5), iconBox, iconBox);
        SPDrawIconSemantic(_icon, iconRect, _iconSize, _iconWeight, fgColor);
        [_title drawInRect:NSMakeRect(startX + iconBox + gap,
                                      floor((b.size.height - textSize.height) * 0.5),
                                      ceil(textSize.width + 2.0),
                                      ceil(textSize.height))
            withAttributes:attrs];
    } else if (_title.length) {
        SPTextStyle ts = (_style == SPButtonStyleLink) ? typo->body : typo->bodyMedium;
        NSDictionary *attrs = SPSemanticTextAttributes(ts, fgColor, NSLineBreakByTruncatingTail, NSTextAlignmentCenter);
        NSSize textSize = [_title sizeWithAttributes:attrs];
        [_title drawInRect:NSMakeRect(6.0,
                                      floor((b.size.height - textSize.height) * 0.5),
                                      MAX(0, b.size.width - 12.0),
                                      ceil(textSize.height))
            withAttributes:attrs];
    } else if (_hasIcon) {
        CGFloat s = MIN(_iconSize + 4.0, MIN(b.size.width, b.size.height));
        CGRect iconRect = CGRectMake(floor((b.size.width - s) * 0.5),
                                     floor((b.size.height - s) * 0.5),
                                     s, s);
        if (_icon == SPIconPlay && _style == SPButtonStyleCirclePlay) {
            iconRect.origin.x += 1.0;
        }
        SPDrawIconSemantic(_icon, iconRect, _iconSize, _iconWeight, fgColor);
    }
}

@end

#pragma mark - SPSegmentedControl

@implementation SPSegmentedControl {
    NSArray<NSString *> *_labels;
    NSArray<NSNumber *> *_icons;
    CGFloat _iconSize;
    NSMutableArray<NSNumber *> *_enabledFlags;
    NSMutableArray<NSNumber *> *_segWidths;
    NSInteger _hoveredSegment;
    NSInteger _pressedSegment;
    NSTrackingArea *_tracking;
}

+ (instancetype)segmentedControlWithLabels:(NSArray<NSString *> *)labels {
    SPSegmentedControl *c = [[self alloc] initWithFrame:NSZeroRect];
    c->_labels = [labels copy] ?: @[];
    c->_momentary = NO;
    c->_selectedSegment = 0;
    c->_enabledFlags = [NSMutableArray arrayWithCapacity:c->_labels.count];
    for (NSUInteger i = 0; i < c->_labels.count; i++) [c->_enabledFlags addObject:@YES];
    [c sizeToFit];
    return c;
}

+ (instancetype)momentaryControlWithIcons:(NSArray<NSNumber *> *)icons iconSize:(CGFloat)iconSize {
    SPSegmentedControl *c = [[self alloc] initWithFrame:NSZeroRect];
    c->_icons = [icons copy] ?: @[];
    c->_iconSize = iconSize > 0 ? iconSize : 13.0;
    c->_momentary = YES;
    c->_selectedSegment = -1;
    c->_enabledFlags = [NSMutableArray arrayWithCapacity:c->_icons.count];
    for (NSUInteger i = 0; i < c->_icons.count; i++) [c->_enabledFlags addObject:@YES];
    [c sizeToFit];
    return c;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _hoveredSegment = -1;
    _pressedSegment = -1;
    _segWidths = [NSMutableArray new];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSUInteger)segmentCount {
    return _labels.count > 0 ? _labels.count : _icons.count;
}

- (void)setSelectedSegment:(NSInteger)selectedSegment {
    if (_selectedSegment == selectedSegment) return;
    _selectedSegment = selectedSegment;
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)segment {
    if (segment < 0 || (NSUInteger)segment >= _enabledFlags.count) return;
    if (_enabledFlags[(NSUInteger)segment].boolValue == enabled) return;
    _enabledFlags[(NSUInteger)segment] = @(enabled);
    self.needsDisplay = YES;
}

- (void)sizeToFit {
    [_segWidths removeAllObjects];
    CGFloat totalW = 4.0;
    if (_labels.count > 0) {
        SPTextStyle segBold = {12.0, 0.23, 16.0, 0.0, NO};
        NSDictionary *attrs = SPSemanticTextAttributes(segBold, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentCenter);
        for (NSString *lbl in _labels) {
            CGFloat sw = MAX(56.0, ceil([lbl sizeWithAttributes:attrs].width) + 22.0);
            [_segWidths addObject:@(sw)];
            totalW += sw;
        }
        self.frame = NSMakeRect(self.frame.origin.x, self.frame.origin.y, totalW, 26.0);
    } else {
        for (NSUInteger i = 0; i < _icons.count; i++) {
            [_segWidths addObject:@30.0];
            totalW += 30.0;
        }
        self.frame = NSMakeRect(self.frame.origin.x, self.frame.origin.y, MAX(32.0, totalW), 28.0);
    }
    [self invalidateIntrinsicContentSize];
}

- (NSSize)intrinsicContentSize {
    return self.frame.size;
}

- (NSRect)rectForSegment:(NSUInteger)idx {
    CGFloat h = self.bounds.size.height;
    CGFloat pad = 2.0;
    CGFloat x = pad;
    CGFloat availW = MAX(1.0, self.bounds.size.width - pad * 2.0);
    CGFloat sumW = 0.0;
    for (NSNumber *n in _segWidths) sumW += n.doubleValue;
    CGFloat scale = sumW > 0.0 ? (availW / sumW) : 1.0;
    for (NSUInteger i = 0; i < idx && i < _segWidths.count; i++) {
        x += _segWidths[i].doubleValue * scale;
    }
    CGFloat sw = (idx < _segWidths.count) ? (_segWidths[idx].doubleValue * scale) : 30.0;
    return NSMakeRect(x, pad, sw, MAX(1.0, h - pad * 2.0));
}

- (NSInteger)segmentAtPoint:(NSPoint)pt {
    NSUInteger n = self.segmentCount;
    for (NSUInteger i = 0; i < n; i++) {
        if (NSPointInRect(pt, [self rectForSegment:i])) return (NSInteger)i;
    }
    return -1;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger seg = [self segmentAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (seg != _hoveredSegment) { _hoveredSegment = seg; self.needsDisplay = YES; }
}

- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (_hoveredSegment != -1) { _hoveredSegment = -1; self.needsDisplay = YES; }
}

- (void)mouseDown:(NSEvent *)event {
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    NSInteger seg = [self segmentAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (seg >= 0 && (NSUInteger)seg < _enabledFlags.count && _enabledFlags[(NSUInteger)seg].boolValue) {
        _pressedSegment = seg;
        self.needsDisplay = YES;
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSInteger pressed = _pressedSegment;
    _pressedSegment = -1;
    NSInteger seg = [self segmentAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (pressed >= 0 && seg == pressed && (NSUInteger)seg < _enabledFlags.count && _enabledFlags[(NSUInteger)seg].boolValue) {
        if (!_momentary) _selectedSegment = seg;
        self.needsDisplay = YES;
        if (_onSelectSegment) _onSelectSegment(seg);
        return;
    }
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    NSRect b = self.bounds;
    CGFloat r = b.size.height * 0.5;
    BOOL dark = SPIsDarkAppearance(self.effectiveAppearance);

    // Translucent macOS 27 glass-like capsule track
    NSColor *trackBg = dark
        ? [NSColor colorWithWhite:1.0 alpha:0.085]
        : [NSColor colorWithWhite:0.0 alpha:0.055];
    NSColor *trackBorder = dark
        ? [NSColor colorWithWhite:1.0 alpha:0.13]
        : [NSColor colorWithWhite:0.0 alpha:0.10];

    CGPathRef bgPath = CGPathCreateWithRoundedRect(NSInsetRect(b, 0.5, 0.5), r - 0.5, r - 0.5, NULL);
    CGContextSetFillColorWithColor(ctx, trackBg.CGColor);
    CGContextAddPath(ctx, bgPath);
    CGContextFillPath(ctx);
    CGContextSetStrokeColorWithColor(ctx, trackBorder.CGColor);
    CGContextSetLineWidth(ctx, 0.75);
    CGContextAddPath(ctx, bgPath);
    CGContextStrokePath(ctx);
    CGPathRelease(bgPath);

    NSUInteger n = self.segmentCount;
    for (NSUInteger i = 0; i < n; i++) {
        NSRect sr = [self rectForSegment:i];
        BOOL enabled = (i < _enabledFlags.count) ? _enabledFlags[i].boolValue : YES;
        BOOL selected = (!_momentary && (NSInteger)i == _selectedSegment);
        BOOL hovered = (enabled && (NSInteger)i == _hoveredSegment);
        BOOL pressed = (enabled && (NSInteger)i == _pressedSegment);

        if (selected) {
            CGFloat pr = sr.size.height * 0.5;
            CGPathRef pp = CGPathCreateWithRoundedRect(sr, pr, pr, NULL);
            CGContextSetFillColorWithColor(ctx, SPAccentColor().CGColor);
            CGContextAddPath(ctx, pp);
            CGContextFillPath(ctx);
            CGPathRelease(pp);
        } else if (pressed || hovered) {
            CGFloat pr = sr.size.height * 0.5;
            CGPathRef pp = CGPathCreateWithRoundedRect(sr, pr, pr, NULL);
            NSColor *hc = pressed
                ? [SPLabelColor() colorWithAlphaComponent:0.16]
                : [SPLabelColor() colorWithAlphaComponent:0.08];
            CGContextSetFillColorWithColor(ctx, hc.CGColor);
            CGContextAddPath(ctx, pp);
            CGContextFillPath(ctx);
            CGPathRelease(pp);
        }

        // Hairline separator between unselected segments
        if (i + 1 < n && !selected && (_momentary || (NSInteger)(i + 1) != _selectedSegment)) {
            CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
            CGContextFillRect(ctx, CGRectMake(floor(NSMaxX(sr)), 6.0, 1.0, MAX(0.0, b.size.height - 12.0)));
        }

        if (_labels.count > 0) {
            NSColor *fg = selected ? NSColor.whiteColor : (enabled ? SPLabelColor() : SPTertiaryLabelColor());
            SPTextStyle segBold = {12.0, 0.23, 16.0, 0.0, NO};
            SPTextStyle ts = selected ? segBold : typo->callout;
            NSDictionary *attrs = SPSemanticTextAttributes(ts, fg, NSLineBreakByClipping, NSTextAlignmentCenter);
            NSSize tsz = [_labels[i] sizeWithAttributes:attrs];
            [_labels[i] drawInRect:NSMakeRect(sr.origin.x,
                                              floor(sr.origin.y + (sr.size.height - tsz.height) * 0.5),
                                              sr.size.width,
                                              ceil(tsz.height))
                    withAttributes:attrs];
        } else if (i < _icons.count) {
            NSColor *fg = enabled ? SPLabelColor() : SPTertiaryLabelColor();
            SPIconName icon = (SPIconName)_icons[i].integerValue;
            CGRect ir = CGRectMake(floor(CGRectGetMidX(sr) - (_iconSize + 2.0) * 0.5),
                                   floor(CGRectGetMidY(sr) - (_iconSize + 2.0) * 0.5),
                                   _iconSize + 2.0,
                                   _iconSize + 2.0);
            SPDrawIconSemantic(icon, ir, _iconSize, NSFontWeightMedium, fg);
        }
    }
}

@end

#pragma mark - SPHeartButton

@implementation SPHeartButton {
    NSTrackingArea *_tracking;
    BOOL _hovered;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _iconPointSize = 13.0;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setFavorited:(BOOL)favorited {
    if (_favorited == favorited) return;
    _favorited = favorited;
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    if (_onToggle) _onToggle();
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    // Spotifly uses systemRed for favorited hearts (both NowPlayingBarView and TrackTable RowActions).
    NSColor *col = _favorited
        ? SPHeartRedColor()
        : ((_hovered || _primaryWhenUnfavorited) ? SPLabelColor() : SPSecondaryLabelColor());
    SPIconName icon = _favorited ? SPIconHeartFilled : SPIconHeart;
    SPDrawIconSemantic(icon, self.bounds, _iconPointSize, NSFontWeightRegular, col);
}

@end

#pragma mark - SPSlider

@implementation SPSlider {
    NSTrackingArea *_tracking;
    BOOL _hovered;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _minValue = 0.0;
    _maxValue = 1.0;
    _doubleValue = 0.0;
    _enabled = YES;
    _alwaysShowKnob = YES;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)isDragging { return _dragging; }

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) { _hovered = NO; _dragging = NO; }
    self.needsDisplay = YES;
}

- (void)setAccentFill:(BOOL)accentFill {
    if (_accentFill == accentFill) return;
    _accentFill = accentFill;
    self.needsDisplay = YES;
}

- (void)setMinValue:(double)minValue {
    if (fabs(_minValue - minValue) < 1e-6) return;
    _minValue = minValue;
    if (_doubleValue < _minValue) _doubleValue = _minValue;
    self.needsDisplay = YES;
}

- (void)setMaxValue:(double)maxValue {
    if (fabs(_maxValue - maxValue) < 1e-6) return;
    _maxValue = maxValue;
    if (_doubleValue > _maxValue) _doubleValue = _maxValue;
    self.needsDisplay = YES;
}

- (void)setDoubleValue:(double)doubleValue {
    double clamped = MIN(MAX(_minValue, doubleValue), _maxValue);
    if (fabs(clamped - _doubleValue) < 1e-6) return;
    _doubleValue = clamped;
    self.needsDisplay = YES;
}

- (double)valueForPoint:(NSPoint)pt {
    CGFloat pad = 6.0;
    CGFloat trackW = MAX(1.0, self.bounds.size.width - pad * 2.0);
    double frac = MIN(MAX(0.0, (pt.x - pad) / trackW), 1.0);
    return _minValue + frac * (_maxValue - _minValue);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { (void)event; if (_enabled) { _hovered = YES; self.needsDisplay = YES; } }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)event {
    if (!_enabled) return;
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    _dragging = YES;
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    _doubleValue = [self valueForPoint:pt];
    self.needsDisplay = YES;
    if (_onChange) _onChange(_doubleValue);
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging || !_enabled) return;
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    _doubleValue = [self valueForPoint:pt];
    self.needsDisplay = YES;
    if (_onChange) _onChange(_doubleValue);
}

- (void)mouseUp:(NSEvent *)event {
    if (!_dragging) return;
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    _doubleValue = [self valueForPoint:pt];
    _dragging = NO;
    self.needsDisplay = YES;
    if (_onCommit) _onCommit(_doubleValue);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    CGFloat alpha = _enabled ? 1.0 : 0.40;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, alpha);

    CGFloat pad = 6.0;
    CGFloat trackW = MAX(1.0, self.bounds.size.width - pad * 2.0);
    CGFloat trackH = (_hovered || _dragging) ? 4.0 : 3.5;
    CGFloat trackY = floor((self.bounds.size.height - trackH) * 0.5);
    CGRect trackRect = CGRectMake(pad, trackY, trackW, trackH);

    // Unfilled track
    NSColor *trackBg = [SPLabelColor() colorWithAlphaComponent:0.18];
    CGContextSetFillColorWithColor(ctx, trackBg.CGColor);
    CGPathRef bgPath = CGPathCreateWithRoundedRect(trackRect, trackH * 0.5, trackH * 0.5, NULL);
    CGContextAddPath(ctx, bgPath);
    CGContextFillPath(ctx);
    CGPathRelease(bgPath);

    // Filled track: #1DB954 green for volume slider (matching Spotifly screenshot), white/primary for scrub slider
    double span = MAX(1e-9, _maxValue - _minValue);
    double frac = MIN(MAX(0.0, (_doubleValue - _minValue) / span), 1.0);
    CGFloat fillW = trackW * frac;
    if (fillW > 0.5) {
        NSColor *fillColor = _accentFill
            ? SPAccentColor()
            : ((_hovered || _dragging) ? SPLabelColor() : [SPLabelColor() colorWithAlphaComponent:0.85]);
        CGContextSetFillColorWithColor(ctx, fillColor.CGColor);
        CGRect fillRect = CGRectMake(pad, trackY, MAX(trackH, fillW), trackH);
        CGPathRef fp = CGPathCreateWithRoundedRect(fillRect, trackH * 0.5, trackH * 0.5, NULL);
        CGContextAddPath(ctx, fp);
        CGContextFillPath(ctx);
        CGPathRelease(fp);
    }

    // Crisp circular white thumb matching macOS 27 native Slider
    if (_alwaysShowKnob || _hovered || _dragging) {
        CGFloat knob = (_hovered || _dragging) ? 11.0 : 9.5;
        CGFloat kx = pad + fillW - knob * 0.5;
        CGFloat ky = floor((self.bounds.size.height - knob) * 0.5);
        CGRect knobRect = CGRectMake(kx, ky, knob, knob);

        CGContextSetFillColorWithColor(ctx, NSColor.whiteColor.CGColor);
        CGContextFillEllipseInRect(ctx, knobRect);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0.0 alpha:0.18].CGColor);
        CGContextSetLineWidth(ctx, 0.5);
        CGContextStrokeEllipseInRect(ctx, CGRectInset(knobRect, 0.25, 0.25));
    }

    CGContextRestoreGState(ctx);
}

@end

#pragma mark - SPSearchField

@interface SPInnerSearchTextField : NSTextField
@property (nonatomic, weak) SPSearchField *owner;
@end

@implementation SPInnerSearchTextField

- (BOOL)becomeFirstResponder {
    BOOL ok = [super becomeFirstResponder];
    if (ok) {
        _owner.needsDisplay = YES;
        if (_owner.onFocus) _owner.onFocus();
    }
    return ok;
}

@end

@implementation SPSearchField {
    SPInnerSearchTextField *_field;
    SPButton *_clearBtn;
    NSString *_storedText;
    NSString *_storedPlaceholder;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _storedText = @"";
    _storedPlaceholder = @"Songs, Artists, Albums, Playlists";

    // Defer NSTextField (TextKit2) creation until first focus/click/typing to save ~2.4 MB cold-launch RAM.
    _clearBtn = [SPButton iconButton:SPIconClose size:11.0 frame:NSZeroRect];
    _clearBtn.hidden = YES;
    __weak typeof(self) weakSelf = self;
    _clearBtn.onClick = ^{
        [weakSelf clearAndResign:NO];
        [weakSelf focusSelectingAll:NO];
    };
    [self addSubview:_clearBtn];
    return self;
}

- (SPInnerSearchTextField *)ensureTextField {
    if (_field) return _field;
    const SPTypographyScale *typo = SPThemeTypography();
    _field = [[SPInnerSearchTextField alloc] initWithFrame:NSZeroRect];
    _field.owner = self;
    _field.bordered = NO;
    _field.bezeled = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = SPNSFont(typo->body);
    _field.textColor = SPLabelColor();
    _field.usesSingleLineMode = YES;
    _field.cell.scrollable = YES;
    _field.cell.wraps = NO;
    _field.delegate = self;
    _field.stringValue = _storedText ?: @"";
    NSDictionary *attrs = SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
    _field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:_storedPlaceholder ?: @"" attributes:attrs];
    [self addSubview:_field];
    [self layout];
    return _field;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSTextField *)textField { return [self ensureTextField]; }

- (NSSize)intrinsicContentSize {
    return NSMakeSize(440.0, 30.0);
}

- (NSString *)stringValue { return _field ? (_field.stringValue ?: @"") : (_storedText ?: @""); }

- (void)setStringValue:(NSString *)stringValue {
    _storedText = [stringValue copy] ?: @"";
    if (_field) _field.stringValue = _storedText;
    _clearBtn.hidden = (_storedText.length == 0);
    self.needsDisplay = YES;
}

- (NSString *)placeholderString { return _storedPlaceholder ?: @""; }

- (void)setPlaceholderString:(NSString *)placeholderString {
    _storedPlaceholder = [placeholderString copy] ?: @"";
    if (_field) {
        const SPTypographyScale *typo = SPThemeTypography();
        NSDictionary *attrs = SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        _field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:_storedPlaceholder attributes:attrs];
    }
    self.needsDisplay = YES;
}

- (BOOL)isFocused {
    if (!_field) return NO;
    NSResponder *fr = self.window.firstResponder;
    if (!fr) return NO;
    if (fr == _field) return YES;
    if ([fr isKindOfClass:NSTextView.class]) {
        NSTextView *tv = (NSTextView *)fr;
        return tv.delegate == (id)_field;
    }
    return NO;
}

- (void)focusSelectingAll:(BOOL)selectAll {
    if (!self.window) return;
    SPInnerSearchTextField *field = [self ensureTextField];
    [self.window makeFirstResponder:field];
    NSText *editor = [field currentEditor];
    if (editor) {
        if (selectAll) {
            editor.selectedRange = NSMakeRange(0, field.stringValue.length);
        } else {
            editor.selectedRange = NSMakeRange(field.stringValue.length, 0);
        }
    }
    self.needsDisplay = YES;
}

- (void)clearAndResign:(BOOL)resign {
    BOOL hadText = self.stringValue.length > 0;
    _storedText = @"";
    if (_field) _field.stringValue = @"";
    _clearBtn.hidden = YES;
    if (hadText && _onTextChange) _onTextChange(@"");
    if (resign && self.window) {
        [self.window makeFirstResponder:nil];
    }
    self.needsDisplay = YES;
}

- (void)typeString:(NSString *)text {
    if (!self.isFocused) [self focusSelectingAll:NO];
    SPInnerSearchTextField *field = [self ensureTextField];
    NSString *next = [(field.stringValue ?: @"") stringByAppendingString:text ?: @""];
    _storedText = next;
    field.stringValue = next;
    _clearBtn.hidden = (next.length == 0);
    if (_onTextChange) _onTextChange(next);
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    // 1-click focus anywhere on the search capsule.
    [self focusSelectingAll:NO];
}

- (void)layout {
    [super layout];
    CGFloat h = self.bounds.size.height;
    CGFloat w = self.bounds.size.width;
    CGFloat fieldH = 18.0;
    CGFloat rightMargin = _clearBtn.hidden ? 12.0 : 30.0;
    if (_field) {
        _field.frame = NSMakeRect(30.0, floor((h - fieldH) * 0.5) - 0.5, MAX(20.0, w - 30.0 - rightMargin), fieldH);
    }
    _clearBtn.frame = NSMakeRect(w - 26.0, floor((h - 20.0) * 0.5), 20.0, 20.0);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    NSRect b = self.bounds;
    CGFloat r = b.size.height * 0.5;
    BOOL focused = self.isFocused;
    BOOL dark = SPIsDarkAppearance(self.effectiveAppearance);

    // Translucent glass-like macOS 27 toolbar search capsule
    NSColor *fillCol = dark
        ? [NSColor colorWithWhite:1.0 alpha:(focused ? 0.13 : 0.09)]
        : [NSColor colorWithWhite:0.0 alpha:(focused ? 0.07 : 0.05)];
    CGPathRef path = CGPathCreateWithRoundedRect(NSInsetRect(b, 0.5, 0.5), r - 0.5, r - 0.5, NULL);
    CGContextSetFillColorWithColor(ctx, fillCol.CGColor);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);

    NSColor *strokeCol = focused
        ? [SPAccentColor() colorWithAlphaComponent:0.70]
        : (dark ? [NSColor colorWithWhite:1.0 alpha:0.14] : [NSColor colorWithWhite:0.0 alpha:0.12]);
    CGContextSetStrokeColorWithColor(ctx, strokeCol.CGColor);
    CGContextSetLineWidth(ctx, focused ? 1.5 : 1.0);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGPathRelease(path);

    // Magnifying glass SF Symbol
    CGRect iconRect = CGRectMake(10.0, floor((b.size.height - 14.0) * 0.5), 14.0, 14.0);
    SPDrawIconSemantic(SPIconSearch, iconRect, 12.5, NSFontWeightMedium,
                       focused ? SPLabelColor() : SPSecondaryLabelColor());

    // Before NSTextField is mounted, draw the exact placeholder or stored text directly.
    if (!_field) {
        const SPTypographyScale *typo = SPThemeTypography();
        BOOL hasText = (_storedText.length > 0);
        NSString *display = hasText ? _storedText : (_storedPlaceholder ?: @"");
        NSColor *col = hasText ? SPLabelColor() : SPSecondaryLabelColor();
        CGFloat rightMargin = _clearBtn.hidden ? 12.0 : 30.0;
        NSDictionary *attrs = SPSemanticTextAttributes(typo->body, col, NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        NSSize tsz = [display sizeWithAttributes:attrs];
        [display drawInRect:NSMakeRect(30.0, floor((b.size.height - tsz.height) * 0.5),
                                       MAX(20.0, b.size.width - 30.0 - rightMargin), ceil(tsz.height))
             withAttributes:attrs];
    }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    (void)obj;
    NSString *val = _field.stringValue ?: @"";
    _storedText = val;
    _clearBtn.hidden = (val.length == 0);
    self.needsLayout = YES;
    self.needsDisplay = YES;
    if (_onTextChange) _onTextChange(val);
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    (void)obj;
    self.needsDisplay = YES;
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    (void)control;
    (void)textView;
    if (commandSelector == @selector(insertNewline:)) {
        if (_onSubmit) _onSubmit(_field.stringValue ?: @"");
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self clearAndResign:YES];
        if (_onEscape) _onEscape();
        return YES;
    }
    return NO;
}

@end

#pragma mark - SPDetailHeaderView

@implementation SPDetailHeaderView {
    SPButton *_playBtn;
    SPButton *_shuffleBtn;
    SPButton *_libraryBtn;
    SPButton *_moreBtn;
    NSRect _linkRect;
    NSTrackingArea *_tracking;
    BOOL _linkHovered;
}

+ (CGFloat)preferredHeightForWidth:(CGFloat)width hasDescription:(BOOL)hasDescription {
    BOOL narrow = (width > 0.0 && width < 520.0);
    if (narrow) {
        return 132.0 + 12.0 + 132.0 + (hasDescription ? 22.0 : 0.0);
    }
    return 162.0;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _kindText = @"";
    _titleText = @"";
    _placeholderSymbol = @"music.note";
    _showPlayButton = YES;
    _playEnabled = YES;
    _libraryOnTitle = @"In Library";
    _libraryOffTitle = @"Add to Library";

    __weak typeof(self) weakSelf = self;

    _playBtn = [SPButton pillButtonWithTitle:@"Play" style:SPButtonStylePrimary frame:NSZeroRect];
    _playBtn.icon = SPIconPlay;
    _playBtn.iconSize = 12.0;
    _playBtn.onClick = ^{ if (weakSelf.onPlay) weakSelf.onPlay(); };
    [self addSubview:_playBtn];

    _shuffleBtn = [SPButton pillButtonWithTitle:@"Shuffle" style:SPButtonStyleSecondary frame:NSZeroRect];
    _shuffleBtn.icon = SPIconShuffle;
    _shuffleBtn.iconSize = 12.0;
    _shuffleBtn.hidden = YES;
    _shuffleBtn.onClick = ^{ if (weakSelf.onShuffle) weakSelf.onShuffle(); };
    [self addSubview:_shuffleBtn];

    _libraryBtn = [SPButton pillButtonWithTitle:@"Add to Library" style:SPButtonStyleSecondary frame:NSZeroRect];
    _libraryBtn.icon = SPIconPlus;
    _libraryBtn.iconSize = 11.5;
    _libraryBtn.hidden = YES;
    _libraryBtn.onClick = ^{ if (weakSelf.onLibraryToggle) weakSelf.onLibraryToggle(); };
    [self addSubview:_libraryBtn];

    _moreBtn = [SPButton iconButton:SPIconMore size:14.0 frame:NSZeroRect];
    _moreBtn.style = SPButtonStyleSecondary;
    _moreBtn.hidden = YES;
    _moreBtn.onClick = ^{
        SPDetailHeaderView *s = weakSelf;
        if (s && s.onMore) s.onMore(s->_moreBtn);
    };
    [self addSubview:_moreBtn];

    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (void)setArtworkURL:(NSString *)artworkURL {
    if ([_artworkURL isEqualToString:artworkURL ?: @""]) return;
    [self.imageHolder removeAllImages];
    _artworkURL = [artworkURL copy];
    self.needsDisplay = YES;
}

- (void)setKindText:(NSString *)kindText { _kindText = [kindText copy] ?: @""; self.needsDisplay = YES; }
- (void)setTitleText:(NSString *)titleText { _titleText = [titleText copy] ?: @""; self.needsDisplay = YES; }
- (void)setDescriptionText:(NSString *)descriptionText { _descriptionText = [descriptionText copy]; self.needsLayout = YES; self.needsDisplay = YES; }
- (void)setMetadataLinkText:(NSString *)metadataLinkText { _metadataLinkText = [metadataLinkText copy]; self.needsDisplay = YES; }
- (void)setMetadataText:(NSString *)metadataText { _metadataText = [metadataText copy]; self.needsDisplay = YES; }
- (void)setIsFavoritesHeader:(BOOL)isFavoritesHeader { _isFavoritesHeader = isFavoritesHeader; self.needsDisplay = YES; }
- (void)setArtworkCircular:(BOOL)artworkCircular { _artworkCircular = artworkCircular; self.needsDisplay = YES; }

- (void)setShowPlayButton:(BOOL)showPlayButton { _showPlayButton = showPlayButton; _playBtn.hidden = !showPlayButton; self.needsLayout = YES; }
- (void)setPlayEnabled:(BOOL)playEnabled { _playEnabled = playEnabled; _playBtn.enabled = playEnabled; _shuffleBtn.enabled = playEnabled; }
- (void)setShowShuffleButton:(BOOL)showShuffleButton { _showShuffleButton = showShuffleButton; _shuffleBtn.hidden = !showShuffleButton; self.needsLayout = YES; }
- (void)setShowMoreButton:(BOOL)showMoreButton { _showMoreButton = showMoreButton; _moreBtn.hidden = !showMoreButton; self.needsLayout = YES; }

- (void)setShowLibraryButton:(BOOL)showLibraryButton {
    _showLibraryButton = showLibraryButton;
    _libraryBtn.hidden = !showLibraryButton;
    self.needsLayout = YES;
}

- (void)setLibraryButtonOn:(BOOL)libraryButtonOn {
    _libraryButtonOn = libraryButtonOn;
    [self syncLibraryButton];
}

- (void)setLibraryOnTitle:(NSString *)libraryOnTitle { _libraryOnTitle = [libraryOnTitle copy] ?: @"In Library"; [self syncLibraryButton]; }
- (void)setLibraryOffTitle:(NSString *)libraryOffTitle { _libraryOffTitle = [libraryOffTitle copy] ?: @"Add to Library"; [self syncLibraryButton]; }

- (void)syncLibraryButton {
    _libraryBtn.title = _libraryButtonOn ? _libraryOnTitle : _libraryOffTitle;
    _libraryBtn.icon = _libraryButtonOn ? SPIconCheck : SPIconPlus;
    self.needsLayout = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL over = !NSIsEmptyRect(_linkRect) && NSPointInRect(pt, _linkRect);
    if (over != _linkHovered) {
        _linkHovered = over;
        self.needsDisplay = YES;
    }
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (_linkHovered) { _linkHovered = NO; self.needsDisplay = YES; }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSIsEmptyRect(_linkRect) && NSPointInRect(pt, _linkRect) && _onMetadataLink) {
        _onMetadataLink();
        return;
    }
    [super mouseDown:event];
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    BOOL narrow = (w > 0.0 && w < 520.0);
    CGFloat padX = narrow ? 20.0 : 28.0;
    CGFloat btnH = 30.0;
    CGFloat btnY = narrow ? (self.bounds.size.height - btnH - 14.0) : (10.0 + 132.0 - btnH);
    CGFloat x = narrow ? padX : (padX + 132.0 + 22.0);

    if (!_playBtn.hidden) {
        _playBtn.frame = NSMakeRect(x, btnY, 82.0, btnH);
        x += 82.0 + 8.0;
    }
    if (!_shuffleBtn.hidden) {
        _shuffleBtn.frame = NSMakeRect(x, btnY, 94.0, btnH);
        x += 94.0 + 8.0;
    }
    if (!_libraryBtn.hidden) {
        NSString *t = _libraryBtn.title ?: @"";
        CGFloat lw = MAX(100.0, ceil([t sizeWithAttributes:@{NSFontAttributeName: SPNSFont(SPThemeTypography()->bodyMedium)}].width) + 38.0);
        _libraryBtn.frame = NSMakeRect(x, btnY, lw, btnH);
        x += lw + 8.0;
    }
    if (!_moreBtn.hidden) {
        _moreBtn.frame = NSMakeRect(x, btnY, 34.0, btnH);
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat w = self.bounds.size.width;
    BOOL narrow = (w > 0.0 && w < 520.0);
    CGFloat padX = narrow ? 20.0 : 28.0;
    CGRect artRect = CGRectMake(padX, 10.0, 132.0, 132.0);

    if (_isFavoritesHeader) {
        SPDrawLikedSongsTile(ctx, artRect, 10.0, NO);
    } else {
        CGImageRef img = NULL;
        if (_artworkURL.length) {
            NSURL *u = [NSURL URLWithString:_artworkURL];
            if (u) {
                CGFloat scale = self.window.backingScaleFactor ?: 2.0;
                img = [self.imageHolder imageWithURL:u pixels:ceil(132.0 * scale)];
            }
        }
        SPDrawArtworkSemantic(ctx, img, artRect, 10.0, _artworkCircular, _placeholderSymbol, 44.0, 2.0);
    }

    CGFloat tx = narrow ? padX : (padX + 132.0 + 22.0);
    CGFloat tw = MAX(80.0, w - tx - padX);
    CGFloat y = narrow ? (CGRectGetMaxY(artRect) + 12.0) : 14.0;

    if (_kindText.length) {
        SPTextStyle kindStyle = {12.0, NSFontWeightSemibold, 15.0, 0.0, NO};
        [_kindText drawInRect:NSMakeRect(tx, y, tw, 16.0)
               withAttributes:SPSemanticTextAttributes(kindStyle, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
        y += 18.0;
    }

    SPTextStyle titleStyle = typo->display;
    if (narrow) titleStyle.size = 24.0;
    [_titleText drawInRect:NSMakeRect(tx, y, tw, narrow ? 30.0 : 36.0)
            withAttributes:SPSemanticTextAttributes(titleStyle, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    y += (narrow ? 30.0 : 38.0);

    if (_descriptionText.length) {
        [_descriptionText drawInRect:NSMakeRect(tx, y, tw, 18.0)
                      withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
        y += 20.0;
    }

    _linkRect = NSZeroRect;
    CGFloat mx = tx;
    if (_metadataLinkText.length) {
        SPTextStyle linkStyle = {13.0, NSFontWeightSemibold, 17.0, 0.0, NO};
        NSColor *linkCol = _onMetadataLink ? NSColor.linkColor : SPSecondaryLabelColor();
        NSMutableDictionary *attrs = [SPSemanticTextAttributes(linkStyle, linkCol, NSLineBreakByTruncatingTail, NSTextAlignmentLeft) mutableCopy];
        if (_linkHovered && _onMetadataLink) {
            attrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
        }
        NSSize lsz = [_metadataLinkText sizeWithAttributes:attrs];
        CGFloat lw = MIN(tw * 0.65, ceil(lsz.width + 2.0));
        _linkRect = NSMakeRect(mx, y, lw, 18.0);
        [_metadataLinkText drawInRect:_linkRect withAttributes:attrs];
        mx += lw + 4.0;
    }
    if (_metadataText.length) {
        CGFloat mw = MAX(20.0, tx + tw - mx);
        [_metadataText drawInRect:NSMakeRect(mx, y, mw, 18.0)
                   withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }

    // Subtle bottom hairline
    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(0.0, self.bounds.size.height - 1.0, w, 1.0));
}

@end

#pragma mark - SPTrackRowView

@implementation SPTrackRowView {
    SPHeartButton *_heartButton;
    SPButton *_moreButton;
    SPWaveformView *_waveform;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _showArtwork = YES;
    _showAlbumColumn = YES;

    _heartButton = [[SPHeartButton alloc] initWithFrame:NSZeroRect];
    _heartButton.iconPointSize = 12.5;
    __weak typeof(self) weakSelf = self;
    _heartButton.onToggle = ^{
        SPTrackRowView *s = weakSelf;
        if (s && s.track && s.onToggleFavorite) {
            s.onToggleFavorite(s.track);
        }
    };
    [self addSubview:_heartButton];

    _moreButton = [SPButton iconButton:SPIconMore size:13.0 frame:NSZeroRect];
    _moreButton.onClick = ^{
        SPTrackRowView *s = weakSelf;
        if (s && s.track && s.onMoreClick) {
            s.onMoreClick(s.track, s->_moreButton);
        }
    };
    [self addSubview:_moreButton];
    return self;
}

- (SPHeartButton *)heartButton { return _heartButton; }
- (BOOL)hasWaveformAttached { return _waveform != nil && _waveform.superview == self; }

- (void)setTrack:(SPTrack *)track {
    if (_track && ![_track.artworkSmallURL isEqualToString:track.artworkSmallURL] &&
        ![_track.artworkURL isEqualToString:track.artworkURL]) {
        [self.imageHolder removeAllImages];
    }
    _track = track;
    self.needsDisplay = YES;
}

- (void)setIsFavorited:(BOOL)isFavorited {
    _isFavorited = isFavorited;
    _heartButton.favorited = isFavorited;
}

- (void)setIsPlayingTrack:(BOOL)isPlayingTrack {
    if (_isPlayingTrack == isPlayingTrack) return;
    _isPlayingTrack = isPlayingTrack;
    [self syncWaveformAttachment];
    self.needsDisplay = YES;
}

- (void)setIsAudioPlaying:(BOOL)isAudioPlaying {
    if (_isAudioPlaying == isAudioPlaying) return;
    _isAudioPlaying = isAudioPlaying;
    _waveform.playing = _isPlayingTrack && _isAudioPlaying;
    self.needsDisplay = YES;
}

- (void)setIsDimmed:(BOOL)isDimmed {
    if (_isDimmed == isDimmed) return;
    _isDimmed = isDimmed;
    self.needsDisplay = YES;
}

- (void)setBadgeTag:(NSString *)badgeTag {
    if ([_badgeTag isEqualToString:badgeTag ?: @""]) return;
    _badgeTag = [badgeTag copy];
    self.needsDisplay = YES;
}

- (void)syncWaveformAttachment {
    if (_isPlayingTrack) {
        if (!_waveform) {
            _waveform = [[SPWaveformView alloc] initWithFrame:NSMakeRect(22.0, 16.0, 14.0, 14.0)];
        }
        if (_waveform.superview != self) {
            [self addSubview:_waveform];
        }
        _waveform.playing = _isAudioPlaying;
        self.needsLayout = YES;
    } else if (_waveform) {
        _waveform.playing = NO;
        [_waveform removeFromSuperview];
        _waveform = nil;
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _track = nil;
    _isPlayingTrack = NO;
    _isAudioPlaying = NO;
    _isFavorited = NO;
    _isDimmed = NO;
    _badgeTag = nil;
    _heartButton.favorited = NO;
    if (_waveform) {
        _waveform.playing = NO;
        [_waveform removeFromSuperview];
        _waveform = nil;
    }
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    _moreButton.frame = NSMakeRect(w - 40.0, floor((h - 22.0) * 0.5), 22.0, 22.0);
    _heartButton.frame = NSMakeRect(w - 66.0, floor((h - 22.0) * 0.5), 22.0, 22.0);
    if (_waveform) {
        _waveform.frame = NSMakeRect(24.0, floor((h - 14.0) * 0.5), 14.0, 14.0);
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!_track) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    const SPLayoutMetrics *m = SPThemeMetrics();

    NSRect b = self.bounds;
    if (self.isSelected || self.isHovered) {
        NSColor *rowBg = self.isSelected ? SPSelectedRowFillColor() : SPHoverFillColor();
        CGContextSetFillColorWithColor(ctx, rowBg.CGColor);
        CGPathRef p = CGPathCreateWithRoundedRect(NSInsetRect(b, 14.0, 1.0), m->radiusMD, m->radiusMD, NULL);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
    }

    BOOL dimmed = (!_track.playable || _isDimmed);
    CGContextSaveGState(ctx);
    if (dimmed) CGContextSetAlpha(ctx, 0.50);

    // Column 1: # / waveform (drawn by subview when playing)
    if (!_isPlayingTrack) {
        if (self.isHovered && _track.playable) {
            SPDrawIconSemantic(SPIconPlay, CGRectMake(24.0, floor((b.size.height - 12.0) * 0.5), 12.0, 12.0),
                               11.0, NSFontWeightRegular, SPLabelColor());
        } else {
            NSString *num = [NSString stringWithFormat:@"%lu", (unsigned long)_displayNumber];
            NSDictionary *numAttrs = SPSemanticTextAttributes(typo->monoTime, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight);
            [num drawInRect:NSMakeRect(16.0, floor((b.size.height - 14.0) * 0.5), 26.0, 15.0) withAttributes:numAttrs];
        }
    }

    // Column 2: 32pt artwork
    CGFloat x = 52.0;
    if (_showArtwork) {
        CGRect artRect = CGRectMake(x, floor((b.size.height - 32.0) * 0.5), 32.0, 32.0);
        NSString *artStr = _track.artworkSmallURL.length ? _track.artworkSmallURL : _track.artworkURL;
        CGImageRef img = NULL;
        if (artStr.length) {
            NSURL *u = [NSURL URLWithString:artStr];
            if (u) {
                CGFloat scale = self.window.backingScaleFactor ?: 2.0;
                img = [self.imageHolder imageWithURL:u pixels:ceil(32.0 * scale)];
            }
        }
        SPDrawArtworkSemantic(ctx, img, artRect, m->radiusSM, NO, @"music.note", 13.0, 0.0);
        x += 42.0;
    }

    // Reserve right columns: duration (48) + gap (10) + heart (22) + gap (4) + more (22) + right pad (18) = 124
    CGFloat durationRight = b.size.width - 74.0;
    CGFloat rightEdge = durationRight - 54.0;
    BOOL drawAlbum = _showAlbumColumn && (rightEdge - x > 280.0);
    CGFloat titleW = drawAlbum ? floor((rightEdge - x) * 0.56) : MAX(40.0, rightEdge - x - 8.0);

    // Optional provider tag (Q / C / A in Queue)
    CGFloat tagReserve = _badgeTag.length ? 22.0 : 0.0;
    NSColor *titleColor = _isPlayingTrack ? SPAccentColor() : SPLabelColor();
    SPTextStyle titleStyle = _isPlayingTrack ? typo->bodyMedium : typo->body;
    NSDictionary *titleAttrs = SPSemanticTextAttributes(titleStyle, titleColor, NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
    CGFloat textY = floor((b.size.height - 34.0) * 0.5);
    [_track.name drawInRect:NSMakeRect(x, textY, MAX(20.0, titleW - tagReserve), 18.0) withAttributes:titleAttrs];

    if (_badgeTag.length) {
        NSSize nameSz = [_track.name sizeWithAttributes:titleAttrs];
        CGFloat tagX = MIN(x + titleW - 18.0, x + ceil(nameSz.width) + 6.0);
        CGRect tagRect = CGRectMake(tagX, textY + 2.0, 16.0, 14.0);
        CGContextSetFillColorWithColor(ctx, SPQuaternaryFillColor().CGColor);
        CGPathRef tp = CGPathCreateWithRoundedRect(tagRect, 3.0, 3.0, NULL);
        CGContextAddPath(ctx, tp);
        CGContextFillPath(ctx);
        CGPathRelease(tp);
        SPTextStyle tagStyle = {9.0, NSFontWeightMedium, 11.0, 0.0, NO};
        [_badgeTag drawInRect:CGRectMake(tagX, textY + 3.0, 16.0, 12.0)
               withAttributes:SPSemanticTextAttributes(tagStyle, SPTertiaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentCenter)];
    }

    if (_track.artistName.length) {
        NSDictionary *artAttrs = SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        [_track.artistName drawInRect:NSMakeRect(x, textY + 18.0, titleW, 16.0) withAttributes:artAttrs];
    }

    // Album column
    if (drawAlbum && _track.albumName.length) {
        CGFloat albX = x + titleW + 14.0;
        CGFloat albW = MAX(20.0, rightEdge - albX - 8.0);
        NSDictionary *albAttrs = SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        [_track.albumName drawInRect:NSMakeRect(albX, floor((b.size.height - 16.0) * 0.5), albW, 17.0) withAttributes:albAttrs];
    }

    // Duration column
    NSString *dur = SPFormatDurationMs(_track.durationMs);
    NSDictionary *durAttrs = SPSemanticTextAttributes(typo->monoTime, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight);
    [dur drawInRect:NSMakeRect(durationRight - 46.0, floor((b.size.height - 14.0) * 0.5), 44.0, 15.0) withAttributes:durAttrs];

    CGContextRestoreGState(ctx);
}

@end

#pragma mark - SPTrackTableHeaderView

@interface SPTrackTableHeaderView : NSView
@property (nonatomic) BOOL showAlbumColumn;
@property (nonatomic) BOOL sortable;
@property (nonatomic) SPTrackSortColumn sortColumn;
@property (nonatomic) BOOL sortAscending;
@property (nonatomic, copy, nullable) void (^onSortColumn)(SPTrackSortColumn col);
@end

@implementation SPTrackTableHeaderView

- (BOOL)isFlipped { return YES; }

- (void)mouseDown:(NSEvent *)event {
    if (!_sortable || !_onSortColumn) return;
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat w = self.bounds.size.width;
    CGFloat durationRight = w - 74.0;
    CGFloat rightEdge = durationRight - 54.0;
    BOOL drawAlbum = _showAlbumColumn && (rightEdge - 52.0 > 280.0);
    CGFloat titleW = drawAlbum ? floor((rightEdge - 52.0) * 0.56) : MAX(40.0, rightEdge - 60.0);

    if (pt.x < 48.0) {
        _onSortColumn(SPTrackSortNumber);
    } else if (pt.x < 52.0 + titleW + 8.0) {
        _onSortColumn(SPTrackSortTitle);
    } else if (drawAlbum && pt.x < rightEdge) {
        _onSortColumn(SPTrackSortAlbum);
    } else if (pt.x >= durationRight - 52.0 && pt.x <= durationRight + 4.0) {
        _onSortColumn(SPTrackSortDuration);
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    SPTextStyle hdrStyle = {11.0, NSFontWeightSemibold, 14.0, 0.0, NO};
    NSDictionary *leftAttrs = SPSemanticTextAttributes(hdrStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft);
    NSDictionary *rightAttrs = SPSemanticTextAttributes(hdrStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight);

    CGFloat y = floor((h - 14.0) * 0.5);
    NSString *numLabel = (_sortColumn == SPTrackSortNumber) ? (_sortAscending ? @"# ▴" : @"# ▾") : @"#";
    [numLabel drawInRect:NSMakeRect(16.0, y, 28.0, 14.0) withAttributes:rightAttrs];

    CGFloat durationRight = w - 74.0;
    CGFloat rightEdge = durationRight - 54.0;
    BOOL drawAlbum = _showAlbumColumn && (rightEdge - 52.0 > 280.0);
    CGFloat titleW = drawAlbum ? floor((rightEdge - 52.0) * 0.56) : MAX(40.0, rightEdge - 60.0);

    NSString *titleLabel = (_sortColumn == SPTrackSortTitle) ? (_sortAscending ? @"Title ▴" : @"Title ▾") : @"Title";
    [titleLabel drawInRect:NSMakeRect(52.0, y, titleW, 14.0) withAttributes:leftAttrs];

    if (drawAlbum) {
        CGFloat albX = 52.0 + titleW + 14.0;
        NSString *albLabel = (_sortColumn == SPTrackSortAlbum) ? (_sortAscending ? @"Album ▴" : @"Album ▾") : @"Album";
        [albLabel drawInRect:NSMakeRect(albX, y, MAX(40.0, rightEdge - albX), 14.0) withAttributes:leftAttrs];
    }

    NSString *durLabel = (_sortColumn == SPTrackSortDuration) ? (_sortAscending ? @"Duration ▴" : @"Duration ▾") : @"Duration";
    [durLabel drawInRect:NSMakeRect(durationRight - 58.0, y, 56.0, 14.0) withAttributes:rightAttrs];

    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(16.0, h - 1.0, MAX(0, w - 32.0), 1.0));
}

@end

#pragma mark - SPTrackListView

@implementation SPTrackListView {
    NSArray<SPTrack *> *_sourceTracks;
    NSArray<SPTrack *> *_tracks;
    /// Populated ONLY for trackIDs that appear more than once (e.g. duplicate tracks in a playlist).
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_extraKeysByTrackID;
    NSString *_lastPlayingTrackID;
    BOOL _lastAudioPlaying;
    SPTrackTableHeaderView *_headerView;
    SPTrackSortColumn _sortColumn;
    BOOL _sortAscending;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _sourceTracks = @[];
    _tracks = @[];
    _showArtwork = YES;
    _showAlbumColumn = YES;
    _showColumnHeader = NO;
    _sortable = NO;
    self.bottomInset = SPThemeMetrics()->nowPlayingContentClearance;
    return self;
}

- (NSArray<SPTrack *> *)tracks { return _tracks; }

- (void)setShowColumnHeader:(BOOL)showColumnHeader {
    if (_showColumnHeader == showColumnHeader) return;
    _showColumnHeader = showColumnHeader;
    if (showColumnHeader && !_headerView) {
        _headerView = [[SPTrackTableHeaderView alloc] initWithFrame:NSZeroRect];
        _headerView.showAlbumColumn = _showAlbumColumn;
        _headerView.sortable = _sortable;
        __weak typeof(self) weakSelf = self;
        _headerView.onSortColumn = ^(SPTrackSortColumn col) {
            [weakSelf toggleSortColumn:col];
        };
        [self addSubview:_headerView];
    } else if (!showColumnHeader && _headerView) {
        [_headerView removeFromSuperview];
        _headerView = nil;
    }
    self.needsLayout = YES;
}

- (void)setShowAlbumColumn:(BOOL)showAlbumColumn {
    _showAlbumColumn = showAlbumColumn;
    _headerView.showAlbumColumn = showAlbumColumn;
    _headerView.needsDisplay = YES;
}

- (void)setSortable:(BOOL)sortable {
    _sortable = sortable;
    _headerView.sortable = sortable;
    _headerView.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    if (_headerView) {
        CGFloat hdrH = 28.0;
        _headerView.frame = NSMakeRect(0.0, 0.0, self.bounds.size.width, hdrH);
        self.scrollView.frame = NSMakeRect(0.0, hdrH, self.bounds.size.width, MAX(0.0, self.bounds.size.height - hdrH));
    }
}

- (void)toggleSortColumn:(SPTrackSortColumn)col {
    if (!_sortable) return;
    if (_sortColumn == col) {
        _sortAscending = !_sortAscending;
    } else {
        _sortColumn = col;
        _sortAscending = YES;
    }
    _headerView.sortColumn = _sortColumn;
    _headerView.sortAscending = _sortAscending;
    _headerView.needsDisplay = YES;
    [self applySortedTracks];
}

- (void)setTracks:(NSArray<SPTrack *> *)tracks {
    _sourceTracks = [tracks copy] ?: @[];
    [self applySortedTracks];
}

- (void)applySortedTracks {
    NSArray<SPTrack *> *display = _sourceTracks;
    if (_sortable && _sortColumn != SPTrackSortNone && _sourceTracks.count > 1) {
        if (_sortColumn == SPTrackSortNumber) {
            if (!_sortAscending) {
                display = _sourceTracks.reverseObjectEnumerator.allObjects;
            }
        } else {
            SPTrackSortColumn col = _sortColumn;
            BOOL asc = _sortAscending;
            display = [_sourceTracks sortedArrayUsingComparator:^NSComparisonResult(SPTrack *a, SPTrack *b) {
                NSComparisonResult r = NSOrderedSame;
                if (col == SPTrackSortTitle) {
                    r = [a.name localizedCaseInsensitiveCompare:b.name];
                } else if (col == SPTrackSortAlbum) {
                    r = [(a.albumName ?: @"") localizedCaseInsensitiveCompare:(b.albumName ?: @"")];
                } else if (col == SPTrackSortDuration) {
                    r = (a.durationMs < b.durationMs) ? NSOrderedAscending : (a.durationMs > b.durationMs ? NSOrderedDescending : NSOrderedSame);
                }
                return asc ? r : -r;
            }];
        }
    }

    _tracks = display;
    _extraKeysByTrackID = nil;
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:_tracks.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:_tracks.count];
    for (NSUInteger i = 0; i < _tracks.count; i++) {
        NSString *tid = _tracks[i].trackID;
        BOOL dup = [seen containsObject:tid];
        NSString *k = dup ? [NSString stringWithFormat:@"%@#%lu", tid, (unsigned long)i] : tid;
        if (dup) {
            if (tid.length) {
                if (!_extraKeysByTrackID) _extraKeysByTrackID = [NSMutableDictionary new];
                NSMutableArray<NSString *> *arr = _extraKeysByTrackID[tid];
                if (!arr) {
                    arr = [NSMutableArray arrayWithCapacity:2];
                    _extraKeysByTrackID[tid] = arr;
                }
                [arr addObject:k];
            }
        } else {
            [seen addObject:tid];
        }
        [keys addObject:k];
    }
    _lastPlayingTrackID = _store.playbackState.currentTrackID;
    _lastAudioPlaying = _store.playbackState.isPlaying;
    [self showKeys:keys];
}

- (void)refreshTrackIDs:(NSSet<NSString *> *)trackIDs {
    if (!trackIDs.count) return;
    if (!_extraKeysByTrackID.count) {
        [self refreshKeys:trackIDs];
        return;
    }
    NSMutableSet<NSString *> *expanded = [NSMutableSet setWithCapacity:trackIDs.count];
    for (NSString *tid in trackIDs) {
        [expanded addObject:tid];
        NSArray<NSString *> *extras = _extraKeysByTrackID[tid];
        if (extras.count) [expanded addObjectsFromArray:extras];
    }
    [self refreshKeys:expanded];
}

- (SPListRowView *)makeRow {
    SPTrackRowView *row = [[SPTrackRowView alloc] initWithFrame:NSZeroRect];
    __weak typeof(self) weakSelf = self;
    row.onToggleFavorite = ^(SPTrack *track) {
        [weakSelf.navigator toggleFavoriteTrackID:track.trackID];
    };
    row.onMoreClick = ^(SPTrack *track, NSView *anchor) {
        SPTrackListView *s = weakSelf;
        if (!s) return;
        NSUInteger idx = [s->_tracks indexOfObjectIdenticalTo:track];
        if (idx == NSNotFound) idx = [s indexOfKey:track.trackID];
        if (idx != NSNotFound) {
            NSMenu *menu = [s contextMenuForIndex:idx];
            if (menu) {
                [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0.0, anchor.bounds.size.height + 2.0) inView:anchor];
            }
        }
    };
    return row;
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width {
    (void)index;
    (void)width;
    return SPThemeMetrics()->trackRowHeight;
}

- (void)showIndex:(NSUInteger)index inRow:(SPTrackRowView *)row {
    if (index >= _tracks.count) return;
    SPTrack *t = _tracks[index];
    SPPlaybackState *pb = _store.playbackState;
    row.track = t;
    row.displayNumber = index + 1;
    row.showArtwork = _showArtwork;
    row.showAlbumColumn = _showAlbumColumn;
    row.isFavorited = [_store isFavoriteTrackID:t.trackID];
    row.isPlayingTrack = (pb.currentTrackID.length > 0 && [pb.currentTrackID isEqualToString:t.trackID]);
    row.isAudioPlaying = pb.isPlaying;
    row.isDimmed = NO;
    row.badgeTag = nil;
}

- (void)applyStoreChange:(SPChange *)change {
    if (change.favorites.count > 0) {
        [self refreshTrackIDs:change.favorites];
    }
    if (change.tracks.count > 0) {
        [self refreshTrackIDs:change.tracks];
    }
    if (change.playback) {
        [self syncPlaybackState];
    }
}

- (void)syncPlaybackState {
    SPPlaybackState *pb = _store.playbackState;
    NSString *curID = pb.currentTrackID;
    BOOL playing = pb.isPlaying;
    NSMutableSet<NSString *> *dirty = [NSMutableSet new];
    if (_lastPlayingTrackID.length && ![_lastPlayingTrackID isEqualToString:curID ?: @""]) {
        [dirty addObject:_lastPlayingTrackID];
    }
    if (curID.length && (![curID isEqualToString:_lastPlayingTrackID ?: @""] || playing != _lastAudioPlaying)) {
        [dirty addObject:curID];
    }
    _lastPlayingTrackID = [curID copy];
    _lastAudioPlaying = playing;
    if (dirty.count > 0) {
        [self refreshTrackIDs:dirty];
    }
}

- (NSArray<NSString *> *)fallbackURIsAfterIndex:(NSUInteger)index {
    NSMutableArray<NSString *> *uris = [NSMutableArray new];
    NSUInteger limit = MIN(_tracks.count, index + 25);
    for (NSUInteger i = index + 1; i < limit; i++) {
        if (_tracks[i].uri.length) [uris addObject:_tracks[i].uri];
    }
    return uris;
}

- (void)didActivateIndex:(NSUInteger)index {
    if (index >= _tracks.count) return;
    SPTrack *track = _tracks[index];
    if (!track.playable) return;
    NSArray<NSString *> *fallback = [self fallbackURIsAfterIndex:index];
    if (_playWithSongRadio || !_contextURI.length) {
        [_navigator playTrackWithRadio:track fallbackURIs:fallback];
    } else {
        NSUInteger origIdx = [_sourceTracks indexOfObjectIdenticalTo:track];
        NSInteger ctxIdx = (origIdx != NSNotFound) ? (NSInteger)origIdx : (NSInteger)index;
        [_navigator playTrack:track inContextURI:_contextURI trackIndex:ctxIdx fallbackURIs:fallback];
    }
}

- (NSMenu *)contextMenuForIndex:(NSUInteger)index {
    if (index >= _tracks.count) return nil;
    SPTrack *track = _tracks[index];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *play = [[NSMenuItem alloc] initWithTitle:@"Play" action:@selector(ctxPlay:) keyEquivalent:@""];
    play.target = self;
    play.representedObject = @(index);
    play.image = SPSFSymbolImage(@"play.fill", 12.0, NSFontWeightRegular, nil);
    [menu addItem:play];

    NSMenuItem *queue = [[NSMenuItem alloc] initWithTitle:@"Play Next" action:@selector(ctxQueue:) keyEquivalent:@""];
    queue.target = self;
    queue.representedObject = track;
    queue.image = SPSFSymbolImage(@"text.line.first.and.arrowtriangle.forward", 12.0, NSFontWeightRegular, nil);
    [menu addItem:queue];

    NSMenuItem *radio = [[NSMenuItem alloc] initWithTitle:@"Start Song Radio" action:@selector(ctxRadio:) keyEquivalent:@""];
    radio.target = self;
    radio.representedObject = @(index);
    radio.image = SPSFSymbolImage(@"dot.radiowaves.left.and.right", 12.0, NSFontWeightRegular, nil);
    [menu addItem:radio];

    [menu addItem:[NSMenuItem separatorItem]];

    BOOL fav = [_store isFavoriteTrackID:track.trackID];
    NSMenuItem *like = [[NSMenuItem alloc] initWithTitle:fav ? @"Remove from Favorites" : @"Add to Favorites"
                                                  action:@selector(ctxFavorite:)
                                           keyEquivalent:@""];
    like.target = self;
    like.representedObject = track;
    like.image = SPSFSymbolImage(fav ? @"heart.slash" : @"heart", 12.0, NSFontWeightRegular, nil);
    [menu addItem:like];

    if (track.albumID.length || track.artistID.length) {
        [menu addItem:[NSMenuItem separatorItem]];
    }
    if (track.artistID.length) {
        NSMenuItem *art = [[NSMenuItem alloc] initWithTitle:@"Go to Artist" action:@selector(ctxArtist:) keyEquivalent:@""];
        art.target = self;
        art.representedObject = track;
        art.image = SPSFSymbolImage(@"mic.fill", 12.0, NSFontWeightRegular, nil);
        [menu addItem:art];
    }
    if (track.albumID.length) {
        NSMenuItem *alb = [[NSMenuItem alloc] initWithTitle:@"Go to Album" action:@selector(ctxAlbum:) keyEquivalent:@""];
        alb.target = self;
        alb.representedObject = track;
        alb.image = SPSFSymbolImage(@"opticaldisc", 12.0, NSFontWeightRegular, nil);
        [menu addItem:alb];
    }

    if (_extraMenuItemsProvider) {
        NSArray<NSMenuItem *> *extras = _extraMenuItemsProvider(track, index);
        if (extras.count > 0) {
            [menu addItem:[NSMenuItem separatorItem]];
            for (NSMenuItem *item in extras) [menu addItem:item];
        }
    }

    if (track.trackID.length) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *copyLink = [[NSMenuItem alloc] initWithTitle:@"Copy Link" action:@selector(ctxCopyLink:) keyEquivalent:@""];
        copyLink.target = self;
        copyLink.representedObject = track;
        copyLink.image = SPSFSymbolImage(@"link", 12.0, NSFontWeightRegular, nil);
        [menu addItem:copyLink];
    }
    return menu;
}

- (void)ctxPlay:(NSMenuItem *)sender {
    [self didActivateIndex:[sender.representedObject unsignedIntegerValue]];
}

- (void)ctxRadio:(NSMenuItem *)sender {
    NSUInteger idx = [sender.representedObject unsignedIntegerValue];
    if (idx < _tracks.count) {
        [_navigator playTrackWithRadio:_tracks[idx] fallbackURIs:[self fallbackURIsAfterIndex:idx]];
    }
}

- (void)ctxQueue:(NSMenuItem *)sender {
    [_navigator addTrackToQueue:(SPTrack *)sender.representedObject];
}

- (void)ctxFavorite:(NSMenuItem *)sender {
    SPTrack *t = (SPTrack *)sender.representedObject;
    [_navigator toggleFavoriteTrackID:t.trackID];
}

- (void)ctxAlbum:(NSMenuItem *)sender {
    SPTrack *t = (SPTrack *)sender.representedObject;
    if (t.albumID.length) [_navigator openAlbumWithID:t.albumID];
}

- (void)ctxArtist:(NSMenuItem *)sender {
    SPTrack *t = (SPTrack *)sender.representedObject;
    if (t.artistID.length) [_navigator openArtistWithID:t.artistID];
}

- (void)ctxCopyLink:(NSMenuItem *)sender {
    SPTrack *t = (SPTrack *)sender.representedObject;
    if (!t.trackID.length) return;
    NSString *url = [NSString stringWithFormat:@"https://open.spotify.com/track/%@", t.trackID];
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:url forType:NSPasteboardTypeString];
}

@end
