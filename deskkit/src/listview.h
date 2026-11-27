// The sectioned list of rows: icon, title, subtitle and a right-aligned label.
#import <AppKit/AppKit.h>

#import "items.h"
#import "panel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DKListView : DKFlippedView
/// Shows the items, grouped under their section headers. With `keepSelection`, the row
/// with the same key stays selected (after a delete, the one that took its place).
- (void)setItems:(NSArray<DKItem *> *)items keepSelection:(BOOL)keepSelection;
@property(readonly, nullable) DKItem *selectedItem;
/// Moves to the next (1) or previous (-1) row, skipping headers.
- (void)moveSelection:(NSInteger)step;
/// Asks the rows on screen for their icons again, keeping everything else.
- (void)reloadIcons;
@property(copy, nullable) void (^onSelectionChange)(DKItem *_Nullable item);
/// A double click on a row; a single click only selects it.
@property(copy, nullable) void (^onActivate)(DKItem *item);
/// The mouse button went down on a row, which it selects; `onRelease` follows when the
/// button comes up. The second press of a double click is no press.
@property(copy, nullable) void (^onPress)(DKItem *item);
@property(copy, nullable) void (^onRelease)(void);
/// Draws the selected row brighter while it is held down, or as selected again.
- (void)showPressed:(BOOL)pressed;
@end

NS_ASSUME_NONNULL_END
