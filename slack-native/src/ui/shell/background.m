// Owns the two gradient layers of the window background.
#import "theme/theme.h"
#import "ui/shell/background.h"

/// CSS filter brightness() of the background in an inactive window.
static const CGFloat kInactiveBrightness = 0.9;

@implementation SNBackgroundView {
    CAGradientLayer *_conic, *_radial;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    // The gradient squares overhang the window.
    self.clipsToBounds = YES;
    _conic = [CAGradientLayer layer];
    _conic.type = kCAGradientLayerConic;
    _radial = [CAGradientLayer layer];
    _radial.type = kCAGradientLayerRadial;
    [self.layer addSublayer:_conic];
    [self.layer addSublayer:_radial];
    [self applyColors];
    return self;
}

- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)setDimmed:(BOOL)dimmed {
    if (dimmed == _dimmed) return;
    _dimmed = dimmed;
    [self applyColors];
}

- (void)applyColors {
    CGFloat brightness = self.dimmed ? kInactiveBrightness : 1;
    void (^fill)(CAGradientLayer *, const SNGradientStop *, NSUInteger) = ^(CAGradientLayer *layer, const SNGradientStop *stops, NSUInteger count) {
        NSMutableArray *colors = [NSMutableArray new], *locations = [NSMutableArray new];
        for (NSUInteger i = 0; i < count; i++) {
            [colors addObject:(__bridge id)SNCGColor(SNColorBrightness(stops[i].color, brightness))];
            [locations addObject:@(stops[i].location)];
        }
        layer.colors = colors;
        layer.locations = locations;
    };
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    fill(_conic, SNWindowConicStops, SNWindowConicStopCount);
    fill(_radial, SNWindowRadialStops, SNWindowRadialStopCount);
    [CATransaction commit];
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Core Animation lays gradients out in the layer's unit square, so angles and circles come
    // out true only on a square layer: both are squares centred on the window that reach its
    // corners, which is also the radius of CSS's "circle" (farthest corner).
    CGRect bounds = self.bounds;
    CGFloat side = ceil(hypot(bounds.size.width, bounds.size.height));
    CGRect square = CGRectMake(CGRectGetMidX(bounds) - side / 2, CGRectGetMidY(bounds) - side / 2, side, side);
    _conic.frame = _radial.frame = square;
    // Core Animation's conic gradient turns counter-clockwise on screen and CSS's clockwise; the
    // stops are symmetric, so only the start direction matters: 45° clockwise from the top, up
    // and to the right in this unflipped view.
    CGFloat angle = SNWindowConicStartDegrees * M_PI / 180;
    _conic.startPoint = CGPointMake(0.5, 0.5);
    _conic.endPoint = CGPointMake(0.5 + sin(angle) / 2, 0.5 + cos(angle) / 2);
    _radial.startPoint = CGPointMake(0.5, 0.5);
    _radial.endPoint = CGPointMake(1, 1);
    [CATransaction commit];
}

@end
