// Slack's icons by Slack's names ("star", "headphones", "ellipsis-vertical-filled"). Slack draws
// each icon as a 20x20 drawing scaled to a square box `size` points wide (its SvgIcon `size`
// prop), so callers pass the box Slack uses and lay it out where Slack's box is. The outlines
// are Slack's and are never published: `make` copies them from design/ into the bundle when they
// are there; without them (a public checkout) each name draws the closest SF Symbol, fitted to
// the share of the box Slack's glyph covers. The glyph is a tinted image in the layer's contents
// (not a mask: masks are costlier to composite and Core Animation's offscreen rendering ignores
// them), so a colour change inside SNAnimate cross-fades like a CSS colour transition.
#import <AppKit/AppKit.h>

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNIconLayer : SNLayer
/// A Slack icon name; nil draws nothing.
@property (nonatomic, copy, nullable) NSString *iconName;
/// Side of the icon's box in points, centred in the layer.
@property (nonatomic) CGFloat iconSize;
@property (nonatomic) SNColorToken color;
+ (instancetype)iconNamed:(nullable NSString *)name size:(CGFloat)size color:(SNColorToken)color;
@end

/// The icon's `size` point box in `color`, at `scale` pixels per point; cached. NULL for an
/// unknown name.
CGImageRef _Nullable SNIconImage(NSString *name, CGFloat size, SNColorToken color, CGFloat scale);
/// Draws the icon's box centred in `rect` of the current context, for views that draw many
/// glyphs in one -drawRect:.
void SNDrawIcon(NSString *name, CGFloat size, SNColorToken color, NSRect rect);
/// Whether Slack's outlines are in the bundle (otherwise icons are SF Symbols).
BOOL SNHasSlackIcons(void);
/// Every name the app draws: the names with an SF Symbol stand-in.
NSArray<NSString *> *SNIconNames(void);

NS_ASSUME_NONNULL_END
