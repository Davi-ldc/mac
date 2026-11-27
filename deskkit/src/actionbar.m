// Owns the bottom bar's two pills and clicks on them.
#import "actionbar.h"
#import "keycaps.h"
#import "theme.h"

/// Measured from Raycast, as distances between visible text and keycaps: text starts 14
/// points into the right pill and its last keycap ends 10.5 points before its edge; the
/// left pill's icon is 18 points, 10 points in.
static const CGFloat kRightLead = 14, kRightTrail = 10.5, kTitleToCaps = 7.5, kCapsToNext = 17.5, kActionsToCaps = 8.5;
static const CGFloat kLeftIconInset = 10, kLeftIconSize = 18, kLeftIconGap = 8, kLeftTrail = 14;
/// A label draws its text this far inside its frame.
static const CGFloat kLabelInset = 2;

@implementation DKActionBar {
    NSView *_leftPill, *_rightPill;
    NSImageView *_leftIcon;
    NSTextField *_leftTitle, *_primary, *_actions;
    DKKeycaps *_primaryCaps, *_actionsCaps;
    NSRect _primaryHit, _actionsHit;
}

static NSView *Pill(void) { return DKGlass(0.14, DKPillHeight / 2); }

/// Raycast's menu glyph: a long line over a shorter one, both starting at the left.
static NSImage *MenuGlyph(void) {
    const CGFloat width = 14, thickness = 1.5, spacing = 4.5;
    return [NSImage imageWithSize:NSMakeSize(width, spacing + thickness) flipped:YES drawingHandler:^BOOL(NSRect rect) {
        [DKTextSecondary() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, width, thickness) xRadius:thickness / 2 yRadius:thickness / 2] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, spacing, 9, thickness) xRadius:thickness / 2 yRadius:thickness / 2] fill];
        return YES;
    }];
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _leftPill = Pill();
    _leftIcon = [NSImageView new];
    _leftIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    _leftTitle = DKLabel(@"", DKFont(12, 400), DKTextSecondary());
    [_leftPill addSubview:_leftIcon];
    [_leftPill addSubview:_leftTitle];
    [self addSubview:_leftPill];

    _rightPill = Pill();
    _primary = DKLabel(@"", DKFont(12, 400), DKTextPrimary());
    _actions = DKLabel(@"Actions", DKFont(12, 400), DKTextSecondary());
    _primaryCaps = [[DKKeycaps alloc] initWithShortcut:nil];
    _actionsCaps = [[DKKeycaps alloc] initWithShortcut:[DKShortcut shortcutWithString:@"cmd+k"]];
    for (NSView *view in @[ _primary, _primaryCaps, _actions, _actionsCaps ]) [_rightPill addSubview:view];
    [self addSubview:_rightPill];
    return self;
}

- (void)showScreen:(DKScreen *)screen {
    CGFloat y = DKInset;
    if (!screen) {
        // The root has a round button where Raycast puts its own menu.
        NSImage *glyph = MenuGlyph();
        _leftIcon.image = glyph;
        _leftIcon.frame = NSMakeRect((DKPillHeight - glyph.size.width) / 2, (DKPillHeight - glyph.size.height) / 2,
                                     glyph.size.width, glyph.size.height);
        _leftTitle.hidden = YES;
        _leftPill.frame = NSMakeRect(DKInset, y, DKPillHeight, DKPillHeight);
        return;
    }
    _leftIcon.image = screen.icon;
    _leftIcon.frame = NSMakeRect(kLeftIconInset, (DKPillHeight - kLeftIconSize) / 2, kLeftIconSize, kLeftIconSize);
    _leftTitle.hidden = NO;
    _leftTitle.stringValue = screen.title;
    [_leftTitle sizeToFit];
    CGFloat titleX = kLeftIconInset + kLeftIconSize + kLeftIconGap - kLabelInset;
    NSSize size = _leftTitle.frame.size;
    _leftTitle.frame = NSMakeRect(titleX, (DKPillHeight - size.height) / 2, size.width, size.height);
    _leftPill.frame = NSMakeRect(DKInset, y, titleX + size.width - kLabelInset + kLeftTrail, DKPillHeight);
}

- (void)showPrimaryTitle:(NSString *)title shortcut:(DKShortcut *)shortcut hasMore:(BOOL)hasMore {
    _rightPill.hidden = !title;
    if (!title) return;
    _primary.stringValue = title;
    _primaryCaps.shortcut = shortcut;
    _actions.hidden = _actionsCaps.hidden = !hasMore;

    [_primary sizeToFit];
    [_actions sizeToFit];
    CGFloat x = kRightLead - kLabelInset, mid = DKPillHeight / 2;
    _primary.frame = NSMakeRect(x, mid - _primary.frame.size.height / 2, _primary.frame.size.width, _primary.frame.size.height);
    x = NSMaxX(_primary.frame) - kLabelInset + kTitleToCaps;
    _primaryCaps.frame = NSMakeRect(x, 0, _primaryCaps.width, DKPillHeight);
    x = NSMaxX(_primaryCaps.frame);
    _primaryHit = NSMakeRect(0, 0, x + kCapsToNext / 2, DKPillHeight);
    if (hasMore) {
        x += kCapsToNext - kLabelInset;
        _actions.frame = NSMakeRect(x, mid - _actions.frame.size.height / 2, _actions.frame.size.width, _actions.frame.size.height);
        x = NSMaxX(_actions.frame) - kLabelInset + kActionsToCaps;
        _actionsCaps.frame = NSMakeRect(x, 0, _actionsCaps.width, DKPillHeight);
        x = NSMaxX(_actionsCaps.frame);
        _actionsHit = NSMakeRect(NSMaxX(_primaryHit), 0, x + kRightTrail - NSMaxX(_primaryHit), DKPillHeight);
    } else {
        _actionsHit = NSZeroRect;
    }
    CGFloat width = x + kRightTrail;
    _rightPill.frame = NSMakeRect(self.bounds.size.width - DKInset - width, DKInset, width, DKPillHeight);
}

// The bar spans the panel's width; only the pills take clicks, the list shows through elsewhere.
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    return hit == self ? nil : hit;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [_rightPill convertPoint:event.locationInWindow fromView:nil];
    if (_rightPill.hidden || !NSPointInRect(point, _rightPill.bounds)) return;
    // The pill is layer-backed and not flipped; hit areas are measured from its left edge.
    if (NSPointInRect(NSMakePoint(point.x, DKPillHeight / 2), _actionsHit)) {
        if (self.onActions) self.onActions();
    } else if (self.onPrimary) {
        self.onPrimary();
    }
}

@end
