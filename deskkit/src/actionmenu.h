// The ⌘K menu: every action of the selected row, with its shortcut and a filter field.
#import <AppKit/AppKit.h>

#import "items.h"
#import "panel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DKActionMenu : DKFlippedView
/// Sizes itself to the actions, under `title` when there is one, and anchors its
/// bottom-right corner at `corner`.
- (void)showActions:(NSArray<DKAction *> *)actions title:(nullable NSString *)title anchoredAt:(NSPoint)corner;
@property(readonly) NSTextField *filterField;
- (void)moveSelection:(NSInteger)step;
@property(readonly, nullable) DKAction *selectedAction;
/// Clicking a row.
@property(copy, nullable) void (^onChoose)(DKAction *action);
@end

NS_ASSUME_NONNULL_END
