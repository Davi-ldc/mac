// Owns the Actions menu: its glass background, drawn rows in groups, filtering, selection
// and scrolling.
#import "actionmenu.h"
#import "drawnview.h"
#import "keycaps.h"
#import "theme.h"

/// Measured from Raycast's menus: rows 36 points, content 16 points from the edges, a title
/// 24 points high, groups 16 points apart with a hairline between them, and at most 239
/// points of rows before they scroll.
static const CGFloat kWidth = 350, kRadius = 18, kRow = 36, kPadding = 8, kContent = 16;
static const CGFloat kIconSize = 16, kIconGap = 8, kFilterHeight = 40, kTitleHeight = 24, kGroupGap = 16, kMaxRowsHeight = 239;

/// Draws the rows; the menu owns the data and the selection.
@interface DKActionRows : DKDrawnView
@property(copy) NSArray<DKAction *> *actions;
@property(copy, nullable) NSString *title;
/// Groups are kept apart only while the menu is not filtered.
@property BOOL grouped;
@property NSInteger selected;
/// How far the rows are scrolled.
@property CGFloat offset;
@end

@implementation DKActionRows

- (BOOL)isFlipped { return YES; }

/// The top of each row, unscrolled, and in `height` where the last one ends.
- (NSArray<NSNumber *> *)rowTops:(CGFloat *)height {
    NSMutableArray *tops = [NSMutableArray new];
    CGFloat y = kPadding + (_title ? kTitleHeight : 0);
    for (NSUInteger i = 0; i < _actions.count; i++) {
        if (i && _grouped && _actions[i].startsSection) y += kGroupGap;
        [tops addObject:@(y)];
        y += kRow;
    }
    if (height) *height = y + kPadding;
    return tops;
}

- (CGFloat)contentHeight {
    CGFloat height;
    [self rowTops:&height];
    return height;
}

- (NSInteger)rowAt:(CGFloat)y {
    NSArray<NSNumber *> *tops = [self rowTops:NULL];
    for (NSUInteger i = 0; i < tops.count; i++)
        if (y + _offset >= tops[i].doubleValue && y + _offset < tops[i].doubleValue + kRow) return (NSInteger)i;
    return -1;
}

- (void)scrollToSelection {
    NSArray<NSNumber *> *tops = [self rowTops:NULL];
    if (_selected < 0 || _selected >= (NSInteger)tops.count) return;
    CGFloat top = tops[_selected].doubleValue, visible = self.bounds.size.height;
    // The first row brings the title back into view.
    if (_selected == 0) _offset = 0;
    else if (top - kPadding < _offset) _offset = top - kPadding;
    else if (top + kRow + kPadding > _offset + visible) _offset = top + kRow + kPadding - visible;
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat limit = MAX(0, self.contentHeight - self.bounds.size.height);
    _offset = MAX(0, MIN(limit, _offset - event.scrollingDeltaY));
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty {
    CGFloat width = self.bounds.size.width;
    NSAffineTransform *scroll = [NSAffineTransform transform];
    [scroll translateXBy:0 yBy:-_offset];
    [scroll concat];
    if (_title) {
        NSDictionary *style = @{NSFontAttributeName : DKFont(11, 400), NSForegroundColorAttributeName : DKTextSecondary()};
        NSSize size = [_title sizeWithAttributes:style];
        // Raycast raises section titles a point and a half above the middle of their band.
        [_title drawAtPoint:NSMakePoint(kContent, kPadding + (kTitleHeight - size.height) / 2 - 1.5) withAttributes:style];
    }
    NSArray<NSNumber *> *tops = [self rowTops:NULL];
    for (NSInteger i = 0; i < (NSInteger)_actions.count; i++) {
        DKAction *action = _actions[i];
        CGFloat y = tops[i].doubleValue;
        if (i && _grouped && action.startsSection) [self drawSeparatorAt:y - kGroupGap / 2 width:width];
        if (i == _selected) {
            [DKWhite(0.1) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(kPadding, y, width - 2 * kPadding, kRow)
                                             xRadius:DKRowRadius yRadius:DKRowRadius] fill];
        }
        NSColor *color = action.destructive ? NSColor.systemRedColor : DKTextPrimary();
        if (action.symbol) {
            NSImage *icon = [[NSImage imageWithSystemSymbolName:action.symbol accessibilityDescription:nil]
                imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
            NSSize size = icon.size;
            CGFloat scale = MIN(kIconSize / size.width, kIconSize / size.height);
            NSRect box = NSMakeRect(kContent + (kIconSize - size.width * scale) / 2, y + (kRow - size.height * scale) / 2,
                                    size.width * scale, size.height * scale);
            [icon drawInRect:box fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                respectFlipped:YES hints:nil];
        }
        NSDictionary *style = @{NSFontAttributeName : DKFont(13, 400), NSForegroundColorAttributeName : color};
        NSSize titleSize = [action.title sizeWithAttributes:style];
        [action.title drawAtPoint:NSMakePoint(kContent + kIconSize + kIconGap, y + (kRow - titleSize.height) / 2)
                   withAttributes:style];
        CGFloat capsWidth = DKKeycapsWidth(action.shortcut);
        DKDrawKeycaps(action.shortcut, width - kContent + 1 - capsWidth, y + kRow / 2);
    }
}

/// A hairline across the menu that fades out over its last tenths at either end.
- (void)drawSeparatorAt:(CGFloat)y width:(CGFloat)width {
    NSGradient *fade = [[NSGradient alloc] initWithColorsAndLocations:DKWhite(0), 0.0, DKWhite(0.1), 0.1, DKWhite(0.1), 0.9,
                                                                      DKWhite(0), 1.0, nil];
    CGFloat hairline = 1 / MAX(1, self.window.backingScaleFactor);
    [fade drawInRect:NSMakeRect(0, y - hairline / 2, width, hairline) angle:0];
}

@end

@interface DKActionMenu () <NSTextFieldDelegate>
@end

@implementation DKActionMenu {
    NSView *_glass;
    /// Above the filter field.
    NSView *_separator;
    DKActionRows *_rows;
    NSArray<DKAction *> *_all;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
    shadow.shadowBlurRadius = 20;
    shadow.shadowOffset = NSMakeSize(0, -8);
    self.shadow = shadow;

    // A step lighter than the panel, as Raycast's menus are, and hiding the rows beneath.
    _glass = DKGlass(0.12, kRadius);
    [self addSubview:_glass];

    _separator = [NSView new];
    _separator.wantsLayer = YES;
    _separator.layer.backgroundColor = DKWhite(0.1).CGColor;
    [self addSubview:_separator];

    _rows = [DKActionRows new];
    [self addSubview:_rows];

    _filterField = [NSTextField new];
    _filterField.bezeled = NO;
    _filterField.drawsBackground = NO;
    _filterField.focusRingType = NSFocusRingTypeNone;
    _filterField.font = DKFont(13, 400);
    _filterField.textColor = DKTextPrimary();
    _filterField.delegate = self;
    _filterField.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:@"Search for actions..."
            attributes:@{NSForegroundColorAttributeName : DKTextTertiary(), NSFontAttributeName : _filterField.font}];
    [self addSubview:_filterField];
    return self;
}

- (void)showActions:(NSArray<DKAction *> *)actions title:(NSString *)title anchoredAt:(NSPoint)corner {
    _all = [actions copy];
    _rows.title = title;
    _filterField.stringValue = @"";
    [self showFiltered:_all];
    CGFloat height = MIN(kMaxRowsHeight, MAX(_rows.contentHeight, 2 * kPadding + kRow)) + kFilterHeight;
    self.frame = NSMakeRect(corner.x - kWidth, corner.y - height, kWidth, height);
    _glass.frame = self.bounds;
    CGFloat listHeight = height - kFilterHeight;
    _rows.frame = NSMakeRect(0, 0, kWidth, listHeight);
    _separator.frame = NSMakeRect(0, listHeight, kWidth, 1);
    _filterField.frame = NSMakeRect(kContent, listHeight + (kFilterHeight - 18) / 2, kWidth - 2 * kContent, 18);
}

- (void)showFiltered:(NSArray<DKAction *> *)actions {
    _rows.actions = actions;
    _rows.grouped = actions == _all;
    _rows.selected = actions.count ? 0 : -1;
    _rows.offset = 0;
    _rows.needsDisplay = YES;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    NSString *query = _filterField.stringValue;
    [self showFiltered:query.length ? [_all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DKAction *action, id bindings) {
        return [action.title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
    }]] : _all];
}

- (void)moveSelection:(NSInteger)step {
    NSInteger count = _rows.actions.count;
    if (!count) return;
    _rows.selected = MAX(0, MIN(count - 1, _rows.selected + step));
    [_rows scrollToSelection];
    _rows.needsDisplay = YES;
}

- (DKAction *)selectedAction {
    NSInteger index = _rows.selected;
    return index >= 0 && index < (NSInteger)_rows.actions.count ? _rows.actions[index] : nil;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [_rows convertPoint:event.locationInWindow fromView:nil];
    if (point.y < 0 || point.y >= _rows.bounds.size.height) return;
    NSInteger index = [_rows rowAt:point.y];
    if (index < 0) return;
    _rows.selected = index;
    if (self.onChoose) self.onChoose(_rows.actions[index]);
}

@end
