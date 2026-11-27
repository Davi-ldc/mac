// Owns the card's border, its columns and the resizers between them.
#import "theme/theme.h"
#import "ui/kit/container.h"
#import "ui/kit/hoverview.h"
#import "ui/shell/card.h"

/// The resizer's hit strip is 8 pt wide around a 1 pt line (components.json sidebar_resizer).
static const CGFloat kHitWidth = 8;
/// A drag pulses the glow from 1 to 3 pt and back.
static const CFTimeInterval kPulse = 0.5;
/// The card's outer corner. tokens.json says 10 (window_content_card), but the arc in the
/// content_card_corner_topleft capture fits a 12 pt circle, the CSS value for macOS 26 and later.
static const CGFloat kCardRadius = SNRadiusXlarge;
/// effects.txt [A24]: the sidebar collapses and expands in 240 ms with cubic-bezier(.1,1,.2,1).
static const CFTimeInterval kCollapse = 0.24;

@interface SNResizer : NSView <SNCursorProvider>
@property (nonatomic, copy) void (^dragged)(CGFloat delta);
@property (nonatomic, copy) void (^ended)(void);
@end

@implementation SNResizer {
    CALayer *_line;
    NSUInteger _hoverGeneration;
    BOOL _dragging;
    CGFloat _lastX;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    _line = [SNLayer layer];
    _line.backgroundColor = SNCGColor(SNColorOtlTer);
    _line.shadowColor = SNCGColor(SNLegacyHighlight);
    _line.shadowOffset = CGSizeZero;
    _line.shadowRadius = 0;
    [self.layer addSublayer:_line];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
    return self;
}

- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _line.frame = CGRectMake((self.bounds.size.width - 1) / 2, 0, 1, self.bounds.size.height);
    // The glow is a 1 pt spread: a shadow the shape of the line, grown by a point each side.
    _line.shadowPath = CFAutorelease(CGPathCreateWithRect(CGRectInset(_line.bounds, -1, -1), NULL));
    [CATransaction commit];
}

- (NSCursor *)cursorAtPoint:(NSPoint)point { return NSCursor.resizeLeftRightCursor; }

/// Measured live: the line turns #1d9bd1 with a 1 pt glow 150 ms into a hover, over 150 ms with
/// the default curve, and turns back 150 ms after the pointer leaves, over 100 ms 'ease'.
- (void)setHighlighted:(BOOL)highlighted {
    CAMediaTimingFunction *timing = highlighted ? SNEaseDefault() : [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault];
    SNAnimate(highlighted ? SNLiveResizerShow : SNLiveResizerHide, timing, ^{
        self->_line.backgroundColor = SNCGColor(highlighted ? SNLegacyHighlight : SNColorOtlTer);
        self->_line.shadowOpacity = highlighted ? 1 : 0;
    });
}

- (void)mouseEntered:(NSEvent *)event {
    [self setHighlighted:YES after:SNLiveResizerShowDelay];
}

- (void)mouseExited:(NSEvent *)event {
    if (!_dragging) [self setHighlighted:NO after:SNLiveResizerHideDelay];
}

- (void)setHighlighted:(BOOL)highlighted after:(NSTimeInterval)delay {
    NSUInteger generation = ++_hoverGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == self->_hoverGeneration) [self setHighlighted:highlighted];
    });
}

- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    _lastX = event.locationInWindow.x;
    _hoverGeneration++;
    [self setHighlighted:YES];
    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"shadowPath"];
    CGRect line = _line.bounds;
    pulse.values = @[
        (__bridge id)CFAutorelease(CGPathCreateWithRect(CGRectInset(line, -1, -1), NULL)),
        (__bridge id)CFAutorelease(CGPathCreateWithRect(CGRectInset(line, -3, -3), NULL)),
        (__bridge id)CFAutorelease(CGPathCreateWithRect(CGRectInset(line, -1, -1), NULL)),
    ];
    pulse.duration = kPulse;
    [_line addAnimation:pulse forKey:@"pulse"];
}

- (void)mouseDragged:(NSEvent *)event {
    CGFloat x = event.locationInWindow.x;
    if (self.dragged) self.dragged(x - _lastX);
    _lastX = x;
}

- (void)mouseUp:(NSEvent *)event {
    _dragging = NO;
    if (!NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) [self setHighlighted:NO after:SNLiveResizerHideDelay];
    if (self.ended) self.ended();
}

@end

@implementation SNContentCard {
    CALayer *_border;
    NSView *_columns, *_sidebarColumn, *_headerColumn, *_primaryColumn, *_secondaryColumn;
    NSView *_headerView;
    SNResizer *_sidebarResizer, *_secondaryResizer;
    CGFloat _collapse;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    _sidebarWidth = 260;
    _secondaryWidth = 400;
    _sidebarMinimumWidth = SNSidebarMinimumWidth;

    // The 1 pt border lies over the window background, outside the columns' fills.
    _border = [CALayer layer];
    _border.borderWidth = 1;
    _border.borderColor = SNCGColor(SNColorOtlTer);
    _border.cornerRadius = kCardRadius;
    _columns = [[SNContainerView alloc] initWithFrame:NSZeroRect];
    _columns.wantsLayer = YES;
    _columns.layer.cornerRadius = kCardRadius - 1;
    _columns.layer.masksToBounds = YES;
    [self addSubview:_columns];
    [self.layer addSublayer:_border];

    _sidebarColumn = [self column:SNThemeSurfInvSec];
    _headerColumn = [self column:SNColorBasePry];
    _primaryColumn = [self column:SNColorBasePry];
    _secondaryColumn = [self column:SNColorBasePry];
    _secondaryColumn.hidden = YES;
    __weak SNContentCard *weakSelf = self;
    _sidebarResizer = [[SNResizer alloc] initWithFrame:NSZeroRect];
    _sidebarResizer.dragged = ^(CGFloat delta) {
        SNContentCard *card = weakSelf;
        card.sidebarWidth = [card clampedSidebarWidth:card.sidebarWidth + delta];
    };
    _secondaryResizer = [[SNResizer alloc] initWithFrame:NSZeroRect];
    _secondaryResizer.dragged = ^(CGFloat delta) {
        SNContentCard *card = weakSelf;
        card.secondaryWidth = [card clampedSecondaryWidth:card.secondaryWidth - delta];
    };
    _secondaryResizer.hidden = YES;
    _sidebarResizer.ended = _secondaryResizer.ended = ^{
        SNContentCard *card = weakSelf;
        if (card.widthsChanged) card.widthsChanged();
    };
    [_columns addSubview:_sidebarResizer];
    [_columns addSubview:_secondaryResizer];
    return self;
}

- (NSView *)column:(SNColorToken)fill {
    NSView *column = [[SNContainerView alloc] initWithFrame:NSZeroRect];
    column.wantsLayer = YES;
    column.layer.backgroundColor = SNCGColor(fill);
    [_columns addSubview:column];
    return column;
}

- (BOOL)isFlipped { return YES; }

static void Place(NSView *_Nullable view, NSView *column) {
    if (!view) return;
    if (view.superview != column) {
        [column addSubview:view];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    view.frame = column.bounds;
}

- (void)setSidebarView:(NSView *)sidebarView {
    [_sidebarView removeFromSuperview];
    _sidebarView = sidebarView;
    Place(sidebarView, _sidebarColumn);
}

- (void)setPrimaryView:(NSView *)primaryView {
    [_primaryView removeFromSuperview];
    [_headerView removeFromSuperview];
    _primaryView = primaryView;
    _headerView = [primaryView conformsToProtocol:@protocol(SNCardHeaderProvider)] ? ((id<SNCardHeaderProvider>)primaryView).cardHeaderView : nil;
    Place(primaryView, _primaryColumn);
    Place(_headerView, _headerColumn);
    self.needsLayout = YES;
}

- (void)setSecondaryView:(NSView *)secondaryView {
    [_secondaryView removeFromSuperview];
    _secondaryView = secondaryView;
    Place(secondaryView, _secondaryColumn);
}

- (void)setSidebarWidth:(CGFloat)sidebarWidth {
    _sidebarWidth = sidebarWidth;
    self.needsLayout = YES;
}

- (void)setSecondaryWidth:(CGFloat)secondaryWidth {
    _secondaryWidth = secondaryWidth;
    self.needsLayout = YES;
}

- (void)setSecondaryVisible:(BOOL)secondaryVisible {
    _secondaryVisible = secondaryVisible;
    _secondaryColumn.hidden = _secondaryResizer.hidden = !secondaryVisible;
    self.needsLayout = YES;
}

- (void)setSidebarCollapsed:(BOOL)sidebarCollapsed { [self setSidebarCollapsed:sidebarCollapsed animated:NO]; }

- (void)setSidebarCollapsed:(BOOL)collapsed animated:(BOOL)animated {
    _sidebarCollapsed = collapsed;
    _collapse = collapsed ? 1 : 0;
    if (!animated) {
        self.needsLayout = YES;
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kCollapse;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:.1 :1 :.2 :1];
        context.allowsImplicitAnimation = YES;
        self.needsLayout = YES;
        [self layoutSubtreeIfNeeded];
    }];
}

- (CGFloat)inner { return MAX(0, self.bounds.size.width - 2); }

- (CGFloat)clampedSecondaryWidth:(CGFloat)width {
    CGFloat room = self.inner - (self.sidebarCollapsed ? 0 : self.sidebarMinimumWidth + 1) - SNPrimaryMinimumWidth - 1;
    return MAX(SNSecondaryMinimumWidth, MIN(MIN(width, SNSecondaryMaximumWidth), room));
}

- (CGFloat)clampedSidebarWidth:(CGFloat)width {
    CGFloat secondary = self.secondaryVisible ? [self clampedSecondaryWidth:self.secondaryWidth] + 1 : 0;
    return MAX(self.sidebarMinimumWidth, MIN(width, self.inner - 1 - SNPrimaryMinimumWidth - secondary));
}

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _border.frame = bounds;
    [CATransaction commit];
    NSRect inner = NSInsetRect(bounds, 1, 1);
    _columns.frame = inner;
    CGFloat height = inner.size.height, width = inner.size.width;
    CGFloat sidebar = round([self clampedSidebarWidth:self.sidebarWidth] * (1 - _collapse));
    CGFloat secondary = self.secondaryVisible ? [self clampedSecondaryWidth:self.secondaryWidth] : 0;
    _sidebarColumn.frame = NSMakeRect(0, 0, sidebar, height);
    _sidebarResizer.hidden = _collapse >= 1;
    _sidebarResizer.frame = NSMakeRect(sidebar + 0.5 - kHitWidth / 2, 0, kHitWidth, height);
    CGFloat primaryX = sidebar + 1, primaryWidth = MAX(0, width - primaryX - (secondary ? secondary + 1 : 0));
    CGFloat header = _headerView ? MIN(height, _headerView.intrinsicContentSize.height) : 0, below = height - header;
    _headerColumn.frame = NSMakeRect(primaryX, 0, MAX(0, width - primaryX), header);
    _primaryColumn.frame = NSMakeRect(primaryX, header, primaryWidth, below);
    _secondaryColumn.frame = NSMakeRect(width - secondary, header, secondary, below);
    _secondaryResizer.frame = NSMakeRect(width - secondary - 0.5 - kHitWidth / 2, header, kHitWidth, below);
}

@end
