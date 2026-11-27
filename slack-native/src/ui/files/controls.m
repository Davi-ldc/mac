// Owns the explorer controls' looks and menus.
#import "render/icon.h"
#import "render/strings.h"
#import "ui/files/controls.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

static const CGFloat kPillPadding = 11, kSelectPadding = 12, kIcon = 18, kIconGap = 2, kCaretGap = 4, kSelectCaret = 16, kSegmentGap = 4;
/// SearchFilterSingleSelect's menu.
static const CGFloat kMenuWidth = 280;

static NSFont *ControlFont(void) { return SNFont(SNFontSizeCaption, SNFontWeightBold); }

static CGFloat TextWidth(NSString *text) { return ceil(SNTextWidth(text, ControlFont())); }

static void DrawBox(NSRect bounds, SNColorToken fill, SNColorToken border) {
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:SNRadiusBase - 0.5 yRadius:SNRadiusBase - 0.5];
    [SNColor(fill) setFill];
    [box fill];
    [SNColor(border) setStroke];
    [box stroke];
}

@implementation SNExplorerPill

- (instancetype)initWithTitle:(NSString *)title {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _title = [title copy];
    self.overlayRadius = SNRadiusBase;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.needsDisplay = YES;
}

- (void)setActive:(BOOL)active {
    _active = active;
    self.needsDisplay = YES;
}

- (CGFloat)fittingWidth {
    CGFloat width = kPillPadding + (_icon ? kIcon + (_title.length ? kIconGap : 0) : 0) + (_title.length ? TextWidth(_title) : 0) + (_caret ? kCaretGap + kIcon : 0) + kPillPadding;
    return MAX(32, width);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    // The active pill keeps its fill under the hover's lighten.
    DrawBox(bounds, _active ? SNColorContentHgl1 : SNColorCtrPry, _active ? SNColorContentHgl1 : SNColorWithAlpha(SNLegacyPrimaryForeground, 0.3));
    SNColorToken color = _active ? SNLegacyInvertedForeground : SNColorContentPry;
    CGFloat x = kPillPadding;
    if (!_title.length && !_caret && _icon) x = (NSWidth(bounds) - kIcon) / 2;
    if (_icon) {
        SNDrawIcon(_icon, kIcon, color, NSMakeRect(x, (NSHeight(bounds) - kIcon) / 2, kIcon, kIcon));
        x += kIcon + kIconGap;
    }
    if (_title.length) {
        CGFloat width = TextWidth(_title);
        SNDrawText(_title, ControlFont(), color, NSHeight(bounds), NSTextAlignmentLeft, 1, NSMakeRect(x, 0, width, NSHeight(bounds)));
        x += width;
    }
    if (_caret) SNDrawIcon(@"caret-down", kIcon, color, NSMakeRect(x + kCaretGap, (NSHeight(bounds) - kIcon) / 2, kIcon, kIcon));
}

@end

@implementation SNExplorerOption

+ (instancetype)optionWithTitle:(NSString *)title value:(NSString *)value {
    SNExplorerOption *option = [self new];
    option->_title = [title copy];
    option->_value = [value copy];
    return option;
}

@end

@implementation SNExplorerSelect

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _value = @"";
    // :hover paints foreground-low-solid over the fill.
    self.hoverColor = self.pressedColor = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.action = ^(SNExplorerSelect *select) { [select open]; };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setValue:(NSString *)value {
    _value = [value copy];
    self.needsDisplay = YES;
}

- (void)setOptions:(NSArray<SNExplorerOption *> *)options {
    _options = [options copy];
    self.needsDisplay = YES;
}

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (NSString *)label {
    for (SNExplorerOption *option in _options)
        if ([option.value isEqualToString:_value]) return option.title;
    return _options.firstObject.title ?: @"";
}

- (BOOL)active { return _defaultValue && ![_value isEqualToString:_defaultValue]; }

- (CGFloat)fittingWidth { return kSelectPadding + TextWidth(self.label) + kCaretGap + kSelectCaret + kSelectPadding; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    BOOL active = self.active, hovered = self.hovered || self.pressed;
    SNColorToken fill = active ? SNColorContentHgl1 : hovered ? SNLegacyForegroundLowSolid : SNColorCtrPry;
    DrawBox(bounds, fill, active ? SNColorContentHgl1 : SNColorOtlSec);
    if (active && hovered) {
        [SNColor(SNColorCtrPryHover) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1) xRadius:SNRadiusBase - 1 yRadius:SNRadiusBase - 1] fill];
    }
    SNColorToken color = active ? SNLegacyInvertedForeground : SNColorContentPry;
    NSString *label = self.label;
    CGFloat width = TextWidth(label);
    SNDrawText(label, ControlFont(), color, NSHeight(bounds), NSTextAlignmentLeft, 1, NSMakeRect(kSelectPadding, 0, width, NSHeight(bounds)));
    SNDrawIcon(@"caret-down", kSelectCaret, color, NSMakeRect(kSelectPadding + width + kCaretGap, (NSHeight(bounds) - kSelectCaret) / 2, kSelectCaret, kSelectCaret));
}

- (void)open {
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    __weak SNExplorerSelect *weakSelf = self;
    for (SNExplorerOption *option in _options) {
        NSString *value = option.value;
        SNMenuItem *item = [SNMenuItem itemWithTitle:option.title action:^{
            SNExplorerSelect *select = weakSelf;
            if (!select || [select.value isEqualToString:value]) return;
            select.value = value;
            if (select.changed) select.changed(value);
        }];
        item.checked = [value isEqualToString:_value];
        [items addObject:item];
    }
    [[[SNMenu alloc] initWithItems:items width:kMenuWidth] showForRect:self.bounds inView:self placement:SNPlacementBelow];
}

@end

@implementation SNExplorerSegments {
    NSMutableArray<SNExplorerPill *> *_pills;
}

- (BOOL)isFlipped { return YES; }

- (void)setOptions:(NSArray<SNExplorerOption *> *)options {
    _options = [options copy];
    for (NSView *pill in _pills) [pill removeFromSuperview];
    _pills = [NSMutableArray new];
    __weak SNExplorerSegments *weakSelf = self;
    for (SNExplorerOption *option in options) {
        SNExplorerPill *pill = [[SNExplorerPill alloc] initWithTitle:option.title];
        NSString *value = option.value;
        pill.action = ^(SNExplorerPill *clicked) {
            SNExplorerSegments *segments = weakSelf;
            if (!segments || [segments.value isEqualToString:value]) return;
            segments.value = value;
            if (segments.changed) segments.changed(value);
        };
        [_pills addObject:pill];
        [self addSubview:pill];
    }
    [self setValue:_value];
    self.needsLayout = YES;
}

- (NSArray<SNExplorerPill *> *)pills { return _pills ?: @[]; }

- (void)setValue:(NSString *)value {
    _value = [value copy];
    for (NSUInteger i = 0; i < _pills.count; i++) _pills[i].active = [_options[i].value isEqualToString:value];
}

- (CGFloat)fittingWidth {
    CGFloat width = 0;
    for (SNExplorerPill *pill in _pills) width += pill.fittingWidth + (width ? kSegmentGap : 0);
    return width;
}

- (void)layout {
    [super layout];
    CGFloat x = 0;
    for (SNExplorerPill *pill in _pills) {
        pill.frame = NSMakeRect(x, 0, pill.fittingWidth, SNExplorerControlHeight);
        x += pill.fittingWidth + kSegmentGap;
    }
}

@end

@implementation SNExplorerSection {
    NSString *_title;
}

- (instancetype)initWithTitle:(NSString *)title action:(NSString *)action {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 16 + 22 + 8)])) return nil;
    _title = [title copy];
    if (action) {
        _button = [SNButton outlineButtonWithTitle:action];
        _button.font = ControlFont();
        _button.borderColor = 0;
        [self addSubview:_button];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    CGFloat width = ceil(_button.fittingContentSize.width) + 16;
    _button.frame = NSMakeRect(NSWidth(self.bounds) - width, 16 + (22 - 28) / 2.0, width, 28);
}

- (void)drawRect:(NSRect)dirtyRect {
    SNDrawText(_title, ControlFont(), SNColorContentSec, 22, NSTextAlignmentLeft, 1, NSMakeRect(0, 16, NSWidth(self.bounds) - 100, 22));
}

@end

@implementation SNExplorerEmptyState {
    SNLabel *_title, *_description;
}

- (instancetype)initWithTitle:(NSString *)title description:(NSString *)description action:(NSString *)action {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 600, 200)])) return nil;
    _title = [SNLabel labelWithText:title font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNColorContentPry];
    _title.lineHeight = 22.5;
    _title.maximumLines = 0;
    _title.alignment = NSTextAlignmentCenter;
    [self addSubview:_title];
    if (description.length) {
        _description = [SNLabel labelWithText:description font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNLegacyPrimaryForeground];
        _description.lineHeight = 22;
        _description.maximumLines = 0;
        _description.alignment = NSTextAlignmentCenter;
        [self addSubview:_description];
    }
    if (action) {
        _button = [SNButton outlineButtonWithTitle:action];
        [self addSubview:_button];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

/// The block's own height at the view's width (the view itself is at least 200).
- (CGFloat)blockHeightForWidth:(CGFloat)width {
    CGFloat height = [_title heightForWidth:width] + 8;
    if (_description) height += [_description heightForWidth:width] + 8;
    if (_button) height += 8 + 36 + 8;
    return height;
}

- (CGFloat)preferredHeight { return MAX(200, [self blockHeightForWidth:MIN(380, NSWidth(self.bounds))] + 32); }

- (void)layout {
    [super layout];
    CGFloat width = MIN(380, NSWidth(self.bounds)), x = round((NSWidth(self.bounds) - width) / 2);
    CGFloat y = round((NSHeight(self.bounds) - [self blockHeightForWidth:width]) / 2);
    CGFloat title = [_title heightForWidth:width];
    _title.frame = NSMakeRect(x, y, width, title);
    y += title + 8;
    if (_description) {
        CGFloat height = [_description heightForWidth:width];
        _description.frame = NSMakeRect(x, y, width, height);
        y += height + 8;
    }
    if (_button) {
        CGFloat buttonWidth = MAX(80, ceil(_button.fittingContentSize.width) + 32);
        _button.frame = NSMakeRect(round((NSWidth(self.bounds) - buttonWidth) / 2), y + 8, buttonWidth, 36);
    }
}

@end

SNButton *SNExplorerLoadMoreButton(void) {
    SNButton *button = [SNButton outlineButtonWithTitle:SNLocalized(@"files.loadMore")];
    return button;
}

/// MoreResultsByType's categoryCard: 42 pt, radius 12, ctr-pry with an otl-ter border (surf-pry
/// under the pointer), 12 pt in: the 16 pt icon 8 pt before the 13 pt bold label, a caret at the
/// right.
@interface SNExplorerCard : SNHoverView
@property (nonatomic, copy) NSString *title, *icon;
@end

@implementation SNExplorerCard

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:SNRadiusXlarge - 0.5 yRadius:SNRadiusXlarge - 0.5];
    [SNColor(SNColorCtrPry) setFill];
    [card fill];
    if (self.hovered || self.pressed) {
        [SNColor(SNColorSurfPry) setFill];
        [card fill];
    }
    [SNColor(SNColorOtlTer) setStroke];
    [card stroke];
    CGFloat middle = NSHeight(bounds) / 2;
    SNDrawIcon(_icon, 16, SNColorContentPry, NSMakeRect(12, middle - 8, 16, 16));
    SNDrawText(_title, ControlFont(), SNColorContentPry, NSHeight(bounds), NSTextAlignmentLeft, 1, NSMakeRect(36, 0, MAX(0, NSWidth(bounds) - 36 - 36), NSHeight(bounds)));
    SNDrawIcon(@"caret-right", 16, SNColorContentPry, NSMakeRect(NSWidth(bounds) - 12 - 16, middle - 8, 16, 16));
}

@end

@implementation SNExplorerMoreByType {
    NSMutableArray<SNHoverView *> *_cards;
}

static const CGFloat kHeadingTop = 36, kHeadingLine = 22, kHeadingGap = 20, kCard = 42, kCardGap = 12, kGridBottom = 32;

- (instancetype)initWithKinds:(NSArray<NSArray<NSString *> *> *)kinds chosen:(void (^)(NSString *))chosen {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 600, 100)])) return nil;
    _cards = [NSMutableArray new];
    for (NSArray<NSString *> *kind in kinds) {
        SNExplorerCard *card = [[SNExplorerCard alloc] initWithFrame:NSZeroRect];
        card.title = kind[0];
        card.icon = kind[1];
        NSString *value = kind[2];
        card.action = ^(SNExplorerCard *clicked) { chosen(value); };
        [_cards addObject:card];
        [self addSubview:card];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSArray<SNHoverView *> *)cards { return _cards; }

- (CGFloat)preferredHeight { return kHeadingTop + kHeadingLine + kHeadingGap + _cards.count * kCard + (_cards.count ? _cards.count - 1 : 0) * kCardGap + kGridBottom; }

- (void)layout {
    [super layout];
    CGFloat y = kHeadingTop + kHeadingLine + kHeadingGap;
    for (SNHoverView *card in _cards) {
        card.frame = NSMakeRect(0, y, NSWidth(self.bounds), kCard);
        y += kCard + kCardGap;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    SNDrawText(SNLocalized(@"files.tab.more"), SNFont(SNFontSizeBase, SNFontWeightBold), SNColorContentPry, kHeadingLine, NSTextAlignmentLeft, 1,
               NSMakeRect(0, kHeadingTop, NSWidth(self.bounds), kHeadingLine));
}

@end
