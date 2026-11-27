// Owns showing and closing popovers, and the menu's rows, highlight and keys.
#import "render/icon.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

static const unsigned short kEscape = 53, kReturn = 36, kUp = 126, kDown = 125;

@implementation SNPopover {
    id _monitor;
    /// What had the keyboard before the popover opened, given it back on close.
    __weak NSResponder *_previousResponder;
    __weak NSWindow *_window;
}

static SNPopover *current;

+ (SNPopover *)current { return current; }

+ (instancetype)showContent:(NSView *)content forRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement gap:(CGFloat)gap {
    NSWindow *window = view.window;
    if (!window) return nil;
    // Placed before the open popover closes: the anchor may be inside it and leave the window.
    SNOverlayHost *host = [SNOverlayHost hostForWindow:window];
    NSRect target = [host convertRect:rect fromView:view];
    [current close];
    content.frame = SNPlaceOverlay(content.frame.size, target, placement, gap, NO, host.bounds);
    [host addSubview:content];
    SNPopover *popover = [self new];
    popover->_content = content;
    popover->_window = window;
    popover->_previousResponder = window.firstResponder;
    __weak SNPopover *weakPopover = popover;
    host.outsideClick = ^{ [weakPopover close]; };
    popover->_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode != kEscape) return event;
        [weakPopover close];
        return nil;
    }];
    current = popover;
    return popover;
}

- (void)close {
    NSView *content = _content;
    if (!content.superview) return;
    // A popover held only as `current` would go away as soon as that is cleared.
    __attribute__((objc_precise_lifetime)) SNPopover *alive = self;
    if (current == alive) current = nil;
    [NSEvent removeMonitor:_monitor];
    _monitor = nil;
    ((SNOverlayHost *)content.superview).outsideClick = nil;
    NSWindow *window = _window;
    NSResponder *focused = window.firstResponder;
    // The keyboard goes back unless something outside the popover took it meanwhile (the
    // field editor of a search field inside it counts as inside).
    BOOL inside = focused == window || ([focused isKindOfClass:NSView.class] && [(NSView *)focused isDescendantOf:content]);
    [content removeFromSuperview];
    // The content may hold its owner, which holds the popover.
    _content = nil;
    NSResponder *previous = _previousResponder;
    if (inside && previous && (![previous isKindOfClass:NSView.class] || ((NSView *)previous).window == window)) [window makeFirstResponder:previous];
    void (^onClose)(void) = self.onClose;
    self.onClose = nil;
    if (onClose) onClose();
}

@end

@interface SNMenuItem ()
@property (nonatomic, readonly) BOOL selectable, isSeparator, isHeader;
- (void)perform;
@end

@implementation SNMenuItem {
    void (^_action)(void);
    BOOL _separator, _header;
}

+ (instancetype)itemWithTitle:(NSString *)title action:(void (^)(void))action {
    SNMenuItem *item = [self new];
    item->_title = [title copy] ?: @"";
    item->_action = [action copy];
    item->_iconSize = 16;
    return item;
}

+ (instancetype)separator {
    SNMenuItem *item = [self itemWithTitle:@"" action:nil];
    item->_separator = YES;
    return item;
}

+ (instancetype)headerWithTitle:(NSString *)title {
    SNMenuItem *item = [self itemWithTitle:title action:nil];
    item->_header = YES;
    return item;
}

- (BOOL)selectable { return !_separator && !_header && !self.disabled; }
- (BOOL)isSeparator { return _separator; }
- (BOOL)isHeader { return _header; }
- (void)perform {
    if (_action) _action();
}

@end

/// components.json menu: 12 pt above and below the rows, 28 pt rows padded 24 pt, a 20 pt icon
/// column with 8 pt after it, a 1 pt separator line in 16 pt, headers 13 pt with 4 pt above and
/// below.
static const CGFloat kPadding = 12, kRow = 28, kInset = 24, kIcon = 20, kIconGap = 8, kSeparator = 16, kHeader = 24;
/// A submenu's caret takes the row's 15 px, centred 32 pt from the right (m_msgmore_open).
static const CGFloat kCaret = 15, kCaretCentre = 32;

@interface SNMenu () <SNCursorProvider>
@end

@implementation SNMenu {
    NSArray<SNMenuItem *> *_items;
    NSArray<NSValue *> *_rows;
    NSTrackingArea *_tracking;
}

- (instancetype)initWithItems:(NSArray<SNMenuItem *> *)items width:(CGFloat)width {
    NSMutableArray *rows = [NSMutableArray new];
    CGFloat y = kPadding;
    for (SNMenuItem *item in items) {
        CGFloat height = item.isSeparator ? kSeparator : item.isHeader ? kHeader : kRow;
        [rows addObject:[NSValue valueWithRect:NSMakeRect(0, y, width ?: 300, height)]];
        y += height;
    }
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, width ?: 300, y + kPadding)])) return nil;
    _items = [items copy];
    _rows = rows;
    _highlightedIndex = NSNotFound;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (SNPopover *)showForRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement {
    SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNColorCtrPry radius:SNRadiusMenuLive shadow:SNMenuShadow];
    panel.frame = self.bounds;
    [panel.contentView addSubview:self];
    SNPopover *popover = [SNPopover showContent:panel forRect:rect inView:view placement:placement gap:4];
    [self.window makeFirstResponder:self];
    return popover;
}

- (void)setHighlightedIndex:(NSUInteger)highlightedIndex {
    if (highlightedIndex == _highlightedIndex) return;
    _highlightedIndex = highlightedIndex;
    self.needsDisplay = YES;
}

- (NSUInteger)indexAtPoint:(NSPoint)point {
    for (NSUInteger i = 0; i < _rows.count; i++)
        if (NSPointInRect(point, _rows[i].rectValue) && [_items[i] selectable]) return i;
    return NSNotFound;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event { self.highlightedIndex = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (NSCursor *)cursorAtPoint:(NSPoint)point { return [self indexAtPoint:point] == NSNotFound ? nil : NSCursor.pointingHandCursor; }
- (void)mouseExited:(NSEvent *)event { self.highlightedIndex = NSNotFound; }
- (void)mouseDown:(NSEvent *)event {}

- (void)mouseUp:(NSEvent *)event {
    NSUInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index != NSNotFound) [self choose:index];
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == kReturn && self.highlightedIndex != NSNotFound) {
        [self choose:self.highlightedIndex];
    } else if (event.keyCode == kUp || event.keyCode == kDown) {
        NSInteger step = event.keyCode == kUp ? -1 : 1, count = (NSInteger)_items.count;
        NSInteger index = self.highlightedIndex == NSNotFound ? (step > 0 ? -1 : count) : (NSInteger)self.highlightedIndex;
        for (NSInteger i = index + step; i >= 0 && i < count; i += step)
            if ([_items[(NSUInteger)i] selectable]) {
                self.highlightedIndex = (NSUInteger)i;
                break;
            }
    } else {
        [super keyDown:event];
    }
}

- (void)choose:(NSUInteger)index {
    [SNPopover.current close];
    [_items[index] perform];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSFont *font = SNFont(SNFontSizeBase, SNFontWeightRegular), *small = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    for (NSUInteger i = 0; i < _items.count; i++) {
        SNMenuItem *item = _items[i];
        NSRect row = _rows[i].rectValue;
        if (item.isSeparator) {
            [SNColor(SNColorOtlTer) setFill];
            NSRectFill(NSMakeRect(0, NSMinY(row) + (kSeparator - 1) / 2, row.size.width, 1));
            continue;
        }
        if (item.isHeader) {
            SNDrawText(item.title, small, SNColorContentSec, kHeader - 8, NSTextAlignmentLeft, 1, NSInsetRect(row, kInset, 4));
            continue;
        }
        BOOL highlighted = i == self.highlightedIndex;
        if (highlighted) {
            [SNColor(item.danger ? SNColorBaseInvImp : SNColorBaseInvHgl1) setFill];
            NSRectFill(row);
        }
        SNColorToken color = highlighted     ? SNColorContentPry
                             : item.disabled ? SNColorContentTer
                             : item.danger   ? SNColorContentImp
                             : item.checked  ? SNColorContentHgl1
                                             : SNColorContentPry;
        CGFloat x = kInset;
        // A label starts where the icon would be in rows without one (the capture's "Organizar").
        if (item.icon) {
            SNDrawIcon(item.icon, item.iconSize, color, NSMakeRect(x, NSMinY(row), kIcon, kRow));
            x += kIcon + kIconGap;
        }
        CGFloat shortcutWidth = 0;
        if (item.submenu) {
            SNDrawIcon(@"caret-right", kCaret, color, NSMakeRect(NSMaxX(row) - kCaretCentre - kIcon / 2, NSMinY(row) + (kRow - kIcon) / 2, kIcon, kIcon));
            shortcutWidth = kCaretCentre + kIcon / 2 - kInset;
        } else if (item.shortcut) {
            shortcutWidth = ceil(SNTextWidth(item.shortcut, small)) + 8;
            SNDrawText(item.shortcut, small, highlighted ? SNColorContentPry : SNColorContentTer, kRow, NSTextAlignmentRight, 1,
                       NSMakeRect(NSMaxX(row) - kInset - shortcutWidth, NSMinY(row), shortcutWidth, kRow));
        }
        SNDrawText(item.title, font, color, kRow, NSTextAlignmentLeft, 1,
                   NSMakeRect(x, NSMinY(row), NSMaxX(row) - kInset - shortcutWidth - x, kRow));
    }
}

@end
