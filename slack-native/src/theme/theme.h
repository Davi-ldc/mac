// Slack's look in AppKit terms: the generated tokens (tokens.h) plus the bundled fonts, colours
// as NSColor/CGColor, and the CSS rules (line boxes, overlays) the web client lays text out by.
#import <AppKit/AppKit.h>

#import "theme/tokens.h"

NS_ASSUME_NONNULL_BEGIN

/// Slack's CSS draws hairlines and borders in rgba(foreground-low, .13) and faint fills in
/// rgba(foreground-min, .04).
static const SNColorToken SNLegacyHairline = (SNLegacyForegroundLow & 0xffffff00) | 0x21;
static const SNColorToken SNLegacyFaintFill = (SNLegacyForegroundMin & 0xffffff00) | 0x0a;

NSColor *SNColor(SNColorToken token);
/// Cached for the life of the process; callers neither retain nor release it.
CGColorRef SNCGColor(SNColorToken token);
SNColorToken SNColorWithAlpha(SNColorToken token, CGFloat alpha);
/// CSS filter brightness(): the colour's channels times `factor`, alpha unchanged.
SNColorToken SNColorBrightness(SNColorToken token, CGFloat factor);
/// `top` composited over `bottom` with source-over, which is also what 'lighten' gives for
/// Slack's overlays: they are lighter than every surface they are drawn on.
SNColorToken SNColorOver(SNColorToken top, SNColorToken bottom);

/// Slack-Lato at a CSS weight. CSS picks the nearest bundled face (300, 400, 700, 900) the way a
/// browser does, so 500 draws as 400 and 600 as 700.
NSFont *SNFont(CGFloat size, CGFloat weight);
NSFont *SNItalicFont(CGFloat size, CGFloat weight);
/// Slack-Roboto-Mono at any weight of its axis.
NSFont *SNMonoFont(CGFloat size, CGFloat weight);

/// Where a CSS line box of `lineHeight` puts the baseline, from the top of the line. Browsers
/// split the leading evenly above and below the font's rounded ascent and descent.
CGFloat SNBaselineOffset(NSFont *font, CGFloat lineHeight);

/// Gives `layer` the stack's outer shadows. A CSS ring (no offset, no blur, a spread) is a
/// border outside the box, so it becomes a sublayer grown by the spread; of the other shadows
/// the one with the largest blur becomes the layer's shadow, since Core Animation draws one
/// shadow per layer and has no spread (the spread grows or shrinks the shadow path instead).
/// The layer must not mask to its bounds. Call again when the layer is resized.
void SNApplyShadow(CALayer *layer, SNShadowStack stack);

/// Runs `changes` as one animation of `duration` and `timing`: changes to SNLayers animate, and
/// view frames too. A zero duration makes them instant.
void SNAnimate(CFTimeInterval duration, CAMediaTimingFunction *_Nullable timing, void (^changes)(void));

/// A layer whose property changes animate inside SNAnimate and are instant outside it. Core
/// Animation's implicit animations are not relied on: they depend on whether the layer belongs
/// to a view and has been on screen, and come with their own 0.25 s timing.
@interface SNLayer : CALayer
@end

NS_ASSUME_NONNULL_END
