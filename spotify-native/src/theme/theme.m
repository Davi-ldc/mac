// Native macOS palette, typography, and layout constants matching Spotifly 1:1.
#import "theme/theme.h"

SPColorToken SPColorHex(uint32_t rgbHex, CGFloat alpha) {
    CGFloat r = (CGFloat)((rgbHex >> 16) & 0xFF) / 255.0;
    CGFloat g = (CGFloat)((rgbHex >> 8) & 0xFF) / 255.0;
    CGFloat b = (CGFloat)(rgbHex & 0xFF) / 255.0;
    return (SPColorToken){r, g, b, alpha, rgbHex & 0xFFFFFFu};
}

CGColorRef SPColorCreateCG(SPColorToken token) {
    static CGColorSpaceRef sRGB = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    CGFloat components[4] = {token.r, token.g, token.b, token.a};
    return CGColorCreate(sRGB, components);
}

SPColorToken SPThemeAccentToken(void) {
    return SPColorHex(0x1DB954, 1.0);
}

const SPColorPalette *SPThemeDarkPalette(void) {
    static SPColorPalette palette;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palette.accent = SPColorHex(0x1DB954, 1.0);
        palette.accentHover = SPColorHex(0x1ED760, 1.0);
        palette.accentPressed = SPColorHex(0x169C46, 1.0);
        palette.accentSubtle = SPColorHex(0x1DB954, 0.20);

        // macOS Dark Aqua charcoal surfaces (not #121212 web-clone black)
        palette.bgBase = SPColorHex(0x1E1E1E, 1.0);
        palette.bgSidebar = SPColorHex(0x282828, 1.0);
        palette.bgElevated = SPColorHex(0x262626, 1.0);
        palette.bgSurface = SPColorHex(0x323232, 1.0);
        palette.bgHover = SPColorHex(0xFFFFFF, 0.06);
        palette.bgSelected = SPColorHex(0x1DB954, 0.22);
        palette.bgNowPlayingBar = SPColorHex(0x2A2A2A, 0.88);
        palette.divider = SPColorHex(0xFFFFFF, 0.10);
        palette.focusRing = SPColorHex(0x1DB954, 0.55);

        palette.textPrimary = SPColorHex(0xFFFFFF, 0.92);
        palette.textSecondary = SPColorHex(0xFFFFFF, 0.58);
        palette.textTertiary = SPColorHex(0xFFFFFF, 0.36);
        palette.textOnAccent = SPColorHex(0xFFFFFF, 1.0);
        palette.textError = SPColorHex(0xFF453A, 1.0);
        palette.textWarning = SPColorHex(0xFFD60A, 1.0);
    });
    return &palette;
}

const SPColorPalette *SPThemeLightPalette(void) {
    static SPColorPalette palette;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palette.accent = SPColorHex(0x1DB954, 1.0);
        palette.accentHover = SPColorHex(0x1AA34A, 1.0);
        palette.accentPressed = SPColorHex(0x15873D, 1.0);
        palette.accentSubtle = SPColorHex(0x1DB954, 0.16);

        palette.bgBase = SPColorHex(0xFFFFFF, 1.0);
        palette.bgSidebar = SPColorHex(0xF2F2F7, 1.0);
        palette.bgElevated = SPColorHex(0xF5F5F7, 1.0);
        palette.bgSurface = SPColorHex(0xE8E8ED, 1.0);
        palette.bgHover = SPColorHex(0x000000, 0.05);
        palette.bgSelected = SPColorHex(0x1DB954, 0.18);
        palette.bgNowPlayingBar = SPColorHex(0xF6F6F6, 0.88);
        palette.divider = SPColorHex(0x000000, 0.10);
        palette.focusRing = SPColorHex(0x1DB954, 0.50);

        palette.textPrimary = SPColorHex(0x000000, 0.88);
        palette.textSecondary = SPColorHex(0x000000, 0.55);
        palette.textTertiary = SPColorHex(0x000000, 0.32);
        palette.textOnAccent = SPColorHex(0xFFFFFF, 1.0);
        palette.textError = SPColorHex(0xFF3B30, 1.0);
        palette.textWarning = SPColorHex(0xFF9500, 1.0);
    });
    return &palette;
}

const SPTypographyScale *SPThemeTypography(void) {
    static const SPTypographyScale scale = {
        .display    = {30.0, 0.40, 36.0, -0.5, NO},  // DetailHeader title / LargeTitle
        .title1     = {22.0, 0.40, 28.0, -0.3, NO},  // Large section / profile title
        .title2     = {17.0, 0.40, 22.0, -0.2, NO},  // SectionHeader (.title2.bold)
        .headline   = {13.0, 0.30, 18.0, -0.1, NO},  // Card title / inspector header (.headline)
        .body       = {13.0, 0.00, 18.0,  0.0, NO},  // Standard macOS body text
        .bodyMedium = {13.0, 0.23, 18.0,  0.0, NO},  // Track title / active sidebar item
        .callout    = {12.0, 0.00, 16.0,  0.0, NO},  // Subheadline / subtitle (.subheadline)
        .caption    = {11.0, 0.00, 14.0,  0.0, NO},  // Metadata / badge / sidebar header
        .monoTime   = {11.0, 0.00, 14.0,  0.0, YES}, // Tabular track duration / elapsed / rank
    };
    return &scale;
}

const SPLayoutMetrics *SPThemeMetrics(void) {
    static const SPLayoutMetrics metrics = {
        .spaceXS = 4.0,
        .spaceSM = 8.0,
        .spaceMD = 12.0,
        .spaceLG = 16.0,
        .spaceXL = 24.0,
        .spaceXXL = 32.0,
        .pageInset = 28.0,

        .radiusSM = 4.0,
        .radiusMD = 7.0,
        .radiusLG = 8.0,
        .radiusXL = 10.0,
        .radiusPill = 999.0,

        .sidebarWidth = 185.0,
        .sidebarMinWidth = 145.0,
        .sidebarMaxWidth = 280.0,
        .libraryColumnWidth = 260.0,
        .inspectorWidth = 320.0,
        .toolbarHeight = 52.0,
        .nowPlayingBarHeight = 64.0,
        .nowPlayingBarMaxWidth = 780.0,
        .nowPlayingBarBottomPadding = 14.0,
        .nowPlayingContentClearance = 98.0, // 64 + 14 + 20
        .trackRowHeight = 46.0,
        .cardWidth = 150.0,
        .cardArtSize = 150.0,
        .artistCardSize = 130.0,
        .cardGap = 16.0,
    };
    return &metrics;
}
