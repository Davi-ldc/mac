// 30 fps playing-track waveform via CALayer + CAKeyframeAnimation; pauses on pause, hide, or window occlusion.
#import "render/waveform.h"

#import <QuartzCore/QuartzCore.h>

static const NSUInteger kSPWaveformBarCount = 3;

@implementation SPWaveformView {
    NSMutableArray<CALayer *> *_bars;
    BOOL _animating;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _barColor = SPThemeDarkPalette()->accent;
    self.wantsLayer = YES;
    _bars = [NSMutableArray arrayWithCapacity:kSPWaveformBarCount];

    CGColorRef cg = SPColorCreateCG(_barColor);
    for (NSUInteger i = 0; i < kSPWaveformBarCount; i++) {
        CALayer *bar = [CALayer layer];
        bar.backgroundColor = cg;
        bar.cornerRadius = 1.0;
        bar.anchorPoint = CGPointMake(0.5, 0.0);
        [self.layer addSublayer:bar];
        [_bars addObject:bar];
    }
    CGColorRelease(cg);
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isAnimating {
    return _animating;
}

- (void)setBarColor:(SPColorToken)barColor {
    _barColor = barColor;
    CGColorRef cg = SPColorCreateCG(barColor);
    for (CALayer *bar in _bars) {
        bar.backgroundColor = cg;
    }
    CGColorRelease(cg);
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) return;
    _playing = playing;
    [self syncAnimationState];
}

- (void)setOccluded:(BOOL)occluded {
    if (_occluded == occluded) return;
    _occluded = occluded;
    [self syncAnimationState];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self syncAnimationState];
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat gap = 2.0;
    CGFloat barW = MAX(2.0, floor((w - gap * (kSPWaveformBarCount - 1)) / (CGFloat)kSPWaveformBarCount));
    CGFloat totalW = barW * kSPWaveformBarCount + gap * (kSPWaveformBarCount - 1);
    CGFloat startX = floor((w - totalW) * 0.5);
    static const CGFloat kIdleHeights[3] = {0.35, 0.65, 0.45};
    for (NSUInteger i = 0; i < _bars.count; i++) {
        CALayer *bar = _bars[i];
        CGFloat x = startX + (CGFloat)i * (barW + gap);
        bar.bounds = CGRectMake(0, 0, barW, MAX(2.0, h));
        bar.position = CGPointMake(x + barW * 0.5, 0.0);
        if (!_animating) {
            bar.transform = CATransform3DMakeScale(1.0, kIdleHeights[i], 1.0);
        }
    }
    [CATransaction commit];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (self.window) {
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSWindowDidChangeOcclusionStateNotification
                                                    object:self.window];
    }
    [super viewWillMoveToWindow:newWindow];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(windowOcclusionChanged:)
                                                   name:NSWindowDidChangeOcclusionStateNotification
                                                 object:self.window];
        _occluded = (self.window.occlusionState & NSWindowOcclusionStateVisible) == 0;
    } else {
        _occluded = YES;
    }
    [self syncAnimationState];
}

- (void)windowOcclusionChanged:(NSNotification *)note {
    NSWindow *win = note.object;
    if (!win) return;
    _occluded = (win.occlusionState & NSWindowOcclusionStateVisible) == 0;
    [self syncAnimationState];
}

- (void)syncAnimationState {
    BOOL shouldAnimate = _playing && !self.hidden && !_occluded && self.window != nil;
    if (shouldAnimate == _animating) return;
    _animating = shouldAnimate;

    if (!shouldAnimate) {
        static const CGFloat kIdleHeights[3] = {0.35, 0.65, 0.45};
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (NSUInteger i = 0; i < _bars.count; i++) {
            [_bars[i] removeAnimationForKey:@"sp.waveform"];
            _bars[i].transform = CATransform3DMakeScale(1.0, kIdleHeights[i], 1.0);
        }
        [CATransaction commit];
        return;
    }

    NSArray<NSArray<NSNumber *> *> *keyValues = @[
        @[ @0.25, @0.92, @0.40, @0.75, @0.25 ],
        @[ @0.85, @0.30, @0.96, @0.45, @0.85 ],
        @[ @0.45, @0.78, @0.22, @0.90, @0.45 ],
    ];
    static const CFTimeInterval kDurations[3] = {0.68, 0.56, 0.74};

    for (NSUInteger i = 0; i < _bars.count; i++) {
        CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
        anim.values = keyValues[i];
        anim.duration = kDurations[i];
        anim.repeatCount = HUGE_VALF;
        anim.removedOnCompletion = NO;
        anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        anim.preferredFrameRateRange = CAFrameRateRangeMake(24.0f, 30.0f, 30.0f);
        [_bars[i] addAnimation:anim forKey:@"sp.waveform"];
    }
}

@end
