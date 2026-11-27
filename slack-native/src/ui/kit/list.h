// The one scrolling list every list of the app is made on (sidebar, DMs, Activity, the pickers):
// keyed entries laid out once per change, rows made only for what is in view and reused by key,
// and one tracking area that hovers them. A subclass makes and fills its rows and says how tall
// each entry is at a width; it keeps its entries, the list only their keys.
#import <AppKit/AppKit.h>

#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNListView : NSView
@property (nonatomic, readonly) NSScrollView *scrollView;
/// The rows' superview, flipped; a subclass may add views over them (added rows go under).
@property (nonatomic, readonly) NSView *documentView;
/// Space above the first entry and under the last.
@property (nonatomic) CGFloat topInset, bottomInset;
/// Rows kept beyond the visible part, so a short scroll reuses nothing.
@property (nonatomic) CGFloat overscan;
@property (nonatomic, readonly) NSArray<NSString *> *keys;
/// Replaces the entries and measures them; rows on screen whose key stays keep their view and are
/// filled again.
- (void)showKeys:(NSArray<NSString *> *)keys;
/// Fills the rows on screen of these entries again; heights stay.
- (void)refreshKeys:(NSSet<NSString *> *)keys;
/// Measures every entry again (what decides heights changed), keeping the rows.
- (void)remeasure;
/// NSNotFound when not listed.
- (NSUInteger)indexOfKey:(NSString *)key;
- (nullable __kindof SNHoverView *)rowAtIndex:(NSUInteger)index;
/// The entry's rect in the document.
- (NSRect)rectOfIndex:(NSUInteger)index;
/// The entry at `y` in the document; NSNotFound past the ends.
- (NSUInteger)indexAtY:(CGFloat)y;
/// The entry the pointer is over, hovered (NSNotFound: none); set it as the pointer would.
@property (nonatomic) NSUInteger hoveredIndex;
/// While set nothing new is hovered (a menu opened from the row is open); when cleared the entry
/// under the pointer is.
@property (nonatomic) BOOL holdsHover;
/// Scrolls the least needed to show the entry.
- (void)revealIndex:(NSUInteger)index;
/// The rows in view, by index.
@property (nonatomic, readonly) NSIndexSet *visibleIndexes;

#pragma mark For subclasses
- (SNHoverView *)makeRow;
- (void)showIndex:(NSUInteger)index inRow:(__kindof SNHoverView *)row;
- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width;
/// After the rows in view were placed: scrolled, resized or new entries.
- (void)didPlaceRows;
/// After the hovered entry changed.
- (void)didHoverIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
