// Owns the picker's sections, its virtualized grid, tabs, search, footer and skin tones.
#import "render/document.h"
#import "render/emoji.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/emoji/picker.h"
#import "ui/kit/button.h"
#import "ui/kit/filter.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

// Measured on design/ref/live/picker (points from the picker's outer top-left): a 1 pt #3a3d40
// border; 32x28 tabs every 34.25 pt from x 8.75, 10.75 down; the search field 18-345 x 53-91;
// the list from 98 to the footer at 427; cells 36x32 every 37 x 33 pt from x 16; section titles
// 27.25 pt above their first row; the footer 61.5 pt on #212428.
static const CGFloat kTabTop = 10.75, kTabLeft = 8.75, kTabPitch = 34.25, kTabWidth = 32, kTabHeight = 28;
static const NSRect kSearchFrame = {{18, 53}, {327, 38}};
static const CGFloat kListTop = 98, kFooterTop = 427;
static const CGFloat kCellLeft = 15, kCellWidth = 36, kCellHeight = 32, kColumnPitch = 37, kRowPitch = 33, kHeader = 27.25, kSectionGap = 1;
static const CGFloat kListPaddingTop = 6, kListPaddingBottom = 8;
static const NSUInteger kColumns = 9;
/// Emoji sizes: 18.5 pt in the cells, 20 in the preview, 18 in the skin tone choice.
static const CGFloat kCellEmoji = 18.5, kPreviewEmoji = 20, kToneEmoji = 18;
/// The tab glyphs and the footer's top line are measured; the rest are Slack's colours.
static const SNColorToken kTabIcon = 0x808385ff, kFooterLine = 0x1d1f22ff, kHeaderText = SNLegacyPrimaryForeground, kListText = SNLegacyPrimaryForeground;
static const SNColorToken kPreviewText = SNLegacyForegroundMaxSolid;
/// components.json emoji_picker cell_hover, at 70% (measured live), in the web client's order.
static const SNColorToken kCellTints[] = {0x9bdf58b3, 0x95d3feb3, 0xf7e922b3, 0xeea6fcb3, 0xffd58fb3, 0xd3d1ffb3};
/// The skin tone swatches' hands, light to dark (tone 1 is no tone).
static NSString *const kHand = @"raised_hand";

/// Slack's "Where work happens" set, shown after the frequently used ones.
static NSArray<NSString *> *WorkEmoji(void) {
    return @[
        @"white_check_mark", @"eyes", @"raised_hands", @"pray", @"heavy_plus_sign", @"clap", @"bulb", @"dart", @"wave", @"+1", @"tada", @"one", @"two",
        @"three", @"mega", @"white_circle", @"large_blue_circle", @"red_circle", @"cool", @"ok", @"sos", @"rotating_light", @"rocket", @"fire",
        @"heart", @"100"
    ];
}

#pragma mark Model

@interface SNPickerItem : NSObject
/// The name without a skin tone.
@property (nonatomic, copy) NSString *name;
/// nil for a custom emoji.
@property (nonatomic, nullable) SNEmoji *emoji;
@end

@implementation SNPickerItem

- (NSString *)nameWithTone:(NSInteger)tone {
    return self.emoji.hasSkinTones && tone >= 2 ? [NSString stringWithFormat:@"%@::skin-tone-%ld", self.name, (long)tone] : self.name;
}

@end

@interface SNPickerSection : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy) NSArray<SNPickerItem *> *items;
/// The tab that scrolls to it, or NSNotFound.
@property (nonatomic) NSUInteger tab;
/// Laid out: top in the grid and the index of its first row among all rows (for the tints).
@property (nonatomic) CGFloat top;
@property (nonatomic) NSUInteger firstRow;
@property (nonatomic, readonly) NSUInteger rows;
@property (nonatomic, readonly) CGFloat height;
@end

@implementation SNPickerSection

- (NSUInteger)rows { return (self.items.count + kColumns - 1) / kColumns; }
- (CGFloat)height { return (self.title ? kHeader : 0) + self.rows * kRowPitch + kSectionGap; }

- (NSRect)cellRect:(NSUInteger)index {
    return NSMakeRect(kCellLeft + (index % kColumns) * kColumnPitch, self.top + (self.title ? kHeader : 0) + (index / kColumns) * kRowPitch, kCellWidth, kCellHeight);
}

@end

static SNPickerItem *ItemNamed(NSString *name) {
    SNPickerItem *item = [SNPickerItem new];
    item.name = SNEmojiBaseName(name);
    item.emoji = SNEmojiNamed(item.name);
    return item.emoji || SNCustomEmojiURL(item.name) ? item : nil;
}

/// The workspace's custom pictures whose name passes `filter`, by name (aliases of standard
/// emoji are left to the standard ones).
static NSArray<SNPickerItem *> *CustomItems(BOOL (^filter)(NSString *name)) {
    NSMutableArray<SNPickerItem *> *items = [NSMutableArray new];
    for (NSString *name in SNCustomEmojiNames()) {
        if (!filter(name) || !SNCustomEmojiURL(name)) continue;
        SNPickerItem *item = [SNPickerItem new];
        item.name = name;
        [items addObject:item];
    }
    return items;
}

#pragma mark Grid

@interface SNEmojiGridView : NSView <SNCursorProvider>
@property (nonatomic, copy) NSArray<SNPickerSection *> *sections;
@property (nonatomic) NSInteger tone;
@property (nonatomic, copy, nullable) void (^pick)(SNPickerItem *item);
@property (nonatomic, copy, nullable) void (^highlightChanged)(SNPickerItem *_Nullable item);
@property (nonatomic, readonly, nullable) SNPickerItem *highlighted;
/// `reveal` scrolls the cell into view: for the keyboard, never under the pointer.
- (void)highlightItem:(nullable SNPickerItem *)item reveal:(BOOL)reveal;
- (void)moveHighlightBy:(NSInteger)columns rows:(NSInteger)rows;
@end

@implementation SNEmojiGridView {
    /// Two tint layers so the old cell fades out while the new one fades in.
    SNLayer *_tints[2];
    NSUInteger _currentTint;
    NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    for (int i = 0; i < 2; i++) {
        _tints[i] = [SNLayer layer];
        _tints[i].cornerRadius = 6;
        _tints[i].opacity = 0;
        _tints[i].zPosition = -1;
        [self.layer addSublayer:_tints[i]];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) [self.imageHolder removeAllImages];
}

- (void)setSections:(NSArray<SNPickerSection *> *)sections {
    [self.imageHolder removeAllImages];
    _sections = [sections copy];
    CGFloat y = kListPaddingTop;
    NSUInteger row = 0;
    for (SNPickerSection *section in sections) {
        section.top = y;
        section.firstRow = row;
        y += section.height;
        row += section.rows;
    }
    [self setFrameSize:NSMakeSize(NSWidth(self.frame), y + kListPaddingBottom)];
    [self highlightItem:nil reveal:NO];
    self.needsDisplay = YES;
}

- (void)setTone:(NSInteger)tone {
    _tone = tone;
    self.needsDisplay = YES;
}

/// The section and index of the cell at `point`, or NO.
- (BOOL)cellAt:(NSPoint)point section:(SNPickerSection **)found index:(NSUInteger *)index {
    for (SNPickerSection *section in self.sections) {
        if (point.y < section.top || point.y >= section.top + section.height) continue;
        CGFloat y = point.y - section.top - (section.title ? kHeader : 0), x = point.x - kCellLeft;
        if (y < 0 || x < 0) return NO;
        NSUInteger column = (NSUInteger)(x / kColumnPitch), row = (NSUInteger)(y / kRowPitch);
        NSUInteger i = row * kColumns + column;
        if (column >= kColumns || i >= section.items.count || fmod(x, kColumnPitch) > kCellWidth) return NO;
        *found = section;
        *index = i;
        return YES;
    }
    return NO;
}

- (BOOL)locate:(SNPickerItem *)item section:(SNPickerSection **)found index:(NSUInteger *)index {
    for (SNPickerSection *section in self.sections) {
        NSUInteger i = [section.items indexOfObjectIdenticalTo:item];
        if (i == NSNotFound) continue;
        *found = section;
        *index = i;
        return YES;
    }
    return NO;
}

- (void)highlightItem:(SNPickerItem *)item reveal:(BOOL)reveal {
    if (item == _highlighted) return;
    _highlighted = item;
    SNLayer *old = _tints[_currentTint];
    // emoji-cell-hover (live): in over 50 ms; out over 150 ms after 50 ms.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLiveEmojiCellOutDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (old != self->_tints[self->_currentTint] || !self.highlighted) SNAnimate(SNLiveEmojiCellOut, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut], ^{ old.opacity = 0; });
    });
    SNPickerSection *section;
    NSUInteger index;
    if (item && [self locate:item section:&section index:&index]) {
        _currentTint = 1 - _currentTint;
        SNLayer *tint = _tints[_currentTint];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        tint.frame = [section cellRect:index];
        tint.backgroundColor = SNCGColor(kCellTints[((section.firstRow + index / kColumns) * kColumns + index % kColumns) % 6]);
        [CATransaction commit];
        SNAnimate(SNLiveEmojiCellIn, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut], ^{ tint.opacity = 1; });
        if (reveal) [self scrollRectToVisible:NSInsetRect(tint.frame, 0, -4)];
    }
    if (self.highlightChanged) self.highlightChanged(item);
}

- (void)moveHighlightBy:(NSInteger)columns rows:(NSInteger)rows {
    NSMutableArray<SNPickerItem *> *all = [NSMutableArray new];
    for (SNPickerSection *section in self.sections) [all addObjectsFromArray:section.items];
    if (!all.count) return;
    SNPickerSection *section;
    NSUInteger index;
    if (!self.highlighted || ![self locate:self.highlighted section:&section index:&index]) return [self highlightItem:all.firstObject reveal:YES];
    // Rows move within the section's grid, then on to the neighbouring section.
    NSInteger target = (NSInteger)index + columns + rows * (NSInteger)kColumns;
    if (target >= 0 && target < (NSInteger)section.items.count) return [self highlightItem:section.items[(NSUInteger)target] reveal:YES];
    NSInteger flat = (NSInteger)[all indexOfObjectIdenticalTo:self.highlighted] + (columns ?: rows * (NSInteger)kColumns);
    [self highlightItem:all[(NSUInteger)MAX(0, MIN((NSInteger)all.count - 1, flat))] reveal:YES];
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

- (void)mouseMoved:(NSEvent *)event {
    SNPickerSection *section;
    NSUInteger index;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self highlightItem:[self cellAt:point section:&section index:&index] ? section.items[index] : nil reveal:NO];
}

- (void)mouseExited:(NSEvent *)event { [self highlightItem:nil reveal:NO]; }
- (void)mouseDown:(NSEvent *)event {}

- (NSCursor *)cursorAtPoint:(NSPoint)point {
    SNPickerSection *section;
    NSUInteger index;
    return [self cellAt:point section:&section index:&index] ? NSCursor.pointingHandCursor : nil;
}

- (void)mouseUp:(NSEvent *)event {
    SNPickerSection *section;
    NSUInteger index;
    if ([self cellAt:[self convertPoint:event.locationInWindow fromView:nil] section:&section index:&index] && self.pick) self.pick(section.items[index]);
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    NSFont *headerFont = SNFont(SNFontSizeCaption, SNFontWeightBold);
    for (SNPickerSection *section in self.sections) {
        if (section.top > NSMaxY(dirtyRect) || section.top + section.height < NSMinY(dirtyRect)) continue;
        if (section.title)
            SNDrawText(section.title, headerFont, kHeaderText, 24, NSTextAlignmentLeft, 1, NSMakeRect(kCellLeft + 5, section.top, NSWidth(self.bounds) - kCellLeft - 10, 24));
        // Only the rows in the dirty rect are drawn: the grid is one view however long the list is.
        CGFloat rowsTop = section.top + (section.title ? kHeader : 0);
        NSUInteger first = (NSUInteger)MAX(0, floor((NSMinY(dirtyRect) - rowsTop) / kRowPitch));
        NSUInteger last = (NSUInteger)MAX(0, ceil((NSMaxY(dirtyRect) - rowsTop) / kRowPitch));
        for (NSUInteger i = first * kColumns; i < MIN(section.items.count, (last + 1) * kColumns); i++) {
            SNPickerItem *item = section.items[i];
            NSRect cell = [section cellRect:i];
            if (!NSIntersectsRect(cell, dirtyRect)) continue;
            // Measured: the capture's glyphs sit half a point above the cell's centre.
            SNDrawEmoji([item nameWithTone:self.tone], kCellEmoji, NSOffsetRect(cell, 0, -0.5), self.imageHolder);
        }
    }
}

@end

#pragma mark Search field

/// The search field: 36 pt inside a ring, which turns blue while it has the caret
/// (emoji-tab-hover LIVE: 1 pt #2aa5ce with a 30% band out to 5 pt).
@interface SNPickerSearchField : NSView
@property (nonatomic, readonly) NSTextField *field;
@property (nonatomic) BOOL focused;
@end

@implementation SNPickerSearchField {
    SNFocusRingLayer *_ring;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.clipsToBounds = NO;
    _ring = [SNFocusRingLayer layer];
    _ring.opacity = 0;
    [self.layer addSublayer:_ring];
    _field = [NSTextField textFieldWithString:@""];
    _field.bezeled = NO;
    _field.bordered = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    _field.textColor = SNColor(SNColorContentPry);
    _field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:SNLocalized(@"emoji.search")
                                                                         attributes:@{NSFontAttributeName : _field.font, NSForegroundColorAttributeName : SNColor(SNColorContentTer)}];
    _field.cell.scrollable = YES;
    [self addSubview:_field];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_ring setRingAroundRect:CGRectInset(self.bounds, 1, 1) radius:7];
    [CATransaction commit];
    CGFloat height = ceil(_field.intrinsicContentSize.height);
    _field.frame = NSMakeRect(13, round((NSHeight(self.bounds) - height) / 2), NSWidth(self.bounds) - 26, height);
}

- (void)setFocused:(BOOL)focused {
    _focused = focused;
    _ring.opacity = focused ? 1 : 0;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = self.bounds;
    if (self.focused) {
        [SNColor(SNMeasuredEmojiPickerBg) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 1, 1) xRadius:7 yRadius:7] fill];
    } else {
        NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:7.5 yRadius:7.5];
        [SNColor(SNColorOtlSec) setStroke];
        [ring stroke];
    }
}

@end

#pragma mark Picker view

@interface SNEmojiPickerView () <NSTextFieldDelegate, SNChangeObserver>
@end

@implementation SNEmojiPickerView {
    id<SNSource> _source;
    NSArray<SNButton *> *_tabButtons;
    SNPickerSearchField *_search;
    NSScrollView *_scroll;
    SNEmojiGridView *_grid;
    NSArray<SNPickerSection *> *_browseSections;
    NSUInteger _activeTab;
    SNButton *_addButton, *_toneButton;
    NSView *_tones;
    SNPickerItem *_preview;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:(NSRect){NSZeroPoint, SNEmojiPickerSize}])) return nil;
    _source = source;
    _query = @"";
    self.wantsLayer = YES;
    // The menu shadow; the picker draws its own fill and border.
    self.layer.shadowColor = SNCGColor(0x000000ff);
    self.layer.shadowOpacity = 0.12;
    self.layer.shadowRadius = 6;
    self.layer.shadowOffset = CGSizeMake(0, -4);

    // Slack shows the search glyph on its "Frequently Used" tab.
    NSArray *icons = @[ @"search", @"emoji-filled", @"emoji-nature", @"emoji-food", @"emoji-travel", @"emoji-activities", @"emoji-objects", @"emoji-symbols", @"emoji-flag", @"slack-logo" ];
    NSArray *tips = @[ @"emoji.tab.frequent", @"emoji.tab.people", @"emoji.tab.nature", @"emoji.tab.food", @"emoji.tab.travel", @"emoji.tab.activities",
                       @"emoji.tab.objects", @"emoji.tab.symbols", @"emoji.tab.flags", @"emoji.tab.custom" ];
    NSMutableArray *tabs = [NSMutableArray new];
    for (NSUInteger i = 0; i < icons.count; i++) {
        SNButton *tab = [SNButton iconButtonNamed:icons[i] size:kTabHeight iconSize:20];
        tab.frame = NSMakeRect(kTabLeft + i * kTabPitch, kTabTop, kTabWidth, kTabHeight);
        tab.cornerRadius = SNRadiusBase;
        tab.contentColor = kTabIcon;
        tab.hoverContentColor = tab.pressedContentColor = SNColorContentPry;
        tab.hoverFillColor = 0;
        tab.transitionDuration = 0;
        tab.tooltip = SNLocalized(tips[i]);
        tab.tooltipPlacement = SNPlacementBelow;
        __weak SNEmojiPickerView *weakSelf = self;
        tab.action = ^(SNButton *sender) { [weakSelf showTab:i]; };
        [tabs addObject:tab];
        [self addSubview:tab];
    }
    _tabButtons = tabs;

    _search = [[SNPickerSearchField alloc] initWithFrame:kSearchFrame];
    _search.field.delegate = self;
    [self addSubview:_search];

    _grid = [[SNEmojiGridView alloc] initWithFrame:NSMakeRect(0, 0, SNEmojiPickerSize.width - 2, 100)];
    __weak SNEmojiPickerView *weakSelf = self;
    _grid.pick = ^(SNPickerItem *item) { [weakSelf choose:item]; };
    _grid.highlightChanged = ^(SNPickerItem *item) { [weakSelf showPreview:item]; };
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(1, kListTop, SNEmojiPickerSize.width - 2, kFooterTop - kListTop)];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.documentView = _grid;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(listDidScroll:) name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    [self addSubview:_scroll];

    _addButton = [SNButton outlineButtonWithTitle:SNLocalized(@"emoji.add")];
    _addButton.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    _addButton.frame = NSMakeRect(15, kFooterTop + 17.5, MAX(115.5, ceil(_addButton.fittingContentSize.width) + 24), 28);
    _addButton.action = ^(SNButton *sender) { [weakSelf openCustomize]; };
    [self addSubview:_addButton];
    _toneButton = [SNButton new];
    _toneButton.title = SNLocalized(@"emoji.tone");
    _toneButton.font = SNFont(SNFontSizeBase, SNFontWeightBold);
    _toneButton.contentColor = kListText;
    _toneButton.hoverContentColor = _toneButton.pressedContentColor = SNColorContentPry;
    _toneButton.hoverColor = 0;
    _toneButton.action = ^(SNButton *sender) { [weakSelf showTones]; };
    [self addSubview:_toneButton];

    [self reload];
    [source addChangeObserver:self];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)isFlipped { return YES; }
- (NSArray<SNHoverView *> *)tabs { return _tabButtons; }

- (void)sourceChanged:(SNChange *)change {
    // A closed picker is not drawn again (a reaction picked with it changes frequent emoji).
    if (change.emoji && self.window) [self reload];
}

/// The browsing sections: frequently used, Slack's work set, the categories, the custom emoji.
- (void)reload {
    NSMutableArray<SNPickerSection *> *sections = [NSMutableArray new];
    void (^add)(NSString *, NSArray<SNPickerItem *> *, NSUInteger) = ^(NSString *title, NSArray *items, NSUInteger tab) {
        if (!items.count) return;
        SNPickerSection *section = [SNPickerSection new];
        section.title = title;
        section.items = items;
        section.tab = tab;
        [sections addObject:section];
    };
    NSMutableArray *frequent = [NSMutableArray new];
    for (NSString *name in _source.frequentEmoji) {
        SNPickerItem *item = ItemNamed(name);
        if (item && frequent.count < kColumns * 2) [frequent addObject:item];
    }
    add(SNLocalized(@"emoji.section.frequent"), frequent, 0);
    NSMutableArray *work = [NSMutableArray new];
    for (NSString *name in WorkEmoji()) {
        SNPickerItem *item = ItemNamed(name);
        if (item) [work addObject:item];
    }
    add(SNLocalized(@"emoji.section.work"), work, frequent.count ? NSNotFound : 0);
    struct {
        NSString *key;
        SNEmojiCategory categories[2];
        NSUInteger count, tab;
    } categories[] = {
        {@"emoji.section.people", {SNEmojiCategorySmileys, SNEmojiCategoryPeople}, 2, 1},
        {@"emoji.section.nature", {SNEmojiCategoryNature}, 1, 2},
        {@"emoji.section.food", {SNEmojiCategoryFood}, 1, 3},
        {@"emoji.section.travel", {SNEmojiCategoryTravel}, 1, 4},
        {@"emoji.section.activities", {SNEmojiCategoryActivities}, 1, 5},
        {@"emoji.section.objects", {SNEmojiCategoryObjects}, 1, 6},
        {@"emoji.section.symbols", {SNEmojiCategorySymbols}, 1, 7},
        {@"emoji.section.flags", {SNEmojiCategoryFlags}, 1, 8},
    };
    for (size_t c = 0; c < sizeof categories / sizeof *categories; c++) {
        NSMutableArray *items = [NSMutableArray new];
        for (NSUInteger k = 0; k < categories[c].count; k++)
            for (SNEmoji *emoji in SNEmojiInCategory(categories[c].categories[k])) {
                SNPickerItem *item = [SNPickerItem new];
                item.name = emoji.name;
                item.emoji = emoji;
                [items addObject:item];
            }
        add(SNLocalized(categories[c].key), items, categories[c].tab);
    }
    add(SNLocalized(@"emoji.section.custom"), CustomItems(^BOOL(NSString *name) { return YES; }), 9);
    _browseSections = sections;
    _grid.tone = _source.preferredSkinTone;
    // What changed (frequent emoji, the workspace's custom ones) leaves the search and the
    // scroll position as they were.
    NSPoint scrolled = _scroll.contentView.bounds.origin;
    [self applyQuery];
    if (!_query.length) [self scrollTo:scrolled.y];
    [self updateFooter];
}

- (void)scrollTo:(CGFloat)y {
    [_scroll.contentView scrollToPoint:NSMakePoint(0, MAX(0, MIN(y, NSHeight(_grid.frame) - NSHeight(_scroll.contentView.bounds))))];
    [_scroll reflectScrolledClipView:_scroll.contentView];
}

- (void)setQuery:(NSString *)query {
    _query = [query copy];
    if (![_search.field.stringValue isEqualToString:query]) _search.field.stringValue = query;
    [self applyQuery];
}

- (void)applyQuery {
    NSString *query = [_query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
    if (!query.length) {
        _grid.sections = _browseSections;
    } else {
        NSMutableArray *items = [NSMutableArray new];
        for (SNEmoji *emoji in SNEmojiMatching(query, 0)) {
            SNPickerItem *item = [SNPickerItem new];
            item.name = emoji.name;
            item.emoji = emoji;
            [items addObject:item];
        }
        [items addObjectsFromArray:CustomItems(^BOOL(NSString *name) { return [name containsString:query]; })];
        SNPickerSection *results = [SNPickerSection new];
        results.items = items;
        results.tab = NSNotFound;
        _grid.sections = @[ results ];
        // Return picks the first result, as in the web client.
        if (items.count) [_grid highlightItem:items.firstObject reveal:NO];
    }
    [self scrollTo:0];
    [self updateTabs];
}

- (void)setHighlightedEmoji:(NSString *)name {
    SNPickerItem *found = nil;
    for (SNPickerSection *section in _grid.sections)
        for (SNPickerItem *item in section.items)
            if (!found && [item.name isEqualToString:SNEmojiBaseName(name ?: @"")]) found = item;
    [_grid highlightItem:found reveal:YES];
}

- (NSString *)highlightedEmoji { return [_grid.highlighted nameWithTone:_grid.tone]; }

- (void)focusSearch {
    [self.window makeFirstResponder:_search.field];
    _search.focused = YES;
}

#pragma mark Tabs and scrolling

- (void)showTab:(NSUInteger)tab {
    if (_query.length) self.query = @"";
    for (SNPickerSection *section in _grid.sections)
        if (section.tab == tab) {
            [self scrollTo:section.top];
            break;
        }
    _activeTab = tab;
    [self updateTabs];
}

- (void)listDidScroll:(NSNotification *)notification {
    // The active tab follows the section at the top of the list.
    CGFloat top = NSMinY(_scroll.contentView.bounds) + 1;
    for (SNPickerSection *section in _grid.sections)
        if (section.tab != NSNotFound && section.top <= top) _activeTab = section.tab;
    [self updateTabs];
}

- (void)updateTabs {
    if (_query.length) _activeTab = 0;
    for (NSUInteger i = 0; i < _tabButtons.count; i++) {
        SNButton *tab = _tabButtons[i];
        BOOL active = i == _activeTab;
        tab.fillColor = active ? SNMeasuredEmojiTabActive : 0;
        tab.hoverFillColor = active ? SNMeasuredEmojiTabActive : 0;
        tab.contentColor = active ? SNColorContentPry : kTabIcon;
    }
}

#pragma mark Footer

- (void)updateFooter {
    NSString *hand = SNEmojiUnicode(_source.preferredSkinTone >= 2 ? [NSString stringWithFormat:@"%@::skin-tone-%ld", kHand, (long)_source.preferredSkinTone] : kHand);
    _toneButton.title = [NSString stringWithFormat:@"%@ %@", hand ?: @"", SNLocalized(@"emoji.tone")];
    NSSize size = _toneButton.fittingContentSize;
    _toneButton.frame = NSMakeRect(SNEmojiPickerSize.width - 28 - size.width, kFooterTop + 17.5, size.width, 28);
    self.needsDisplay = YES;
}

- (void)showPreview:(SNPickerItem *)item {
    _preview = item;
    // The preview replaces the footer's buttons while a cell is highlighted.
    _addButton.hidden = _toneButton.hidden = item != nil || _tones != nil;
    [self setNeedsDisplayInRect:NSMakeRect(0, kFooterTop, SNEmojiPickerSize.width, SNEmojiPickerSize.height - kFooterTop)];
}

- (void)showTones {
    [_tones removeFromSuperview];
    // The six hands, 36x32 each, in a 10 pt rounded box where the footer's button was.
    NSView *tones = [[NSView alloc] initWithFrame:NSMakeRect(SNEmojiPickerSize.width - 16 - 6 * 36 - 8, kFooterTop + 14.5, 6 * 36 + 8, 36)];
    tones.wantsLayer = YES;
    tones.layer.backgroundColor = SNCGColor(SNColorBasePry);
    tones.layer.cornerRadius = 10;
    tones.layer.borderWidth = 1;
    tones.layer.borderColor = SNCGColor(SNColorOtlTer);
    for (NSInteger tone = 1; tone <= 6; tone++) {
        NSString *name = tone >= 2 ? [NSString stringWithFormat:@"%@::skin-tone-%ld", kHand, (long)tone] : kHand;
        SNButton *option = [SNButton new];
        option.title = SNEmojiUnicode(name) ?: @"";
        option.font = SNEmojiFont(kToneEmoji);
        option.cornerRadius = SNRadiusBase;
        option.fillColor = (tone == MAX(1, _source.preferredSkinTone)) ? SNColorCtrPry : 0;
        option.frame = NSMakeRect(4 + (tone - 1) * 36, 2, 36, 32);
        __weak SNEmojiPickerView *weakSelf = self;
        option.action = ^(SNButton *sender) { [weakSelf chooseTone:tone]; };
        [tones addSubview:option];
    }
    _tones = tones;
    _addButton.hidden = _toneButton.hidden = YES;
    [self addSubview:tones];
}

- (void)chooseTone:(NSInteger)tone {
    [_source setPreferredSkinTone:tone >= 2 ? tone : 0];
    [_tones removeFromSuperview];
    _tones = nil;
    _grid.tone = _source.preferredSkinTone;
    _addButton.hidden = _toneButton.hidden = NO;
    [self updateFooter];
}

- (void)openCustomize {
    NSURL *url = [_source.workspace.url URLByAppendingPathComponent:@"customize/emoji"];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

/// Who receives the emoji counts it as used (the composer, the reaction).
- (void)choose:(SNPickerItem *)item {
    if (self.completion) self.completion([item nameWithTone:_grid.tone]);
}

#pragma mark Search field delegate

- (void)controlTextDidChange:(NSNotification *)notification {
    _query = [_search.field.stringValue copy];
    [self applyQuery];
}

- (void)controlTextDidBeginEditing:(NSNotification *)notification { _search.focused = YES; }
- (void)controlTextDidEndEditing:(NSNotification *)notification { _search.focused = NO; }

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command == @selector(moveUp:)) [_grid moveHighlightBy:0 rows:-1];
    else if (command == @selector(moveDown:)) [_grid moveHighlightBy:0 rows:1];
    else if (command == @selector(moveLeft:) && _grid.highlighted && !_query.length) [_grid moveHighlightBy:-1 rows:0];
    else if (command == @selector(moveRight:) && _grid.highlighted && !_query.length) [_grid moveHighlightBy:1 rows:0];
    else if (command == @selector(insertNewline:) && _grid.highlighted) [self choose:_grid.highlighted];
    else return NO;
    return YES;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    NSRect bounds = self.bounds;
    CGFloat radius = SNRadiusLarge;
    [SNColor(SNMeasuredEmojiPickerBorder) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius] fill];
    NSRect inner = NSInsetRect(bounds, 1, 1);
    [SNColor(SNMeasuredEmojiPickerBg) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:inner xRadius:radius - 1 yRadius:radius - 1] fill];
    // The footer: #212428 under a hairline, clipped to the bottom corners.
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:inner xRadius:radius - 1 yRadius:radius - 1] addClip];
    [SNColor(SNColorCtrPry) setFill];
    NSRectFill(NSMakeRect(NSMinX(inner), kFooterTop, NSWidth(inner), NSMaxY(inner) - kFooterTop));
    [SNColor(kFooterLine) setFill];
    NSRectFill(NSMakeRect(NSMinX(inner), kFooterTop - 1, NSWidth(inner), 1));
    [NSGraphicsContext restoreGraphicsState];
    if (_preview) {
        NSRect box = NSMakeRect(13, kFooterTop + (NSMaxY(inner) - kFooterTop - 32) / 2, 32, 32);
        SNDrawEmoji([_preview nameWithTone:_grid.tone], kPreviewEmoji, box, self.imageHolder);
        SNDrawText([NSString stringWithFormat:@":%@:", [_preview nameWithTone:_grid.tone]], SNFont(SNFontSizeBase, SNFontWeightBold), kPreviewText, 22, NSTextAlignmentLeft, 1,
                   NSMakeRect(47, NSMidY(box) - 11, NSWidth(bounds) - 47 - 16, 22));
    }
}

@end

#pragma mark Popover

@implementation SNEmojiPicker {
    SNPopover *_popover;
}

static SNEmojiPicker *current;

+ (SNEmojiPicker *)current { return current; }

+ (instancetype)showForRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement source:(id<SNSource>)source completion:(void (^)(NSString *))completion {
    SNEmojiPicker *picker = [self new];
    SNEmojiPickerView *content = [[SNEmojiPickerView alloc] initWithSource:source];
    __weak SNEmojiPicker *weakPicker = picker;
    content.completion = ^(NSString *name) {
        [weakPicker close];
        completion(name);
    };
    // popover-open-close (live): no fade either way.
    picker->_popover = [SNPopover showContent:content forRect:rect inView:view placement:placement gap:4];
    picker->_popover.onClose = ^{
        SNEmojiPicker *strong = weakPicker;
        if (current == strong) current = nil;
        if (strong.onClose) strong.onClose();
    };
    [content focusSearch];
    current = picker;
    return picker;
}

- (void)close { [_popover close]; }

@end
