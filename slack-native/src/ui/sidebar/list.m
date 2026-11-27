// Owns the sidebar list's entries, scrollbar and keyboard focus.
#import "ui/kit/filter.h"
#import "ui/sidebar/list.h"

/// Slack's overlay thumb: 8 pt, the legacy primary foreground at 52%, radius 4, 4 pt from the
/// list's top and bottom, flush with the column's right edge (measured live).
static const CGFloat kThumbWidth = 8, kThumbInset = 4;
static const SNColorToken kThumbColor = (SNLegacyPrimaryForeground & 0xffffff00) | 0x85;
/// Rows kept beyond the visible part, so a short scroll reuses nothing.
static const CGFloat kOverscan = 56;
/// The focus ring of a sidebar row: its box inset 8 pt from the column's sides, radius 8
/// (.p-ia4_client .p-channel_sidebar__static_list__item:focus:after).
static const CGFloat kRingInset = 8, kRingRadius = 8;
enum { kKeyReturn = 36, kKeyTab = 48, kKeySpace = 49, kKeyEnter = 76, kKeyDown = 125, kKeyUp = 126 };

/// Holds a layer over the rows (the scrollbar, the focus ring); the pointer passes through it.
@interface SNSidebarOverlayView : NSView
@end

@implementation SNSidebarOverlayView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

/// What Slack's tree lets the keyboard land on (role treeitem): not lines, gaps or hints.
static BOOL Focusable(SNSidebarItem *item) {
    return item.kind != SNSidebarItemDivider && item.kind != SNSidebarItemGap && item.kind != SNSidebarItemHint;
}

@implementation SNSidebarListView {
    NSArray<SNSidebarItem *> *_items;
    SNSidebarOverlayView *_thumbView, *_ringView;
    SNLayer *_thumb;
    SNFocusRingLayer *_ring;
    NSUInteger _thumbGeneration;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overscan = kOverscan;
    self.bottomInset = SNSpace2;
    _items = @[];
    self.scrollView.hasVerticalScroller = NO;
    self.scrollView.verticalScrollElasticity = NSScrollElasticityAllowed;
    // The ring sits over the rows (they are added under it) and may reach past its row.
    _ringView = [[SNSidebarOverlayView alloc] initWithFrame:NSZeroRect];
    _ringView.wantsLayer = YES;
    _ringView.hidden = YES;
    _ring = [SNFocusRingLayer layer];
    [_ringView.layer addSublayer:_ring];
    [self.documentView addSubview:_ringView];
    _thumbView = [[SNSidebarOverlayView alloc] initWithFrame:self.bounds];
    _thumbView.wantsLayer = YES;
    [self addSubview:_thumbView];
    _thumb = [SNLayer layer];
    _thumb.backgroundColor = SNCGColor(kThumbColor);
    _thumb.cornerRadius = kThumbWidth / 2;
    _thumb.opacity = 0;
    [_thumbView.layer addSublayer:_thumb];
    return self;
}

- (CALayer *)scrollThumb { return _thumb; }

- (void)layout {
    [super layout];
    _thumbView.frame = self.bounds;
    [self placeThumb];
    [self placeRing];
}

#pragma mark Entries

- (void)showItems:(NSArray<SNSidebarItem *> *)items {
    _items = [items copy];
    if (_focusedKey && ![self itemForKey:_focusedKey]) _focusedKey = nil;
    [self showKeys:[items valueForKey:@"key"]];
    [self placeRing];
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { return _items[index].height; }

- (SNHoverView *)makeRow {
    SNSidebarRowView *row = [[SNSidebarRowView alloc] initWithFrame:NSZeroRect];
    row.delegate = self.delegate;
    return row;
}

- (void)showIndex:(NSUInteger)index inRow:(SNSidebarRowView *)row {
    [row showItem:_items[index] state:[self.delegate sidebarList:self stateForItem:_items[index]]];
}

- (void)didPlaceRows { [self placeThumb]; }

- (SNSidebarItem *)itemForKey:(NSString *)key {
    NSUInteger index = [self indexOfKey:key];
    return index == NSNotFound ? nil : _items[index];
}

- (SNSidebarRowView *)rowForKey:(NSString *)key { return [self rowAtIndex:[self indexOfKey:key]]; }
- (NSRect)rectForKey:(NSString *)key { return [self rectOfIndex:[self indexOfKey:key]]; }
- (void)hoverKey:(NSString *)key { self.hoveredIndex = [self indexOfKey:key]; }
- (void)revealKey:(NSString *)key { [self revealIndex:[self indexOfKey:key]]; }

- (void)setDelegate:(id<SNSidebarListDelegate>)delegate {
    _delegate = delegate;
    for (NSView *row in self.documentView.subviews)
        if ([row isKindOfClass:SNSidebarRowView.class]) ((SNSidebarRowView *)row).delegate = delegate;
}

- (void)mouseEntered:(NSEvent *)event {
    [self showThumb:YES];
    [super mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event {
    [self showThumb:NO];
    [super mouseExited:event];
}

#pragma mark Scrollbar

- (void)placeThumb {
    CGFloat visible = self.bounds.size.height, offset = self.scrollView.contentView.bounds.origin.y;
    CGFloat track = visible - 2 * kThumbInset, content = NSMaxY([self rectOfIndex:_items.count - 1]) + self.bottomInset;
    if (!_items.count || content <= visible || track <= 0) {
        _thumb.hidden = YES;
        return;
    }
    CGFloat height = MAX(SNSpace8, round(track * visible / content));
    CGFloat progress = MIN(1, MAX(0, offset / (content - visible)));
    _thumb.hidden = NO;
    // The host view's layer keeps a bottom-left origin.
    CGFloat top = kThumbInset + (track - height) * progress;
    _thumb.frame = CGRectMake(self.bounds.size.width - kThumbWidth, visible - top - height, kThumbWidth, height);
}

- (void)showThumb:(BOOL)show {
    NSUInteger generation = ++_thumbGeneration;
    [self placeThumb];
    if (show) {
        _thumb.opacity = 1;
        return;
    }
    // Fades out 100 ms after a 160 ms pause (live).
    __weak SNSidebarListView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLiveScrollbarHideDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SNSidebarListView *list = weakSelf;
        if (!list || list->_thumbGeneration != generation) return;
        SNAnimate(SNLiveScrollbarHide, SNEaseDefault(), ^{ list->_thumb.opacity = 0; });
    });
}

#pragma mark Keyboard

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)resignFirstResponder {
    _focusedKey = nil;
    [self placeRing];
    return YES;
}

- (BOOL)focusFirstItem {
    for (SNSidebarItem *item in _items) {
        if (!Focusable(item)) continue;
        [self.window makeFirstResponder:self];
        [self focusKey:item.key];
        return YES;
    }
    return NO;
}

- (void)focusKey:(NSString *)key {
    _focusedKey = [key copy];
    [self revealKey:key];
    [self placeRing];
}

- (void)placeRing {
    NSRect rect = _focusedKey && self.window.firstResponder == self ? [self rectForKey:_focusedKey] : NSZeroRect;
    _ringView.hidden = NSIsEmptyRect(rect);
    if (_ringView.hidden) return;
    NSRect ring = NSInsetRect(rect, kRingInset, 0);
    CGFloat reach = SNFocusRingReach;
    _ringView.frame = NSInsetRect(ring, -reach, -reach);
    [_ring setRingAroundRect:CGRectMake(reach, reach, ring.size.width, ring.size.height) radius:kRingRadius];
}

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand);
    switch (event.keyCode) {
    case kKeyDown:
    case kKeyUp:
        if (modifiers) break;
        [self moveFocus:event.keyCode == kKeyUp ? -1 : 1];
        return;
    case kKeyReturn:
    case kKeyEnter:
    case kKeySpace:
        if (modifiers & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) break;
        [self actOnFocused];
        return;
    case kKeyTab:
        if (modifiers != NSEventModifierFlagShift) break;
        [self.delegate sidebarListShiftTabbed:self];
        return;
    }
    [super keyDown:event];
}

/// The next entry that takes the keyboard, `step` away; at either end the focus stays.
- (void)moveFocus:(NSInteger)step {
    NSUInteger current = [self indexOfKey:_focusedKey];
    if (current == NSNotFound) {
        [self focusFirstItem];
        return;
    }
    for (NSInteger index = (NSInteger)current + step; index >= 0 && index < (NSInteger)_items.count; index += step) {
        if (!Focusable(_items[(NSUInteger)index])) continue;
        [self focusKey:_items[(NSUInteger)index].key];
        return;
    }
}

- (void)actOnFocused {
    if (!_focusedKey) return;
    [self revealKey:_focusedKey];
    [[self rowForKey:_focusedKey] performPrimaryAction];
}

@end
