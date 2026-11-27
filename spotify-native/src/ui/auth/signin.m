// Native macOS Spotifly 1:1 Sign-In screen (adapts to Light & Dark Mode automatically).
#import "ui/auth/signin.h"
#import "render/icons.h"
#import "theme/theme.h"
#import "ui/kit/controls.h"

@implementation SPSignInView {
    SPButton *_connectButton;
    NSProgressIndicator *_spinner;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _connectButton = [SPButton pillButtonWithTitle:@"Connect with Spotify" style:SPButtonStylePrimary frame:NSZeroRect];
    __weak typeof(self) weakSelf = self;
    _connectButton.onClick = ^{
        SPSignInView *s = weakSelf;
        if (!s) return;
        if (s.loading) {
            if (s.onCancel) s.onCancel();
        } else {
            if (s.onSignIn) s.onSignIn();
        }
    };
    [self addSubview:_connectButton];

    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.hidden = YES;
    [self addSubview:_spinner];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setLoading:(BOOL)loading {
    _loading = loading;
    _connectButton.title = loading ? @"Waiting for your browser — cancel" : @"Connect with Spotify";
    _spinner.hidden = !loading;
    if (loading) [_spinner startAnimation:nil];
    else [_spinner stopAnimation:nil];
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (void)setStatusMessage:(NSString *)statusMessage {
    _statusMessage = [statusMessage copy];
    self.needsDisplay = YES;
}

- (void)setErrorMessage:(NSString *)errorMessage {
    _errorMessage = [errorMessage copy];
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CGFloat cx = floor(self.bounds.size.width * 0.5);
    CGFloat cy = floor(self.bounds.size.height * 0.5);
    CGFloat btnW = _loading ? 264.0 : 210.0;
    _connectButton.frame = NSMakeRect(cx - floor(btnW * 0.5), cy + 44.0, btnW, 34.0);
    _spinner.frame = NSMakeRect(NSMinX(_connectButton.frame) - 24.0, cy + 53.0, 16.0, 16.0);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    CGContextSetFillColorWithColor(ctx, SPWindowBackgroundColor().CGColor);
    CGContextFillRect(ctx, self.bounds);

    CGFloat cx = floor(self.bounds.size.width * 0.5);
    CGFloat cy = floor(self.bounds.size.height * 0.5);

    // Spotifly ContentView: 60pt music.note.list SF Symbol in #1DB954 green
    SPDrawSFSymbol(@"music.note.list", CGRectMake(cx - 38.0, cy - 118.0, 76.0, 72.0),
                   56.0, NSFontWeightRegular, SPAccentColor());

    [@"Spotify" drawInRect:NSMakeRect(cx - 180.0, cy - 38.0, 360.0, 38.0)
            withAttributes:SPSemanticTextAttributes(typo->display, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];

    [@"Connect your Spotify account to get started. This authorizes Spotify in your browser."
        drawInRect:NSMakeRect(cx - 165.0, cy + 2.0, 330.0, 36.0)
    withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByWordWrapping, NSTextAlignmentCenter)];

    if (_errorMessage.length) {
        [_errorMessage drawInRect:NSMakeRect(cx - 210.0, cy + 92.0, 420.0, 36.0)
                   withAttributes:SPSemanticTextAttributes(typo->caption, NSColor.systemRedColor, NSLineBreakByWordWrapping, NSTextAlignmentCenter)];
    } else if (_statusMessage.length) {
        [_statusMessage drawInRect:NSMakeRect(cx - 210.0, cy + 92.0, 420.0, 30.0)
                    withAttributes:SPSemanticTextAttributes(typo->caption, SPSecondaryLabelColor(), NSLineBreakByWordWrapping, NSTextAlignmentCenter)];
    }
}

@end
