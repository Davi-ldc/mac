// Virtualized C-array list view with binary search, single tracking area, and safe recycled-row redrawing.
#import "ui/kit/list.h"
#import "render/images.h"

#import <stdlib.h>

@implementation SPListRowView

- (BOOL)isFlipped { return YES; }

- (void)setHovered:(BOOL)hovered {
    if (_hovered == hovered) return;
    _hovered = hovered;
    self.needsDisplay = YES;
}

- (void)setSelected:(BOOL)selected {
    if (_selected == selected) return;
    _selected = selected;
    self.needsDisplay = YES;
}

- (void)setPressed:(BOOL)pressed {
    if (_pressed == pressed) return;
    _pressed = pressed;
    self.needsDisplay = YES;
}

- (void)prepareForReuse {
    _hovered = NO;
    _selected = NO;
    _pressed = NO;
    _rowKey = nil;
    _rowIndex = NSNotFound;
}

@end

@interface SPListDocumentView : NSView
@property (nonatomic, weak) SPListView *owner;
@end

@implementation SPListDocumentView

- (BOOL)isFlipped { return YES; }

- (NSMenu *)menuForEvent:(NSEvent *)event {
    SPListView *list = _owner;
    if (!list) return nil;
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger idx = [list indexAtY:pt.y];
    if (idx == NSNotFound) return nil;
    list.selectedIndex = idx;
    return [list contextMenuForIndex:idx];
}

@end

@interface SPListScrollView : NSScrollView
@property (nonatomic, weak) SPListView *listOwner;
@end

@implementation SPListScrollView
- (void)scrollWheel:(NSEvent *)event {
    if (_listOwner && !_listOwner.scrollingEnabled) {
        [self.nextResponder scrollWheel:event];
        return;
    }
    [super scrollWheel:event];
}
@end

@implementation SPListView {
    SPListScrollView *_scroll;
    SPListDocumentView *_document;
    NSArray<NSString *> *_keys;
    NSDictionary<NSString *, NSNumber *> *_indexes;
    CGFloat *_tops;
    CGFloat _measuredWidth;
    NSMutableDictionary<NSString *, SPListRowView *> *_visible;
    NSMutableArray<SPListRowView *> *_pool;
    NSString *_hoveredKey;
    NSString *_selectedKey;
    NSTrackingArea *_tracking;
    BOOL _pointerInside;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _keys = @[];
    _indexes = @{};
    _tops = (CGFloat *)calloc(1, sizeof(CGFloat));
    _visible = [NSMutableDictionary new];
    _pool = [NSMutableArray new];
    _overscan = 160.0;
    _scrollingEnabled = YES;

    _scroll = [[SPListScrollView alloc] initWithFrame:self.bounds];
    _scroll.listOwner = self;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = NO;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _scroll.contentView.postsBoundsChangedNotifications = YES;

    _document = [[SPListDocumentView alloc] initWithFrame:self.bounds];
    _document.owner = self;
    _scroll.documentView = _document;
    [self addSubview:_scroll];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(clipBoundsChanged:)
                                               name:NSViewBoundsDidChangeNotification
                                             object:_scroll.contentView];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    free(_tops);
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSScrollView *)scrollView { return _scroll; }
- (NSView *)documentView { return _document; }
- (NSArray<NSString *> *)keys { return _keys; }
- (NSUInteger)visibleRowCount { return _visible.count; }
- (NSUInteger)pooledRowCount { return _pool.count; }

- (SPListRowView *)makeRow { return [[SPListRowView alloc] initWithFrame:NSZeroRect]; }
- (void)showIndex:(NSUInteger)index inRow:(SPListRowView *)row { (void)index; (void)row; }
- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { (void)index; (void)width; return 44.0; }
- (void)didPlaceRows {}
- (void)didHoverIndex:(NSUInteger)index { (void)index; }
- (void)didSelectIndex:(NSUInteger)index { (void)index; }
- (void)didActivateIndex:(NSUInteger)index { (void)index; }
- (NSMenu *)contextMenuForIndex:(NSUInteger)index { (void)index; return nil; }

- (void)setScrollingEnabled:(BOOL)scrollingEnabled {
    _scrollingEnabled = scrollingEnabled;
    _scroll.hasVerticalScroller = scrollingEnabled;
    _scroll.verticalScrollElasticity = scrollingEnabled ? NSScrollElasticityAutomatic : NSScrollElasticityNone;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        // Hidden screens / closed windows detach and release all visible and pooled row views immediately.
        for (NSString *key in _visible.allKeys) [self recycleKey:key];
        for (SPListRowView *row in _pool) {
            SPReleaseViewImages(row);
            [row removeFromSuperview];
        }
        [_pool removeAllObjects];
    } else if (_measuredWidth > 0) {
        [self placeRowsRefreshingExisting:NO];
    }
}

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    if (fabs(self.bounds.size.width - _measuredWidth) > 0.5) {
        [self remeasure];
    } else {
        [self sizeDocument];
        [self placeRowsRefreshingExisting:NO];
    }
}

- (void)clipBoundsChanged:(NSNotification *)note {
    (void)note;
    [self placeRowsRefreshingExisting:NO];
    if (_pointerInside) [self updateHoverFromPointer];
}

#pragma mark - Entries & Measurement

- (void)showKeys:(NSArray<NSString *> *)keys {
    _keys = [keys copy] ?: @[];
    NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity:_keys.count];
    [_keys enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL *stop) {
        (void)stop;
        map[key] = @(idx);
    }];
    _indexes = map;
    if (_hoveredKey && !map[_hoveredKey]) _hoveredKey = nil;
    if (_selectedKey && !map[_selectedKey]) _selectedKey = nil;

    [self measure];
    for (NSString *key in _visible.allKeys) {
        if (!map[key]) [self recycleKey:key];
    }
    [self placeRowsRefreshingExisting:YES];
    if (_pointerInside) [self updateHoverFromPointer];
}

- (void)refreshKeys:(NSSet<NSString *> *)keys {
    for (NSString *key in keys) {
        SPListRowView *row = _visible[key];
        NSNumber *idx = _indexes[key];
        if (row && idx) {
            [self bindIndex:idx.unsignedIntegerValue toRow:row key:key];
            row.needsDisplay = YES;
        }
    }
}

- (void)remeasure {
    [self measure];
    [self placeRowsRefreshingExisting:YES];
}

- (void)measure {
    CGFloat width = self.bounds.size.width;
    _measuredWidth = width;
    free(_tops);
    _tops = (CGFloat *)malloc(sizeof(CGFloat) * (_keys.count + 1));
    CGFloat y = self.topInset;
    for (NSUInteger i = 0; i < _keys.count; i++) {
        _tops[i] = y;
        if (width > 0) {
            y += [self heightOfIndex:i width:width];
        }
    }
    _tops[_keys.count] = y;
    [self sizeDocument];
}

- (void)sizeDocument {
    CGFloat totalH = MAX(_tops[_keys.count] + self.bottomInset, self.bounds.size.height);
    NSSize size = NSMakeSize(MAX(0, self.bounds.size.width), MAX(0, totalH));
    if (!NSEqualSizes(_document.frame.size, size)) {
        [_document setFrameSize:size];
    }
}

#pragma mark - Binary Search Geometry

- (NSUInteger)indexOfKey:(NSString *)key {
    if (!key) return NSNotFound;
    NSNumber *n = _indexes[key];
    return n ? n.unsignedIntegerValue : NSNotFound;
}

- (SPListRowView *)rowAtIndex:(NSUInteger)index {
    if (index >= _keys.count) return nil;
    return _visible[_keys[index]];
}

- (NSRect)rectOfIndex:(NSUInteger)index {
    if (index >= _keys.count) return NSZeroRect;
    return NSMakeRect(0, _tops[index], _measuredWidth, _tops[index + 1] - _tops[index]);
}

/// Binary search: first index i such that _tops[i + 1] > y.
- (NSUInteger)firstIndexEndingBelow:(CGFloat)y {
    NSUInteger lo = 0, hi = _keys.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (_tops[mid + 1] <= y) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

- (NSUInteger)indexAtY:(CGFloat)y {
    if (_keys.count == 0 || y < _tops[0] || y >= _tops[_keys.count]) return NSNotFound;
    NSUInteger idx = [self firstIndexEndingBelow:y];
    return idx < _keys.count ? idx : NSNotFound;
}

- (NSIndexSet *)visibleIndexes {
    NSMutableIndexSet *set = [NSMutableIndexSet new];
    for (NSString *key in _visible) {
        NSNumber *n = _indexes[key];
        if (n) [set addIndex:n.unsignedIntegerValue];
    }
    return set;
}

#pragma mark - Placement & Safe Recycling

static void MarkTreeNeedsDisplay(NSView *view) {
    view.needsDisplay = YES;
    for (NSView *sub in view.subviews) MarkTreeNeedsDisplay(sub);
}

static void ClearLayerContentsRecursively(NSView *view) {
    if (view.wantsLayer && view.layer.contents) {
        view.layer.contents = nil;
        view.needsDisplay = YES;
    }
    for (NSView *sub in view.subviews) ClearLayerContentsRecursively(sub);
}

- (void)bindIndex:(NSUInteger)index toRow:(SPListRowView *)row key:(NSString *)key {
    row.rowKey = key;
    row.rowIndex = index;
    row.bindCount++;
    [self showIndex:index inRow:row];
    row.hovered = (_hoveredKey && [key isEqualToString:_hoveredKey]);
    row.selected = (_selectedKey && [key isEqualToString:_selectedKey]);
}

- (void)placeRowsRefreshingExisting:(BOOL)refresh {
    CGFloat width = self.bounds.size.width;
    if (!self.window || width <= 0 || _keys.count == 0) {
        for (NSString *key in _visible.allKeys) [self recycleKey:key];
        [self didPlaceRows];
        return;
    }

    NSRect vis = _scroll.contentView.documentVisibleRect;
    CGFloat top = MAX(0.0, NSMinY(vis) - _overscan);
    CGFloat bottom = NSMaxY(vis) + _overscan;

    NSUInteger first = [self firstIndexEndingBelow:top];
    NSUInteger end = first;
    NSMutableSet<NSString *> *keep = [NSMutableSet new];
    while (end < _keys.count && _tops[end] < bottom) {
        [keep addObject:_keys[end++]];
    }

    // Recycle exiting rows BEFORE dequeuing new ones so pool reuse stays tight.
    for (NSString *key in _visible.allKeys) {
        if (![keep containsObject:key]) [self recycleKey:key];
    }

    for (NSUInteger i = first; i < end; i++) {
        NSString *key = _keys[i];
        SPListRowView *row = _visible[key];
        NSRect frame = NSMakeRect(0, _tops[i], width, _tops[i + 1] - _tops[i]);
        if (!row) {
            row = [self dequeueRow];
            _visible[key] = row;
            if (!NSEqualRects(row.frame, frame)) row.frame = frame;
            [self bindIndex:i toRow:row key:key];
        } else {
            if (!NSEqualRects(row.frame, frame)) row.frame = frame;
            if (refresh) {
                [self bindIndex:i toRow:row key:key];
            }
        }
    }
    [self didPlaceRows];
}

- (SPListRowView *)dequeueRow {
    SPListRowView *row = _pool.lastObject;
    if (row) {
        [_pool removeLastObject];
        if (row.superview != _document) {
            [_document addSubview:row positioned:NSWindowBelow relativeTo:nil];
        }
        row.hidden = NO;
        // Always mark subviews needsDisplay = YES so any layer-backed subview cleared on recycle cannot go blank.
        MarkTreeNeedsDisplay(row);
        return row;
    }
    row = [self makeRow];
    [_document addSubview:row positioned:NSWindowBelow relativeTo:nil];
    return row;
}

- (void)recycleKey:(NSString *)key {
    SPListRowView *row = _visible[key];
    if (!row) return;
    [_visible removeObjectForKey:key];
    [row prepareForReuse];
    row.hidden = YES;
    ClearLayerContentsRecursively(row);
    SPReleaseViewImages(row);
    [row removeFromSuperview];
    [_pool addObject:row];
}

#pragma mark - Scrolling

- (void)scrollToY:(CGFloat)y {
    CGFloat maxY = MAX(0.0, _document.frame.size.height - _scroll.contentView.bounds.size.height);
    CGFloat clamped = MIN(MAX(0.0, y), maxY);
    [_scroll.contentView scrollToPoint:NSMakePoint(0, clamped)];
    [_scroll reflectScrolledClipView:_scroll.contentView];
    [self placeRowsRefreshingExisting:NO];
}

- (void)revealIndex:(NSUInteger)index {
    if (index >= _keys.count) return;
    NSRect rect = [self rectOfIndex:index];
    NSRect vis = _scroll.contentView.documentVisibleRect;
    if (NSMinY(rect) < NSMinY(vis)) {
        [self scrollToY:NSMinY(rect)];
    } else if (NSMaxY(rect) > NSMaxY(vis)) {
        [self scrollToY:NSMaxY(rect) - NSHeight(vis)];
    }
}

#pragma mark - Hover, Selection & Input

- (NSUInteger)hoveredIndex { return [self indexOfKey:_hoveredKey]; }

- (void)setHoveredIndex:(NSUInteger)index {
    if (_holdsHover) return;
    NSString *key = index < _keys.count ? _keys[index] : nil;
    if (key == _hoveredKey || [key isEqualToString:_hoveredKey]) return;
    if (_hoveredKey) _visible[_hoveredKey].hovered = NO;
    _hoveredKey = key;
    if (key) _visible[key].hovered = YES;
    [self didHoverIndex:index < _keys.count ? index : NSNotFound];
}

- (void)setHoldsHover:(BOOL)holdsHover {
    _holdsHover = holdsHover;
    if (!holdsHover && _pointerInside) [self updateHoverFromPointer];
}

- (NSUInteger)selectedIndex { return [self indexOfKey:_selectedKey]; }

- (void)setSelectedIndex:(NSUInteger)index {
    NSString *key = index < _keys.count ? _keys[index] : nil;
    if (key == _selectedKey || [key isEqualToString:_selectedKey]) return;
    if (_selectedKey) _visible[_selectedKey].selected = NO;
    _selectedKey = key;
    if (key) _visible[key].selected = YES;
    [self didSelectIndex:index < _keys.count ? index : NSNotFound];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event {
    _pointerInside = YES;
    [self mouseMoved:event];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint pt = [_document convertPoint:event.locationInWindow fromView:nil];
    self.hoveredIndex = [self indexAtY:pt.y];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _pointerInside = NO;
    self.hoveredIndex = NSNotFound;
}

- (void)updateHoverFromPointer {
    if (!self.window.isVisible) return;
    NSPoint pt = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    if (!NSPointInRect(pt, self.bounds)) {
        self.hoveredIndex = NSNotFound;
        return;
    }
    NSPoint docPt = [_document convertPoint:pt fromView:self];
    self.hoveredIndex = [self indexAtY:docPt.y];
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint docPt = [_document convertPoint:event.locationInWindow fromView:nil];
    NSUInteger idx = [self indexAtY:docPt.y];
    if (idx == NSNotFound) return;
    self.selectedIndex = idx;
    if (event.clickCount >= 2) {
        [self didActivateIndex:idx];
    }
}

- (void)keyDown:(NSEvent *)event {
    if (_keys.count == 0) {
        [super keyDown:event];
        return;
    }
    NSString *chars = event.charactersIgnoringModifiers;
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    NSUInteger sel = self.selectedIndex;

    if (c == NSUpArrowFunctionKey) {
        NSUInteger next = (sel == NSNotFound || sel == 0) ? 0 : sel - 1;
        self.selectedIndex = next;
        [self revealIndex:next];
        return;
    }
    if (c == NSDownArrowFunctionKey) {
        NSUInteger next = (sel == NSNotFound) ? 0 : MIN(_keys.count - 1, sel + 1);
        self.selectedIndex = next;
        [self revealIndex:next];
        return;
    }
    if (c == '\r' || c == '\n' || c == NSEnterCharacter) {
        if (sel != NSNotFound) {
            [self didActivateIndex:sel];
        }
        return;
    }
    if (c == NSHomeFunctionKey) {
        self.selectedIndex = 0;
        [self revealIndex:0];
        return;
    }
    if (c == NSEndFunctionKey) {
        self.selectedIndex = _keys.count - 1;
        [self revealIndex:_keys.count - 1];
        return;
    }
    [super keyDown:event];
}

@end
