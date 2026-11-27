// The sidebar's list (ui/kit/list.h) of fixed-height entries, with Slack's overlay scrollbar that
// shows while the pointer is over the list (effects.txt A22) and the keyboard moving between rows
// as in Slack's tree (Up and Down, no wrapping; Return or Space acts).
#import <AppKit/AppKit.h>

#import "ui/kit/list.h"
#import "ui/sidebar/row.h"

NS_ASSUME_NONNULL_BEGIN

@class SNSidebarListView;

@protocol SNSidebarListDelegate <SNSidebarRowDelegate>
- (SNSidebarRowState *)sidebarList:(SNSidebarListView *)list stateForItem:(SNSidebarItem *)item;
/// Shift-Tab on a row: Slack gives the keyboard back to the filter field.
- (void)sidebarListShiftTabbed:(SNSidebarListView *)list;
@end

@interface SNSidebarListView : SNListView
@property (nonatomic, weak, nullable) id<SNSidebarListDelegate> delegate;
@property (nonatomic, readonly) NSArray<SNSidebarItem *> *items;
/// Replaces the entries; rows on screen keep their views when their key stays. refreshKeys: asks
/// the delegate again for those entries' state.
- (void)showItems:(NSArray<SNSidebarItem *> *)items;
/// The row on screen for `key`, if any.
- (nullable SNSidebarRowView *)rowForKey:(NSString *)key;
- (nullable SNSidebarItem *)itemForKey:(NSString *)key;
/// The entry's rect in the list's content.
- (NSRect)rectForKey:(NSString *)key;
/// Hovers the row as the pointer would (nil: none).
- (void)hoverKey:(nullable NSString *)key;
/// Scrolls the least needed to show the entry.
- (void)revealKey:(NSString *)key;
/// The overlay scrollbar, visible while hovered.
@property (nonatomic, readonly) CALayer *scrollThumb;
/// The entry with the keyboard, drawn with the focus ring while the list is first responder.
@property (nonatomic, readonly, nullable) NSString *focusedKey;
/// Gives the list the keyboard on the first entry that takes it (Down from the filter field);
/// NO when none does.
- (BOOL)focusFirstItem;
@end

NS_ASSUME_NONNULL_END
