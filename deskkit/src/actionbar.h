// The bottom bar: two floating pills, the screen on the left and its actions on the right.
#import <AppKit/AppKit.h>

#import "items.h"
#import "panel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DKActionBar : DKFlippedView
/// Left pill: the screen's icon and title, or Raycast's round menu button on the root.
- (void)showScreen:(nullable DKScreen *)screen;
/// Right pill: the primary action with its shortcut, then "Actions ⌘K" when there are more.
- (void)showPrimaryTitle:(nullable NSString *)title shortcut:(nullable DKShortcut *)shortcut hasMore:(BOOL)hasMore;
@property(copy, nullable) void (^onPrimary)(void);
@property(copy, nullable) void (^onActions)(void);
@end

NS_ASSUME_NONNULL_END
