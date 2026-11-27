// Raycast's look, shared by every view of the picker. The numbers come from Raycast's own
// design tokens (its frontend stylesheet) and from measuring its windows on this Mac.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat DKPanelWidth = 750, DKPanelHeight = 475, DKPanelRadius = 26;
static const CGFloat DKHeaderHeight = 64;
/// Distance from the panel edge to a row's highlight, and from the highlight to its content.
static const CGFloat DKInset = 8;
static const CGFloat DKRowHeight = 38, DKRowRadius = 8, DKIconSize = 22, DKIconGap = 12;
/// A section header's height; every header but the first also has a gap above it.
static const CGFloat DKSectionHeight = 24, DKSectionGap = 8;
/// Width of the detail pane in the list-and-detail layout.
static const CGFloat DKDetailWidth = 465;
static const CGFloat DKPillHeight = 36, DKFooterHeight = DKPillHeight + 2 * DKInset;

/// Inter, the typeface Raycast draws with, at a variable-font weight (400 regular, 500
/// medium, 600 semibold). Falls back to the system font if Inter cannot be loaded.
NSFont *DKFont(CGFloat size, CGFloat weight);
/// Raycast's letter spacing for a size and weight of Inter, in points.
CGFloat DKTracking(CGFloat size, CGFloat weight);

NSColor *DKTextPrimary(void);
NSColor *DKTextSecondary(void);
/// Placeholders and the search bar's logo.
NSColor *DKTextTertiary(void);
/// White at the given opacity: Raycast's fills, borders and separators are all of this kind.
NSColor *DKWhite(CGFloat alpha);

/// A text field that is only a label.
NSTextField *DKLabel(NSString *text, NSFont *font, NSColor *color);

/// Raycast's date style: "16 Nov 2026 at 11:14:52", "Today at 00:52:47".
NSString *DKFormatDate(NSDate *date);

NS_ASSUME_NONNULL_END
