// Owns the unreads switch's drawing and motion.
#import "ui/kit/label.h"
#import "ui/kit/toggle.h"

static const CGFloat kTrackWidth = 28, kTrackHeight = 18, kHandle = 12, kHandleInset = 3, kTravel = 10, kGap = 8;
static const CFTimeInterval kHandleDuration = 0.2, kColourDuration = 0.04;

@implementation SNUnreadsToggle {
    SNLabel *_label;
    SNLayer *_track, *_handle;
}

- (instancetype)initWithTitle:(NSString *)title {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.hoverColor = self.pressedColor = 0;
    _label = [SNLabel labelWithText:title font:SNFont(SNFontSizeMicro, SNFontWeightBold) color:SNThemeContentInvSec];
    _label.lineHeight = kTrackHeight;
    [self addSubview:_label];
    _track = [SNLayer layer];
    _track.cornerRadius = kTrackHeight / 2;
    _track.borderWidth = 1;
    _handle = [SNLayer layer];
    _handle.cornerRadius = kHandle / 2;
    [self.layer addSublayer:_track];
    [self.layer addSublayer:_handle];
    __weak SNUnreadsToggle *weakSelf = self;
    self.action = ^(SNUnreadsToggle *toggle) {
        [toggle setOn:!toggle.on animated:YES];
        if (weakSelf.changed) weakSelf.changed(toggle.on);
    };
    _inverse = YES;
    [self setOn:NO animated:NO];
    return self;
}

- (void)setInverse:(BOOL)inverse {
    _inverse = inverse;
    [self setOn:self.on animated:NO];
}

- (NSSize)fittingSize { return NSMakeSize(ceil(_label.textWidth) + kGap + kTrackWidth, kTrackHeight); }

- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    SNColorToken secondary = self.inverse ? SNThemeContentInvSec : SNColorContentSec, primary = self.inverse ? SNThemeContentInvPry : SNColorContentPry;
    SNColorToken line = on ? SNThemeContentImp : secondary;
    SNAnimate(animated ? kColourDuration : 0, [CAMediaTimingFunction functionWithControlPoints:0.45 :0 :0.55 :1], ^{
        self->_label.color = on ? primary : secondary;
        self->_track.backgroundColor = on ? SNCGColor(SNThemeBaseImp) : NULL;
        self->_track.borderColor = SNCGColor(line);
        self->_handle.backgroundColor = SNCGColor(line);
    });
    SNAnimate(animated ? kHandleDuration : 0, [CAMediaTimingFunction functionWithControlPoints:0.3 :0 :0.45 :1.4], ^{
        self->_handle.affineTransform = CGAffineTransformMakeTranslation(on ? kTravel : 0, 0);
    });
}

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    CGFloat trackX = size.width - kTrackWidth, top = (size.height - kTrackHeight) / 2;
    _label.frame = NSMakeRect(0, top, MAX(0, trackX - kGap), kTrackHeight);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.frame = CGRectMake(trackX, top, kTrackWidth, kTrackHeight);
    _handle.bounds = CGRectMake(0, 0, kHandle, kHandle);
    _handle.position = CGPointMake(trackX + kHandleInset + kHandle / 2, top + kTrackHeight / 2);
    [CATransaction commit];
}

@end
