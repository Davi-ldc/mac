// Owns the list's entry geometry, virtualization and hover.
#import "render/images.h"
#import "ui/kit/list.h"

@interface SNListDocumentView : NSView
@end

@implementation SNListDocumentView
- (BOOL)isFlipped { return YES; }
@end

@implementation SNListView {
    NSScrollView *_scroll;
    SNListDocumentView *_document;
    NSArray<NSString *> *_keys;
    NSDictionary<NSString *, NSNumber *> *_indexes;
    /// Each entry's top, and the end of the last, at `_measuredWidth`.
    CGFloat *_tops;
    CGFloat _measuredWidth;
    NSMutableDictionary<NSString *, SNHoverView *> *_visible;
    NSMutableArray<SNHoverView *> *_pool;
    NSString *_hoveredKey;
    NSTrackingArea *_tracking;
    BOOL _pointerInside;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _keys = @[];
    _indexes = @{};
    _tops = calloc(1, sizeof(CGFloat));
    _visible = [NSMutableDictionary new];
    _pool = [NSMutableArray new];
    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    _document = [[SNListDocumentView alloc] initWithFrame:self.bounds];
    _scroll.documentView = _document;
    [self addSubview:_scroll];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:) name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    free(_tops);
}

- (BOOL)isFlipped { return YES; }
- (NSScrollView *)scrollView { return _scroll; }
- (NSView *)documentView { return _document; }

- (SNHoverView *)makeRow { return [[SNHoverView alloc] initWithFrame:NSZeroRect]; }
- (void)showIndex:(NSUInteger)index inRow:(SNHoverView *)row {}
- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { return 0; }
- (void)didPlaceRows {}
- (void)didHoverIndex:(NSUInteger)index {}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        _hoveredKey = nil;
        _pointerInside = NO;
        // Hidden tabs drop visible row backing stores and decoded images until shown again.
        for (NSString *key in _visible.allKeys) [self recycle:key];
    } else if (_measuredWidth > 0) {
        [self placeRows];
    }
}

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    if (self.bounds.size.width != _measuredWidth) [self remeasure];
    else {
        [self sizeDocument];
        [self placeRows];
    }
}

#pragma mark Entries

- (void)showKeys:(NSArray<NSString *> *)keys {
    _keys = [keys copy];
    NSMutableDictionary *indexes = [NSMutableDictionary dictionaryWithCapacity:keys.count];
    [keys enumerateObjectsUsingBlock:^(NSString *key, NSUInteger index, BOOL *stop) { indexes[key] = @(index); }];
    _indexes = indexes;
    if (_hoveredKey && !indexes[_hoveredKey]) _hoveredKey = nil;
    [self measure];
    for (NSString *key in _visible.allKeys)
        if (!indexes[key]) [self recycle:key];
    [self placeRowsRefreshingExisting:YES];
    // What now lies under a pointer that did not move.
    if (_pointerInside) [self hoverFromPointer];
}

- (void)refreshKeys:(NSSet<NSString *> *)keys {
    for (NSString *key in keys) {
        SNHoverView *row = _visible[key];
        if (row) [self showIndex:_indexes[key].unsignedIntegerValue inRow:row];
    }
}

- (void)remeasure {
    [self measure];
    [self placeRowsRefreshingExisting:YES];
}

/// Every entry's top at the list's width; nothing is measured before the list has one.
- (void)measure {
    CGFloat width = self.bounds.size.width;
    _measuredWidth = width;
    free(_tops);
    _tops = malloc(sizeof(CGFloat) * (_keys.count + 1));
    CGFloat y = self.topInset;
    for (NSUInteger index = 0; index < _keys.count; index++) {
        _tops[index] = y;
        if (width > 0) y += [self heightOfIndex:index width:width];
    }
    _tops[_keys.count] = y;
    [self sizeDocument];
}

- (void)sizeDocument {
    NSSize size = NSMakeSize(self.bounds.size.width, MAX(_tops[_keys.count] + self.bottomInset, self.bounds.size.height));
    if (!NSEqualSizes(_document.frame.size, size)) [_document setFrameSize:size];
}

- (NSUInteger)indexOfKey:(NSString *)key {
    NSNumber *index = key ? _indexes[key] : nil;
    return index ? index.unsignedIntegerValue : NSNotFound;
}

- (SNHoverView *)rowAtIndex:(NSUInteger)index { return index < _keys.count ? _visible[_keys[index]] : nil; }

- (NSRect)rectOfIndex:(NSUInteger)index {
    if (index >= _keys.count) return NSZeroRect;
    return NSMakeRect(0, _tops[index], _measuredWidth, _tops[index + 1] - _tops[index]);
}

/// The first entry whose bottom is below `y`.
- (NSUInteger)firstIndexEndingBelow:(CGFloat)y {
    NSUInteger low = 0, high = _keys.count;
    while (low < high) {
        NSUInteger middle = (low + high) / 2;
        if (_tops[middle + 1] <= y) low = middle + 1;
        else high = middle;
    }
    return low;
}

- (NSUInteger)indexAtY:(CGFloat)y {
    NSUInteger index = [self firstIndexEndingBelow:y];
    return index < _keys.count && y >= _tops[index] ? index : NSNotFound;
}

- (void)revealIndex:(NSUInteger)index {
    NSRect rect = [self rectOfIndex:index], visible = _scroll.contentView.bounds;
    if (NSIsEmptyRect(rect) || NSIsEmptyRect(visible)) return;
    CGFloat y = visible.origin.y;
    if (NSMinY(rect) < y) y = NSMinY(rect) - self.topInset;
    else if (NSMaxY(rect) > NSMaxY(visible)) y = NSMaxY(rect) - visible.size.height + self.bottomInset;
    if (y == visible.origin.y) return;
    [_scroll.contentView scrollToPoint:NSMakePoint(0, MAX(0, y))];
    [_scroll reflectScrolledClipView:_scroll.contentView];
}

#pragma mark Rows

- (void)scrolled:(NSNotification *)notification {
    [self placeRows];
    if (_pointerInside) [self hoverFromPointer];
}

- (NSIndexSet *)visibleIndexes {
    NSMutableIndexSet *indexes = [NSMutableIndexSet new];
    for (NSString *key in _visible) [indexes addIndex:_indexes[key].unsignedIntegerValue];
    return indexes;
}

- (void)placeRows { [self placeRowsRefreshingExisting:NO]; }

- (void)placeRowsRefreshingExisting:(BOOL)refresh {
    if (_measuredWidth <= 0) return;
    NSRect visible = _scroll.contentView.bounds;
    CGFloat top = NSMinY(visible) - self.overscan, bottom = NSMaxY(visible) + self.overscan, width = _measuredWidth;
    NSString *hovered = _hoveredKey;
    NSUInteger first = [self firstIndexEndingBelow:MAX(0, top)], end = first;
    NSMutableSet<NSString *> *keep = [NSMutableSet new];
    while (end < _keys.count && _tops[end] < bottom) [keep addObject:_keys[end++]];
    // Recycle rows leaving view before dequeuing or refilling so pool reuse avoids extra allocations
    // and rows about to be recycled are never refilled.
    for (NSString *key in _visible.allKeys)
        if (![keep containsObject:key]) [self recycle:key];
    for (NSUInteger index = first; index < end; index++) {
        NSString *key = _keys[index];
        SNHoverView *row = _visible[key];
        if (!row) {
            row = [self dequeue];
            _visible[key] = row;
            [self showIndex:index inRow:row];
            row.hovered = [key isEqualToString:hovered];
        } else if (refresh) {
            [self showIndex:index inRow:row];
        }
        NSRect frame = NSMakeRect(0, _tops[index], width, _tops[index + 1] - _tops[index]);
        if (!NSEqualRects(row.frame, frame)) row.frame = frame;
    }
    [self didPlaceRows];
}

static void MarkNeedsDisplay(NSView *view) {
    view.needsDisplay = YES;
    for (NSView *subview in view.subviews) MarkNeedsDisplay(subview);
}

- (SNHoverView *)dequeue {
    SNHoverView *row = _pool.lastObject;
    if (row) {
        [_pool removeLastObject];
        row.hidden = NO;
        // ClearLayerContents wiped subviews' backing layers on recycle, so every subview must redraw
        // even if showIndex:inRow: or SNLabel setText: early-returns for the same content.
        MarkNeedsDisplay(row);
        return row;
    }
    row = [self makeRow];
    row.tracksMouse = NO;
    // Under whatever the subclass shows over the rows.
    [_document addSubview:row positioned:NSWindowBelow relativeTo:nil];
    return row;
}

static void ClearLayerContents(NSView *view) {
    if (view.layer.contents) {
        view.layer.contents = nil;
        view.needsDisplay = YES;
    }
    for (NSView *subview in view.subviews) ClearLayerContents(subview);
}

- (void)recycle:(NSString *)key {
    SNHoverView *row = _visible[key];
    [_visible removeObjectForKey:key];
    row.hovered = row.pressed = NO;
    row.hidden = YES;
    // Out of view a row keeps neither its drawing nor its pictures; it draws again when shown.
    ClearLayerContents(row);
    SNReleaseViewImages(row);
    [_pool addObject:row];
}

#pragma mark Hover

- (NSUInteger)hoveredIndex { return [self indexOfKey:_hoveredKey]; }

- (void)setHoveredIndex:(NSUInteger)index {
    if (!_holdsHover) [self hover:index];
}

- (void)hover:(NSUInteger)index {
    NSString *key = index < _keys.count ? _keys[index] : nil;
    if (key == _hoveredKey || [key isEqualToString:_hoveredKey]) return;
    _visible[_hoveredKey ?: @""].hovered = NO;
    _hoveredKey = key;
    _visible[key ?: @""].hovered = YES;
    [self didHoverIndex:index < _keys.count ? index : NSNotFound];
}

- (void)setHoldsHover:(BOOL)holdsHover {
    _holdsHover = holdsHover;
    if (holdsHover) return;
    // The pointer may have moved on while the menu was open.
    NSPoint point = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    [self hover:self.window && NSPointInRect(point, self.bounds) ? [self indexAtY:[_document convertPoint:point fromView:self].y] : NSNotFound];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    // Like the web client, hover works while the window is in the background.
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event {
    _pointerInside = YES;
    [self mouseMoved:event];
}

- (void)mouseMoved:(NSEvent *)event { self.hoveredIndex = [self indexAtY:[_document convertPoint:event.locationInWindow fromView:nil].y]; }

- (void)mouseExited:(NSEvent *)event {
    _pointerInside = NO;
    self.hoveredIndex = NSNotFound;
}

- (void)hoverFromPointer {
    if (!self.window.isVisible) return;
    self.hoveredIndex = [self indexAtY:[_document convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil].y];
}

@end
