// Tooltips, menus, popovers and hover cards live in one transparent layer above a window's
// content, the way the web client draws them inside its page: no extra windows, clipped to the
// window, and part of the window's own picture (so snapshots include them).
#import <AppKit/AppKit.h>

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNOverlayHost : NSView
/// The window's host, created on first use and kept above the rest of the content; nil without a
/// window.
+ (nullable instancetype)hostForWindow:(nullable NSWindow *)window;
/// While set, clicks anywhere outside the overlays call it instead of reaching the content
/// (how an open menu or popover closes on an outside click).
@property (nonatomic, copy, nullable) void (^outsideClick)(void);
@end

/// Menus' ring and shadow (components.json menu), shared by popovers, peeks and lists over the
/// content.
static const SNShadowStack SNMenuShadow = {2, {{0, 0, 0, 1, SNMeasuredMenuBorder, NO}, {0, 4, 12, 0, 0x0000001f, NO}}};

/// The surface menus, popovers and hover cards share: a rounded fill with an outer ring and a
/// drop shadow (components.json: menu, profile_hover_card), whose `contentView` clips to it.
@interface SNPanelView : NSView
- (instancetype)initWithFill:(SNColorToken)fill radius:(CGFloat)radius shadow:(SNShadowStack)shadow;
@property (nonatomic, readonly) NSView *contentView;
@end

typedef NS_ENUM(NSInteger, SNPlacement) {
    SNPlacementAbove,
    SNPlacementBelow,
    SNPlacementLeft,
    SNPlacementRight,
};

/// Where an overlay of `size` goes next to `target` (both in the overlay host's flipped
/// coordinates): on the `placement` side at `gap`, centred on the target or aligned with its
/// leading edge, on the opposite side when it does not fit there, and kept inside `bounds`.
NSRect SNPlaceOverlay(NSSize size, NSRect target, SNPlacement placement, CGFloat gap, BOOL centred, NSRect bounds);
/// The side SNPlaceOverlay actually used for `frame`.
SNPlacement SNPlacementOf(NSRect frame, NSRect target);

NS_ASSUME_NONNULL_END
