// Menus and popovers (components.json popover, menu). A popover shows a view next to a target
// and closes on an outside click or Escape; both happen in one frame (measured live, despite the
// CSS fades). A menu is a popover of 28 pt rows highlighted in #0a77a7 by the pointer or the
// arrow keys.
#import <AppKit/AppKit.h>

#import "ui/kit/overlay.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNPopover : NSObject
/// Shows `content` at its current size on the `placement` side of `rect` (in `view`'s
/// coordinates), aligned with the rect's leading edge. Closes the popover already open; nil when
/// `view` is in no window. Closing gives the keyboard back to what had it, unless something
/// outside the popover took it meanwhile.
+ (nullable instancetype)showContent:(NSView *)content forRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement gap:(CGFloat)gap;
/// The open popover, if any.
+ (nullable SNPopover *)current;
/// nil once closed.
@property (nonatomic, readonly, nullable) NSView *content;
@property (nonatomic, copy, nullable) void (^onClose)(void);
- (void)close;
@end

@interface SNMenuItem : NSObject
+ (instancetype)itemWithTitle:(NSString *)title action:(nullable void (^)(void))action;
+ (instancetype)separator;
+ (instancetype)headerWithTitle:(NSString *)title;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *icon;
/// The icon's box: Slack's menus use 16 (view header), 18 (message actions) or 20 (composer).
@property (nonatomic) CGFloat iconSize;
/// Shown right-aligned in 13 pt #9a9b9e ("⌘K").
@property (nonatomic, copy, nullable) NSString *shortcut;
/// Opens a submenu: a caret at the right, centred 32 pt from the menu's edge.
@property (nonatomic) BOOL submenu;
@property (nonatomic) BOOL danger, checked, disabled;
@end

@interface SNMenu : NSView
/// 300 pt wide unless `width` is given (Slack's default).
- (instancetype)initWithItems:(NSArray<SNMenuItem *> *)items width:(CGFloat)width;
/// The highlighted row's index, or NSNotFound.
@property (nonatomic) NSUInteger highlightedIndex;
- (nullable SNPopover *)showForRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement;
@end

NS_ASSUME_NONNULL_END
