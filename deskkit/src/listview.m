// Owns the list: table, row highlight, row and header cells, and the fade under the
// bottom bar.
#import <QuartzCore/QuartzCore.h>

#import "calculatorcard.h"
#import "listview.h"
#import "theme.h"

/// The row a cell sits in fills the table's width; content is inset from the highlight.
static const CGFloat kContentX = 2 * DKInset;
/// A label draws its text this far inside its frame, so frames start that much earlier.
static const CGFloat kLabelInset = 2;
/// The running dot, measured from Raycast: its size and its centre's distance below the icon.
static const CGFloat kDotSize = 3, kDotBelowIcon = 3.25;

@interface DKRowView : NSTableRowView
/// White behind the row while it is neither selected nor under the mouse: Raycast's
/// calculator card has a faint one.
@property(nonatomic) CGFloat restingFill;
@property(nonatomic) BOOL hovered;
@property(nonatomic) BOOL pressed;
@end
@implementation DKRowView
static void FillHighlight(NSRect bounds, CGFloat white) {
    [DKWhite(white) setFill];
    NSRect highlight = NSInsetRect(bounds, DKInset, 0);
    [[NSBezierPath bezierPathWithRoundedRect:highlight xRadius:DKRowRadius yRadius:DKRowRadius] fill];
}
- (void)drawSelectionInRect:(NSRect)rect { FillHighlight(self.bounds, _pressed ? 0.15 : 0.1); }
- (void)drawBackgroundInRect:(NSRect)rect {
    // The selection's fill takes the place of these, not over them.
    CGFloat white = self.selected ? 0 : _hovered ? 0.05 : _restingFill;
    if (white) FillHighlight(self.bounds, white);
}
- (void)setHovered:(BOOL)hovered {
    if (_hovered == hovered) return;
    _hovered = hovered;
    self.needsDisplay = YES;
}
- (void)setPressed:(BOOL)pressed {
    if (_pressed == pressed) return;
    _pressed = pressed;
    self.needsDisplay = YES;
}
- (void)setRestingFill:(CGFloat)fill {
    if (_restingFill == fill) return;
    _restingFill = fill;
    self.needsDisplay = YES;
}
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self showSelectionInCard];
}
/// A card brightens its arrow and divider when selected; a row view lends the state to the
/// card it holds.
- (void)showSelectionInCard {
    NSView *cell = self.numberOfColumns ? [self viewAtColumn:0] : nil;
    if ([cell isKindOfClass:DKCalculatorCard.class]) ((DKCalculatorCard *)cell).selected = self.selected;
}
// The highlight looks the same whether or not the panel is key.
- (BOOL)isEmphasized { return NO; }
@end

/// Reports a mouse press on a row for as long as it lasts.
@interface DKTableView : NSTableView
@property(copy, nullable) void (^onPress)(NSInteger row);
@property(copy, nullable) void (^onRelease)(void);
@end
@implementation DKTableView
- (void)mouseDown:(NSEvent *)event {
    NSInteger row = event.clickCount == 1 ? [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]] : -1;
    if (row >= 0 && self.onPress) self.onPress(row);
    // Returns once the button is up: the table follows the mouse in a loop of its own.
    [super mouseDown:event];
    if (row >= 0 && self.onRelease) self.onRelease();
}
@end

/// What a row of the list is drawn as.
typedef NS_ENUM(NSInteger, DKRowKind) { DKRowHeader, DKRowItem, DKRowCard };

static DKRowKind KindOf(id entry) {
    if (![entry isKindOfClass:DKItem.class]) return DKRowHeader;
    return ((DKItem *)entry).calculation ? DKRowCard : DKRowItem;
}

/// Sets a label's text unless it shows it already: a row that takes another item often
/// keeps its subtitle and its right-hand label, and a label redraws whenever it is set.
static void SetText(NSTextField *label, NSString *text) {
    if (![label.stringValue isEqualToString:text]) label.stringValue = text;
}

@interface DKItemCell : NSTableCellView
- (void)showItem:(DKItem *)item;
@end
@implementation DKItemCell {
    NSImageView *_icon;
    NSView *_dot;
    NSTextField *_title, *_subtitle, *_accessory;
}

- (instancetype)init {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _icon = [NSImageView new];
    _icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    _title = DKLabel(@"", DKFont(13, 400), DKTextPrimary());
    _subtitle = DKLabel(@"", DKFont(13, 400), DKTextSecondary());
    _accessory = DKLabel(@"", DKFont(13, 400), DKTextSecondary());
    _accessory.alignment = NSTextAlignmentRight;
    _dot = [NSView new];
    _dot.wantsLayer = YES;
    _dot.layer.backgroundColor = DKWhite(0.45).CGColor;
    _dot.layer.cornerRadius = kDotSize / 2;
    for (NSView *view in @[ _icon, _dot, _title, _subtitle, _accessory ]) [self addSubview:view];
    return self;
}

- (void)showItem:(DKItem *)item {
    if (!item.icon && item.iconLoader) item.icon = item.iconLoader();
    _icon.image = item.icon;
    _dot.hidden = !item.running;
    SetText(_title, item.title);
    SetText(_subtitle, item.subtitle ?: @"");
    SetText(_accessory, item.accessory ?: @"");
    self.needsLayout = YES;
}

// Rows get their final width only after the cell is made; frames follow every resize.
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    CGFloat height = self.bounds.size.height, width = self.bounds.size.width;
    _icon.frame = NSMakeRect(kContentX, (height - DKIconSize) / 2, DKIconSize, DKIconSize);
    _dot.frame = NSMakeRect(NSMidX(_icon.frame) - kDotSize / 2, NSMaxY(_icon.frame) + kDotBelowIcon - kDotSize / 2, kDotSize, kDotSize);
    CGFloat right = width - kContentX;
    [_accessory sizeToFit];
    CGFloat accessoryWidth = _accessory.stringValue.length ? _accessory.frame.size.width : 0;
    _accessory.frame = NSMakeRect(right - accessoryWidth + kLabelInset, (height - _accessory.frame.size.height) / 2 - 1,
                                  accessoryWidth, _accessory.frame.size.height);
    // Raycast keeps 16 points between the text and the label on the right.
    CGFloat limit = right - (accessoryWidth ? accessoryWidth + 16 : 0);
    CGFloat x = kContentX + DKIconSize + DKIconGap - kLabelInset;
    [_title sizeToFit];
    CGFloat titleWidth = MIN(_title.frame.size.width, limit - x);
    // Inter sits a point low in its line box compared with how Raycast places it.
    CGFloat textY = (height - _title.frame.size.height) / 2 - 0.5;
    _title.frame = NSMakeRect(x, textY, titleWidth, _title.frame.size.height);
    CGFloat subtitleX = x + titleWidth + DKIconGap - 2 * kLabelInset;
    [_subtitle sizeToFit];
    _subtitle.frame = NSMakeRect(subtitleX, textY, MAX(0, MIN(_subtitle.frame.size.width, limit - subtitleX)),
                                 _subtitle.frame.size.height);
}

- (BOOL)isFlipped { return YES; }
@end

@interface DKHeaderCell : NSTableCellView
@property(strong) NSTextField *label;
@end
@implementation DKHeaderCell
- (instancetype)init {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _label = DKLabel(@"", DKFont(11, 400), DKTextSecondary());
    [self addSubview:_label];
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    [_label sizeToFit];
    // The title sits in the header's last DKSectionHeight points, raised as Raycast raises it.
    CGFloat top = self.bounds.size.height - DKSectionHeight;
    CGFloat height = _label.frame.size.height;
    _label.frame = NSMakeRect(kContentX - kLabelInset, top + (DKSectionHeight - height) / 2 - 1, self.bounds.size.width, height);
}
@end

@interface DKListView () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation DKListView {
    NSScrollView *_scroll;
    DKTableView *_table;
    __weak DKRowView *_pressedRow;
    NSTextField *_empty;
    CAGradientLayer *_fade;
    /// Section titles (NSString) and items (DKItem), in display order.
    NSArray *_rows;
    /// The row under the mouse, -1 for none.
    NSInteger _hoveredRow;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _table = [[DKTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    [_table addTableColumn:column];
    _table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    _table.headerView = nil;
    _table.backgroundColor = NSColor.clearColor;
    _table.intercellSpacing = NSZeroSize;
    _table.style = NSTableViewStylePlain;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(activate);
    __weak DKListView *weakSelf = self;
    _table.onPress = ^(NSInteger row) { [weakSelf pressRow:row]; };
    _table.onRelease = ^{
        DKListView *list = weakSelf;
        if (list.onRelease) list.onRelease();
    };

    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scroll.drawsBackground = NO;
    _scroll.documentView = _table;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.automaticallyAdjustsContentInsets = NO;
    // The last rows can scroll up out from under the bottom bar.
    _scroll.contentInsets = NSEdgeInsetsMake(0, 0, DKFooterHeight, 0);
    _scroll.wantsLayer = YES;
    // Rows fade out as they pass under the bottom bar.
    _fade = [CAGradientLayer layer];
    _fade.colors = @[ (id)NSColor.blackColor.CGColor, (id)NSColor.blackColor.CGColor, (id)[NSColor colorWithWhite:0 alpha:0.25].CGColor ];
    _scroll.layer.mask = _fade;
    [self addSubview:_scroll];

    _empty = DKLabel(@"No Results", DKFont(13, 500), DKTextSecondary());
    _empty.alignment = NSTextAlignmentCenter;
    _empty.hidden = YES;
    [self addSubview:_empty];

    _hoveredRow = -1;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                               NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
    // As in Raycast, scrolling clears the hover until the mouse moves again.
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clearHover) name:NSViewBoundsDidChangeNotification
                                               object:_scroll.contentView];
    return self;
}

#pragma mark Hover

- (void)hoverRow:(NSInteger)row {
    if (row == _hoveredRow) return;
    if (_hoveredRow >= 0 && _hoveredRow < _table.numberOfRows)
        ((DKRowView *)[_table rowViewAtRow:_hoveredRow makeIfNecessary:NO]).hovered = NO;
    _hoveredRow = row >= 0 && row < (NSInteger)_rows.count && KindOf(_rows[row]) != DKRowHeader ? row : -1;
    if (_hoveredRow >= 0) ((DKRowView *)[_table rowViewAtRow:_hoveredRow makeIfNecessary:NO]).hovered = YES;
}

- (void)clearHover { [self hoverRow:-1]; }

- (void)mouseMoved:(NSEvent *)event {
    [self hoverRow:[_table rowAtPoint:[_table convertPoint:event.locationInWindow fromView:nil]]];
}

- (void)mouseExited:(NSEvent *)event { [self clearHover]; }

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    _table.tableColumns.firstObject.width = size.width;
    // A layer of its own animates every change: when the list gets its full width back
    // from the detail pane, the fade would take a quarter of a second to follow, and the
    // rows would show through it from the left.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.frame = _scroll.bounds;
    CGFloat fadeStart = 1 - DKFooterHeight / MAX(size.height, 1);
    // The scroll view's layer is flipped like the list: 0 is the top.
    _fade.startPoint = CGPointMake(0.5, 0);
    _fade.endPoint = CGPointMake(0.5, 1);
    _fade.locations = @[ @0, @(fadeStart), @1 ];
    [CATransaction commit];
    [_empty sizeToFit];
    _empty.frame = NSMakeRect(0, (size.height - _empty.frame.size.height) / 2 - DKFooterHeight / 2, size.width,
                              _empty.frame.size.height);
}

#pragma mark Content

- (void)setItems:(NSArray<DKItem *> *)items keepSelection:(BOOL)keepSelection {
    NSString *keptKey = keepSelection ? self.selectedItem.key : nil;
    NSInteger keptRow = keepSelection ? _table.selectedRow : -1;
    NSMutableArray *rows = [NSMutableArray new];
    NSString *section = nil;
    for (DKItem *item in items) {
        if (item.section.length && ![item.section isEqualToString:section]) [rows addObject:item.section];
        section = item.section;
        [rows addObject:item];
    }
    // The same rows again, as when a closed panel opens on the root it already holds, need
    // nothing.
    if (![rows isEqualToArray:_rows]) {
        _empty.hidden = items.count > 0;
        [self clearHover];
        [self showRows:rows];
    }

    NSInteger row = -1;
    if (keptKey)
        for (NSInteger i = 0; i < (NSInteger)_rows.count; i++)
            if ([_rows[i] isKindOfClass:DKItem.class] && [((DKItem *)_rows[i]).key isEqualToString:keptKey]) row = i;
    if (row < 0 && keptRow >= 0) row = [self itemRowFrom:MIN(keptRow, (NSInteger)_rows.count) - 1 step:1];
    if (row < 0) row = [self itemRowFrom:-1 step:1];
    [self selectRow:row];
    if (row <= 1) [_table scrollRowToVisible:0];
    // The selected index can stay the same while the item under it changed.
    if (self.onSelectionChange) self.onSelectionChange(self.selectedItem);
}

/// Puts `rows` in the table's existing views. A row that stays an item, or stays a header,
/// only takes its new content; -reloadData would pull every row's views out of the table
/// and put them back, which costs several times more than everything else a key press does.
- (void)showRows:(NSArray *)rows {
    NSArray *old = _rows;
    _rows = rows;
    // Rows that turned into another kind (item, header, card) need the other view and height.
    NSMutableIndexSet *turned = [NSMutableIndexSet new];
    for (NSUInteger i = 0; i < MIN(old.count, rows.count); i++)
        if (KindOf(old[i]) != KindOf(rows[i])) [turned addIndex:i];
    // Left to itself the table takes several frames to grow or shrink and to slide rows
    // to their new places.
    [NSAnimationContext beginGrouping];
    NSAnimationContext.currentContext.duration = 0;
    [_table noteNumberOfRowsChanged];
    [_table noteHeightOfRowsWithIndexesChanged:turned];
    [NSAnimationContext endGrouping];
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        if (row < (NSInteger)rows.count && ![turned containsIndex:row]) [self show:rows[row] in:[rowView viewAtColumn:0]];
    }];
    [_table reloadDataForRowIndexes:turned columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    [_table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        if (row >= (NSInteger)rows.count) return;
        ((DKRowView *)rowView).restingFill = KindOf(rows[row]) == DKRowCard ? 0.03 : 0;
        [(DKRowView *)rowView showSelectionInCard];
    }];
}

- (void)show:(id)entry in:(NSView *)cell {
    if (KindOf(entry) == DKRowCard) return [(DKCalculatorCard *)cell showCalculation:[entry calculation] note:[entry subtitle]];
    if ([entry isKindOfClass:DKItem.class]) return [(DKItemCell *)cell showItem:entry];
    DKHeaderCell *header = (DKHeaderCell *)cell;
    SetText(header.label, entry);
    header.needsLayout = YES;
}

- (DKItem *)selectedItem {
    NSInteger row = _table.selectedRow;
    return row >= 0 && row < (NSInteger)_rows.count && [_rows[row] isKindOfClass:DKItem.class] ? _rows[row] : nil;
}

- (NSInteger)itemRowFrom:(NSInteger)row step:(NSInteger)step {
    for (NSInteger i = row + step; i >= 0 && i < (NSInteger)_rows.count; i += step)
        if ([_rows[i] isKindOfClass:DKItem.class]) return i;
    return -1;
}

- (void)moveSelection:(NSInteger)step {
    NSInteger row = [self itemRowFrom:_table.selectedRow step:step];
    if (row >= 0) [self selectRow:row];
}

- (void)selectRow:(NSInteger)row {
    if (row < 0) {
        [_table deselectAll:nil];
        if (self.onSelectionChange) self.onSelectionChange(nil);
        return;
    }
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    // Keeps the section header in view when moving onto its first row.
    NSInteger visible = row > 0 && [_rows[row - 1] isKindOfClass:NSString.class] ? row - 1 : row;
    [_table scrollRowToVisible:visible];
    [_table scrollRowToVisible:row];
}

- (void)reloadIcons {
    for (id row in _rows)
        if ([row isKindOfClass:DKItem.class] && ((DKItem *)row).iconLoader) ((DKItem *)row).icon = nil;
    NSRange visible = [_table rowsInRect:_table.visibleRect];
    [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:visible] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

- (void)pressRow:(NSInteger)row {
    if (row >= (NSInteger)_rows.count || ![_rows[row] isKindOfClass:DKItem.class]) return;
    // Selected now rather than whenever the table's own handling gets to it, so that the
    // press is drawn on this row.
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    if (self.onPress) self.onPress(_rows[row]);
}

- (void)showPressed:(BOOL)pressed {
    _pressedRow.pressed = NO;
    _pressedRow = pressed && _table.selectedRow >= 0 ? (DKRowView *)[_table rowViewAtRow:_table.selectedRow makeIfNecessary:NO] : nil;
    _pressedRow.pressed = YES;
}

// The row under the double click, which is the selected one unless the first click only
// brought the panel forward.
- (void)activate {
    NSInteger row = _table.clickedRow;
    DKItem *item = row >= 0 && row < (NSInteger)_rows.count && [_rows[row] isKindOfClass:DKItem.class] ? _rows[row] : nil;
    if (!item || !self.onActivate) return;
    [self selectRow:row];
    self.onActivate(item);
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return _rows.count; }

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (KindOf(_rows[row]) == DKRowCard) return DKCalculatorCardHeight;
    if ([_rows[row] isKindOfClass:DKItem.class]) return DKRowHeight;
    return row == 0 ? DKSectionHeight : DKSectionHeight + DKSectionGap;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return [_rows[row] isKindOfClass:DKItem.class];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.onSelectionChange) self.onSelectionChange(self.selectedItem);
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [DKRowView new];
}

- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    // Raycast's card rests on 3% white; it takes the hover's 5% and the selection's 10% like a row.
    ((DKRowView *)rowView).restingFill = row < (NSInteger)_rows.count && KindOf(_rows[row]) == DKRowCard ? 0.03 : 0;
    ((DKRowView *)rowView).hovered = row == _hoveredRow;
    [(DKRowView *)rowView showSelectionInCard];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    id entry = _rows[row];
    DKRowKind kind = KindOf(entry);
    NSUserInterfaceItemIdentifier identifier = kind == DKRowCard ? @"card" : kind == DKRowItem ? @"item" : @"header";
    NSView *cell = [tableView makeViewWithIdentifier:identifier owner:nil];
    if (!cell) cell = kind == DKRowCard ? [DKCalculatorCard new] : kind == DKRowItem ? [DKItemCell new] : [DKHeaderCell new];
    cell.identifier = identifier;
    [self show:entry in:cell];
    return cell;
}

@end
