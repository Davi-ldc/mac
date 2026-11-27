// Virtualized C-array backed list view: binary-search layout & hit-testing, single hover tracking area,
// keyed row reuse, keyboard navigation, double-click, right-click menu hook, zero wantsLayer bloat.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight non-layer-backed row base view.
@interface SPListRowView : NSView
@property (nonatomic, getter=isHovered) BOOL hovered;
@property (nonatomic, getter=isSelected) BOOL selected;
@property (nonatomic, getter=isPressed) BOOL pressed;
@property (nonatomic, copy, nullable) NSString *rowKey;
@property (nonatomic) NSUInteger rowIndex;
/// Incremented each time the list rebinds this row via showIndex:inRow: (also aids single-row redraw tests).
@property (nonatomic) NSUInteger bindCount;
/// Called right before recycling into the pool so subclasses can detach transient subviews (e.g. waveform).
- (void)prepareForReuse;
@end

@interface SPListView : NSView
@property (nonatomic, readonly) NSScrollView *scrollView;
@property (nonatomic, readonly) NSView *documentView;
@property (nonatomic) CGFloat topInset;
@property (nonatomic) CGFloat bottomInset;
@property (nonatomic) CGFloat overscan;
@property (nonatomic) BOOL scrollingEnabled;
@property (nonatomic, readonly) NSArray<NSString *> *keys;

/// Replaces the list keys and re-measures heights; visible rows whose keys remain keep their views.
- (void)showKeys:(NSArray<NSString *> *)keys;
/// Rebinds ONLY visible rows whose keys appear in `keys` (heights unchanged).
- (void)refreshKeys:(NSSet<NSString *> *)keys;
/// Re-measures all heights and repositions visible rows.
- (void)remeasure;

- (NSUInteger)indexOfKey:(NSString *)key;
- (nullable __kindof SPListRowView *)rowAtIndex:(NSUInteger)index;
- (NSRect)rectOfIndex:(NSUInteger)index;
- (NSUInteger)indexAtY:(CGFloat)y;

@property (nonatomic) NSUInteger hoveredIndex;
@property (nonatomic) NSUInteger selectedIndex;
@property (nonatomic) BOOL holdsHover;
@property (nonatomic, readonly) NSIndexSet *visibleIndexes;
@property (nonatomic, readonly) NSUInteger visibleRowCount;
@property (nonatomic, readonly) NSUInteger pooledRowCount;

- (void)revealIndex:(NSUInteger)index;
- (void)scrollToY:(CGFloat)y;

#pragma mark - Subclass hooks
- (SPListRowView *)makeRow;
- (void)showIndex:(NSUInteger)index inRow:(__kindof SPListRowView *)row;
- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width;
- (void)didPlaceRows;
- (void)didHoverIndex:(NSUInteger)index;
- (void)didSelectIndex:(NSUInteger)index;
- (void)didActivateIndex:(NSUInteger)index;
- (nullable NSMenu *)contextMenuForIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
