// Native macOS SF Symbols, semantic Light/Dark colors, Liquid Glass helper, typography, and artwork drawing.
#import <AppKit/AppKit.h>

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPIconName) {
    SPIconHome = 0,
    SPIconSearch,
    SPIconHeart,
    SPIconHeartFilled,
    SPIconAlbum,
    SPIconArtist,
    SPIconPlaylist,
    SPIconBack,
    SPIconForward,
    SPIconClose,
    SPIconPlay,
    SPIconPause,
    SPIconNext,
    SPIconPrevious,
    SPIconShuffle,
    SPIconRepeat,
    SPIconRepeatOne,
    SPIconSpeaker,
    SPIconSpeakerLow,
    SPIconSpeakerMute,
    SPIconDevices,
    SPIconQueue,
    SPIconSettings,
    SPIconPlus,
    SPIconMore,
    SPIconCheck,
    SPIconMusicNote,
    // Extended Spotifly SF Symbols
    SPIconRefresh,
    SPIconScrollToCurrent,
    SPIconInspector,
    SPIconSidebarLeft,
    SPIconShare,
    SPIconProfile,
    SPIconPersonFill,
    SPIconSquareStack,
    SPIconDevicesOutline,
    SPIconSpeakerMed,
    SPIconLaptop,
    SPIconPhone,
    SPIconTablet,
    SPIconTV,
    SPIconCopy,
    SPIconArrowUpRight,
    SPIconCommand,
    SPIconTrash,
    SPIconPencil,
    SPIconLink,
    SPIconRadio,
    SPIconExclamation,
};

#pragma mark - Semantic macOS Colors (adapt automatically to Light & Dark Mode)

/// Spotifly's signature Spotify green accent (#1DB954).
NSColor *SPAccentColor(void);
NSColor *SPAccentHoverColor(void);
NSColor *SPAccentPressedColor(void);

/// System semantic colors following macOS Light / Dark appearance automatically.
NSColor *SPWindowBackgroundColor(void);
NSColor *SPControlBackgroundColor(void);
NSColor *SPUnderPageBackgroundColor(void);
NSColor *SPLabelColor(void);
NSColor *SPSecondaryLabelColor(void);
NSColor *SPTertiaryLabelColor(void);
NSColor *SPQuaternaryFillColor(void);
NSColor *SPSeparatorColor(void);
NSColor *SPHoverFillColor(void);
NSColor *SPSelectedRowFillColor(void);
NSColor *SPHeartRedColor(void);
NSColor *SPCardSurfaceColor(void);

/// Returns YES if `appearance` (or current effective appearance) is Dark Aqua.
BOOL SPIsDarkAppearance(NSAppearance *_Nullable appearance);

/// Converts a theme color token into an sRGB NSColor.
NSColor *SPNSColor(SPColorToken token);

/// Converts a theme text style into an NSFont (with monospaced digits when requested).
NSFont *SPNSFont(SPTextStyle style);

/// Builds attributed-string attributes with a fixed SPColorToken.
NSDictionary<NSAttributedStringKey, id> *SPTextAttributes(SPTextStyle style,
                                                          SPColorToken color,
                                                          NSLineBreakMode lineBreak,
                                                          NSTextAlignment alignment);

/// Builds attributed-string attributes with a dynamic semantic NSColor.
NSDictionary<NSAttributedStringKey, id> *SPSemanticTextAttributes(SPTextStyle style,
                                                                  NSColor *color,
                                                                  NSLineBreakMode lineBreak,
                                                                  NSTextAlignment alignment);

#pragma mark - SF Symbols

/// Canonical macOS SF Symbol name for `SPIconName`.
NSString *SPSFSymbolNameForIcon(SPIconName icon);

/// Creates a crisp configured SF Symbol NSImage (template if tintColor == nil, palette-tinted otherwise).
NSImage *_Nullable SPSFSymbolImage(NSString *symbolName,
                                   CGFloat pointSize,
                                   NSFontWeight weight,
                                   NSColor *_Nullable tintColor);

/// Draws a crisp SF Symbol centered in `rect` inside the current AppKit/CoreGraphics drawing context.
void SPDrawSFSymbol(NSString *symbolName,
                    CGRect rect,
                    CGFloat pointSize,
                    NSFontWeight weight,
                    NSColor *color);

/// Draws a crisp SF Symbol for `SPIconName` centered in `rect` with `SPColorToken`.
void SPDrawIcon(CGContextRef ctx, SPIconName icon, CGRect rect, SPColorToken color);

/// Draws a crisp SF Symbol for `SPIconName` centered in `rect` with semantic `NSColor`.
void SPDrawIconSemantic(SPIconName icon, CGRect rect, CGFloat pointSize, NSFontWeight weight, NSColor *color);

/// Creates a template-free NSImage for menus/buttons without retaining bitmap caches.
NSImage *SPIconImage(SPIconName icon, CGFloat pointSize, SPColorToken color);

#pragma mark - Formatting & Artwork

/// Formats milliseconds as `m:ss` or `h:mm:ss` (e.g. `3:45`).
NSString *SPFormatDurationMs(int64_t ms);

/// Formats a total list duration in Spotifly style (e.g. `1 hr 12 min` or `42 min`).
NSString *SPFormatTotalDurationMs(int64_t totalMs);

/// Draws a rounded or circular artwork bitmap, or a semantic placeholder with SF Symbol if `image == NULL`.
void SPDrawRoundedArtwork(CGContextRef ctx,
                          CGImageRef _Nullable image,
                          CGRect rect,
                          CGFloat radius,
                          BOOL circular,
                          SPColorToken placeholderBg,
                          SPColorToken placeholderIcon);

/// Draws a rounded or circular artwork with semantic placeholder, custom SF Symbol, and optional soft shadow.
void SPDrawArtworkSemantic(CGContextRef ctx,
                           CGImageRef _Nullable image,
                           CGRect rect,
                           CGFloat radius,
                           BOOL circular,
                           NSString *placeholderSymbol,
                           CGFloat symbolSize,
                           CGFloat shadowRadius);

/// Draws the Liked Songs / Favorites gradient tile with a centered white heart SF Symbol.
/// `purpleStyle = YES` renders Spotify's blue-purple Startpage gradient; `NO` renders Spotifly's pink-red Favorites header gradient.
void SPDrawLikedSongsTile(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL purpleStyle);

/// Draws a circular user profile avatar photo or Spotifly's #1DB954 green gradient initials circle.
void SPDrawProfileAvatar(CGContextRef ctx,
                         CGImageRef _Nullable image,
                         NSString *_Nullable displayName,
                         CGRect rect);

#pragma mark - Liquid Glass Helper (macOS 26/27 NSGlassEffectView with NSVisualEffectView fallback)

/// Wraps `contentView` in a real macOS Liquid Glass `NSGlassEffectView` (macOS 26+) or translucent `NSVisualEffectView` fallback.
NSView *SPCreateGlassContainerView(NSRect frame, CGFloat cornerRadius, NSView *contentView);

/// Updates the corner radius of a glass container returned by `SPCreateGlassContainerView`.
void SPUpdateGlassContainerCornerRadius(NSView *glassContainer, CGFloat cornerRadius);

NS_ASSUME_NONNULL_END
