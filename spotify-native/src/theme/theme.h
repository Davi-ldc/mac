// Native macOS design tokens (colors, typography, spacing) matching Spotifly.
// Zero UI/AppKit imports: usable from render, layout, and headless tests alike.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    CGFloat r;
    CGFloat g;
    CGFloat b;
    CGFloat a;
    uint32_t hex; // 0xRRGGBB
} SPColorToken;

typedef struct {
    CGFloat size;
    CGFloat weight; // Matches NSFontWeight scale (-0.4..+0.62)
    CGFloat lineHeight;
    CGFloat tracking;
    BOOL monospacedDigits;
} SPTextStyle;

typedef struct {
    // Brand accents (Spotifly / Spotify green #1DB954)
    SPColorToken accent;
    SPColorToken accentHover;
    SPColorToken accentPressed;
    SPColorToken accentSubtle;

    // Native macOS surfaces (reference tokens; AppKit layer uses dynamic semantic NSColors)
    SPColorToken bgBase;
    SPColorToken bgSidebar;
    SPColorToken bgElevated;
    SPColorToken bgSurface;
    SPColorToken bgHover;
    SPColorToken bgSelected;
    SPColorToken bgNowPlayingBar;
    SPColorToken divider;
    SPColorToken focusRing;

    // Text hierarchy
    SPColorToken textPrimary;
    SPColorToken textSecondary;
    SPColorToken textTertiary;
    SPColorToken textOnAccent;
    SPColorToken textError;
    SPColorToken textWarning;
} SPColorPalette;

typedef struct {
    SPTextStyle display;
    SPTextStyle title1;
    SPTextStyle title2;
    SPTextStyle headline;
    SPTextStyle body;
    SPTextStyle bodyMedium;
    SPTextStyle callout;
    SPTextStyle caption;
    SPTextStyle monoTime;
} SPTypographyScale;

typedef struct {
    CGFloat spaceXS;
    CGFloat spaceSM;
    CGFloat spaceMD;
    CGFloat spaceLG;
    CGFloat spaceXL;
    CGFloat spaceXXL;
    CGFloat pageInset;

    CGFloat radiusSM;
    CGFloat radiusMD;
    CGFloat radiusLG;
    CGFloat radiusXL;
    CGFloat radiusPill;

    CGFloat sidebarWidth;
    CGFloat sidebarMinWidth;
    CGFloat sidebarMaxWidth;
    CGFloat libraryColumnWidth;
    CGFloat inspectorWidth;
    CGFloat toolbarHeight;
    CGFloat nowPlayingBarHeight;
    CGFloat nowPlayingBarMaxWidth;
    CGFloat nowPlayingBarBottomPadding;
    CGFloat nowPlayingContentClearance;
    CGFloat trackRowHeight;
    CGFloat cardWidth;
    CGFloat cardArtSize;
    CGFloat artistCardSize;
    CGFloat cardGap;
} SPLayoutMetrics;

/// Constructs a color token from 0xRRGGBB and alpha (0..1).
SPColorToken SPColorHex(uint32_t rgbHex, CGFloat alpha);

/// Creates an sRGB CGColorRef for CoreGraphics/CoreText drawing. Caller releases with CGColorRelease.
CGColorRef SPColorCreateCG(SPColorToken token) CF_RETURNS_RETAINED;

/// Canonical native macOS Dark Aqua palette (charcoal #1E1E1E + #1DB954 accent).
const SPColorPalette *SPThemeDarkPalette(void);

/// Canonical native macOS Light Aqua palette.
const SPColorPalette *SPThemeLightPalette(void);

/// Spotifly's signature Spotify green accent (#1DB954).
SPColorToken SPThemeAccentToken(void);

/// Canonical typography scale matching Spotifly on macOS.
const SPTypographyScale *SPThemeTypography(void);

/// Canonical layout & spacing constants matching Spotifly on macOS.
const SPLayoutMetrics *SPThemeMetrics(void);

NS_ASSUME_NONNULL_END
