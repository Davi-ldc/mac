// Owns the Preferences dialog: its frame, section list, the options of each section, the controls
// they use (Slack's checkbox, radio, select and text input) and where each option is saved.
#import <ServiceManagement/ServiceManagement.h>

#import "model/timezone.h"
#import "render/document.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/kit/button.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/overlay.h"
#import "ui/kit/popover.h"
#import "ui/prefs/prefs.h"
#import "ui/prefs/vips.h"
#import "ui/shell/actions.h"

__asm__(".linker_option \"-framework\", \"ServiceManagement\"");

/// c-sk-modal: up to 800 x 700, radius 8; the title bar 20/28 padding around the 36 pt line of a
/// 22 pt black title, the 36 pt close button 20 pt from the top right; a 1 pt otl-ter line under it.
static const CGFloat kWidth = 800, kHeight = 700, kMargin = 40, kSide = 28, kTitleTop = 20, kTitleLine = 36, kClose = 36, kCloseInset = 20;
static const CGFloat kHeader = kTitleTop + kTitleLine + 20;
/// The vertical tabs: 205 wide, 16 pt above and below, 16 pt in; 15/1.25 items with 4/8 padding,
/// radius 4, 4 pt apart, a 20 pt icon 8 pt before the label.
static const CGFloat kNav = 205, kNavInset = 16, kTab = 26.75, kTabGap = 4, kTabPadding = 8, kTabIcon = 20;
/// The panel: 20/28 padding.
static const CGFloat kPanelTop = 20;
/// Text: h2 18 bold, legends 15 bold, labels 15; inline controls 14 pt with 8 pt after them.
static const CGFloat kLine = 22.5, kHeadingLine = 22.5, kBox = 14, kBoxGap = 8, kRowGap = 4, kGroupGap = 24, kSelect = 36;
static const SNColorToken kTabActive = SNColorBaseInvHgl1, kRule = SNColorOtlTer;
static const unsigned short kEscape = 53;

#pragma mark Options

typedef NS_ENUM(NSInteger, SNPrefsRowKind) {
    SNPrefsRowHeading,
    SNPrefsRowLegend,
    SNPrefsRowSubtext,
    SNPrefsRowText,
    SNPrefsRowCheck,
    SNPrefsRowRadio,
    SNPrefsRowSelect,
    SNPrefsRowField,
    SNPrefsRowRule,
    /// A view of its own, last in its section: makeView's, as tall as it says.
    SNPrefsRowView,
};

/// One line of a section: text, or a control with its state and what changing it does.
@interface SNPrefsRow : NSObject
@property (nonatomic) SNPrefsRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *hint, *value;
@property (nonatomic) BOOL on, disabled;
@property (nonatomic) CGFloat indent, width;
/// A select's choices: @[title, value] pairs.
@property (nonatomic, copy, nullable) NSArray<NSArray<NSString *> *> *choices;
/// A check gets @YES/@NO, a radio nil, a select or field the new value.
@property (nonatomic, copy, nullable) void (^changed)(id _Nullable value);
@property (nonatomic, copy, nullable) SNPrefsVIPList * (^makeView)(void);
@end

@implementation SNPrefsRow
@end

static SNPrefsRow *Row(SNPrefsRowKind kind, NSString *title) {
    SNPrefsRow *row = [SNPrefsRow new];
    row.kind = kind;
    row.title = title;
    return row;
}

static NSString *L(NSString *key) { return SNLocalized([@"prefs." stringByAppendingString:key]); }

#pragma mark Controls

/// Slack's c-input_checkbox and c-input_radio beside their c-label: a 14 pt box (radius 4) or
/// circle with a 1.5 pt otl-sec ring on base-pry, otl-pry under the pointer; checked, the box fills
/// base-inv-hgl-1 under a 10 pt content-inv-pry tick, the circle takes the ring and a dot.
@interface SNPrefsToggle : SNHoverView
@property (nonatomic) SNPrefsRow *row;
@end

@implementation SNPrefsToggle

- (instancetype)initWithRow:(SNPrefsRow *)row {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _row = row;
    self.hoverColor = self.pressedColor = 0;
    self.enabled = !row.disabled;
    __weak SNPrefsToggle *weakSelf = self;
    self.action = ^(SNPrefsToggle *toggle) { [weakSelf toggle]; };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)toggle {
    SNPrefsRow *row = self.row;
    if (row.kind == SNPrefsRowRadio && row.on) return;
    row.on = row.kind == SNPrefsRowRadio ? YES : !row.on;
    self.needsDisplay = YES;
    if (row.changed) row.changed(row.kind == SNPrefsRowCheck ? @(row.on) : nil);
}

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    SNPrefsRow *row = self.row;
    NSRect box = NSMakeRect(0.75, (kLine - kBox) / 2 + 0.75, kBox - 1.5, kBox - 1.5);
    BOOL radio = row.kind == SNPrefsRowRadio;
    NSBezierPath *outline = radio ? [NSBezierPath bezierPathWithOvalInRect:box] : [NSBezierPath bezierPathWithRoundedRect:box xRadius:3.25 yRadius:3.25];
    outline.lineWidth = 1.5;
    CGFloat alpha = row.disabled ? 0.38 : 1;
    if (row.on && !radio) {
        [[SNColor(SNColorBaseInvHgl1) colorWithAlphaComponent:alpha] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, -0.75, -0.75) xRadius:4 yRadius:4] fill];
        // The 10 pt mask path M2 5.5 L4 7.5 L8 2.5, centred.
        NSPoint origin = NSMakePoint(NSMidX(box) - 5, NSMidY(box) - 5);
        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:NSMakePoint(origin.x + 2, origin.y + 5.5)];
        [tick lineToPoint:NSMakePoint(origin.x + 4, origin.y + 7.5)];
        [tick lineToPoint:NSMakePoint(origin.x + 8, origin.y + 2.5)];
        tick.lineWidth = 1.5;
        tick.lineCapStyle = NSLineCapStyleRound;
        tick.lineJoinStyle = NSLineJoinStyleRound;
        [[SNColor(SNColorContentInvPry) colorWithAlphaComponent:alpha] setStroke];
        [tick stroke];
    } else {
        [SNColor(SNColorBasePry) setFill];
        [outline fill];
        SNColorToken ring = row.on ? SNColorBaseInvHgl1 : self.hovered ? SNColorOtlPry : SNColorOtlSec;
        [[SNColor(ring) colorWithAlphaComponent:alpha * SNColor(ring).alphaComponent] setStroke];
        [outline stroke];
        if (row.on) {
            [SNColor(SNColorBaseInvHgl1) setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(box, 3.5, 3.5)] fill];
        }
    }
    CGFloat x = kBox + kBoxGap, width = NSWidth(self.bounds) - x;
    SNDrawText(row.title, SNFont(SNFontSizeBase, SNFontWeightRegular), row.disabled ? SNColorContentTer : SNColorContentPry, kLine, NSTextAlignmentLeft, 0,
               NSMakeRect(x, 0, width, NSHeight(self.bounds)));
    if (row.hint.length) {
        CGFloat top = SNLineCount(row.title, SNFont(SNFontSizeBase, SNFontWeightRegular), width, 0) * kLine;
        SNDrawText(row.hint, SNFont(SNFontSizeCaption, SNFontWeightRegular), SNColorContentTer, 18, NSTextAlignmentLeft, 0, NSMakeRect(x, top, width, NSHeight(self.bounds) - top));
    }
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat text = width - kBox - kBoxGap;
    CGFloat height = SNLineCount(self.row.title, SNFont(SNFontSizeBase, SNFontWeightRegular), text, 0) * kLine;
    if (self.row.hint.length) height += SNLineCount(self.row.hint, SNFont(SNFontSizeCaption, SNFontWeightRegular), text, 0) * 18;
    return height;
}

@end

/// c-select's options list: at most 240 pt tall (its maxListHeight), scrolled to the choice; the
/// arrow keys keep the highlighted row in view.
@interface SNPrefsSelectMenu : SNMenu
@end

@implementation SNPrefsSelectMenu

/// SNMenu's rows: 28 pt under 12 pt of padding (components.json menu).
- (NSRect)rectOfRow:(NSUInteger)index { return NSMakeRect(0, 12 + index * 28, NSWidth(self.bounds), 28); }

- (void)keyDown:(NSEvent *)event {
    [super keyDown:event];
    if (self.highlightedIndex != NSNotFound) [self scrollRectToVisible:[self rectOfRow:self.highlightedIndex]];
}

@end

static const CGFloat kListHeight = 240;

/// c-select_button (medium): 36 pt, radius 8, a 1 pt otl-pry border on base-pry, the choice in 15
/// pt 12 pt in and the caret at the right; it opens a menu of the choices under it. Disabled, it
/// shows its choice dimmed and does not open.
@interface SNPrefsSelect : SNHoverView
@property (nonatomic) SNPrefsRow *row;
@end

@implementation SNPrefsSelect

- (instancetype)initWithRow:(SNPrefsRow *)row {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _row = row;
    self.overlayRadius = SNRadiusLarge;
    self.enabled = !row.disabled;
    __weak SNPrefsSelect *weakSelf = self;
    self.action = ^(SNPrefsSelect *select) { [weakSelf open]; };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSString *)choiceTitle {
    for (NSArray<NSString *> *choice in self.row.choices)
        if ([choice[1] isEqualToString:self.row.value ?: @""]) return choice[0];
    return self.row.choices.firstObject[0] ?: @"";
}

- (void)choose:(NSString *)value {
    self.row.value = value;
    self.needsDisplay = YES;
    if (self.row.changed) self.row.changed(value);
}

- (void)open {
    NSMutableArray *items = [NSMutableArray new];
    __weak SNPrefsSelect *weakSelf = self;
    NSUInteger chosen = NSNotFound;
    for (NSArray<NSString *> *choice in self.row.choices) {
        NSString *value = choice[1];
        SNMenuItem *item = [SNMenuItem itemWithTitle:choice[0] action:^{ [weakSelf choose:value]; }];
        item.checked = [value isEqualToString:self.row.value ?: @""];
        if (item.checked) chosen = items.count;
        [items addObject:item];
    }
    SNPrefsSelectMenu *menu = [[SNPrefsSelectMenu alloc] initWithItems:items width:NSWidth(self.bounds)];
    if (NSHeight(menu.frame) <= kListHeight) {
        [menu showForRect:self.bounds inView:self placement:SNPlacementBelow];
        return;
    }
    SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNColorCtrPry radius:SNRadiusMenuLive shadow:SNMenuShadow];
    panel.frame = NSMakeRect(0, 0, NSWidth(menu.frame), kListHeight);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:panel.contentView.bounds];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.documentView = menu;
    [panel.contentView addSubview:scroll];
    if (chosen != NSNotFound) {
        NSRect row = [menu rectOfRow:chosen];
        CGFloat top = MIN(MAX(0, NSMidY(row) - NSHeight(scroll.contentView.bounds) / 2), NSHeight(menu.frame) - NSHeight(scroll.contentView.bounds));
        [scroll.contentView scrollToPoint:NSMakePoint(0, top)];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
    [SNPopover showContent:panel forRect:self.bounds inView:self placement:SNPlacementBelow gap:4];
    [self.window makeFirstResponder:menu];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusLarge yRadius:SNRadiusLarge];
    [SNColor(SNColorBasePry) setFill];
    [path fill];
    [[SNColor(SNColorOtlPry) colorWithAlphaComponent:(self.row.disabled ? 0.38 : 1) * SNColor(SNColorOtlPry).alphaComponent] setStroke];
    [path stroke];
    SNColorToken color = self.row.disabled ? SNColorContentTer : SNColorContentPry;
    SNDrawText(self.choiceTitle, SNFont(SNFontSizeBase, SNFontWeightRegular), color, kSelect, NSTextAlignmentLeft, 1,
               NSMakeRect(12, 0, NSWidth(self.bounds) - 12 - 32, kSelect));
    SNDrawIcon(@"caret-down", 16, color, NSMakeRect(NSWidth(self.bounds) - 12 - 16, (kSelect - 16) / 2, 16, 16));
}

@end

/// c-input_text: 36 pt, radius 8, a 1 pt otl-pry border, 15 pt text 12 pt in. Changes save a
/// second after the last keystroke, as Slack's keyword field does.
@interface SNPrefsField : NSView <NSTextFieldDelegate>
@property (nonatomic) SNPrefsRow *row;
@property (nonatomic, readonly) NSTextField *field;
@end

@implementation SNPrefsField

- (instancetype)initWithRow:(SNPrefsRow *)row {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _row = row;
    _field = [NSTextField textFieldWithString:row.value ?: @""];
    _field.bordered = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    _field.textColor = SNColor(SNColorContentPry);
    _field.delegate = self;
    [self addSubview:_field];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    CGFloat height = ceil(_field.intrinsicContentSize.height);
    _field.frame = NSMakeRect(12, (kSelect - height) / 2, NSWidth(self.bounds) - 24, height);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.5, 0.5, NSWidth(self.bounds) - 1, kSelect - 1) xRadius:SNRadiusLarge yRadius:SNRadiusLarge];
    [SNColor(SNColorBasePry) setFill];
    [path fill];
    [SNColor(SNColorOtlPry) setStroke];
    [path stroke];
    if (self.row.hint.length)
        SNDrawText(self.row.hint, SNFont(SNFontSizeCaption, SNFontWeightRegular), SNColorContentTer, 18, NSTextAlignmentLeft, 0,
                   NSMakeRect(0, kSelect + 4, NSWidth(self.bounds), NSHeight(self.bounds) - kSelect - 4));
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(save) object:nil];
    [self performSelector:@selector(save) withObject:nil afterDelay:1 inModes:@[ NSRunLoopCommonModes ]];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification { [self save]; }

- (void)save {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(save) object:nil];
    NSString *value = _field.stringValue;
    if ([value isEqualToString:self.row.value ?: @""]) return;
    self.row.value = value;
    if (self.row.changed) self.row.changed(value);
}

- (void)viewWillMoveToWindow:(NSWindow *)window {
    if (!window) [self save];
    [super viewWillMoveToWindow:window];
}

@end

#pragma mark Section list

@interface SNPrefsTab : SNHoverView
@property (nonatomic, copy) NSString *title, *icon;
@property (nonatomic) BOOL current;
@end

@implementation SNPrefsTab

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overlayRadius = 4;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setCurrent:(BOOL)current {
    _current = current;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.current) {
        [SNColor(kTabActive) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4] fill];
    }
    // Inactive icons are foreground_max at 70%.
    SNDrawIcon(self.icon, kTabIcon, self.current ? SNColorContentInvPry : (SNColorContentPry & 0xffffff00) | 0xb3, NSMakeRect(kTabPadding, (kTab - kTabIcon) / 2, kTabIcon, kTabIcon));
    SNDrawText(self.title, SNFont(SNFontSizeBase, SNFontWeightRegular), self.current ? SNColorContentInvPry : SNColorContentPry, kTab, NSTextAlignmentLeft, 1,
               NSMakeRect(kTabPadding + kTabIcon + 8, 0, NSWidth(self.bounds) - kTabPadding * 2 - kTabIcon - 8, kTab));
}

@end

#pragma mark Dialog

@interface SNPrefsBackdrop : NSView
@property (nonatomic, copy) void (^clicked)(void);
@end

@implementation SNPrefsBackdrop
- (BOOL)isFlipped { return YES; }
- (void)mouseDown:(NSEvent *)event { self.clicked(); }
@end

@interface SNPrefsFlippedView : NSView
@end

@implementation SNPrefsFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface SNPreferencesDialog () <SNChangeObserver>
@end

@implementation SNPreferencesDialog {
    id<SNSource> _source;
    SNPrefsBackdrop *_backdrop;
    SNPanelView *_panel;
    NSView *_content;
    NSArray<SNPrefsTab *> *_tabs;
    NSScrollView *_scroll;
    SNPrefsFlippedView *_document;
    NSArray<SNPrefsRow *> *_rows;
    NSArray<NSView *> *_controls;
    id _monitor;
}

static SNPreferencesDialog *current;

+ (SNPreferencesDialog *)current { return current; }

+ (instancetype)showInWindow:(NSWindow *)window source:(id<SNSource>)source section:(SNPrefsSection)section {
    [current close];
    SNPreferencesDialog *dialog = [self new];
    dialog->_source = source;
    dialog->_section = section;
    [dialog buildInHost:[SNOverlayHost hostForWindow:window]];
    current = dialog;
    return dialog;
}

- (NSView *)panel { return _panel; }

/// The sections this client honours, in Slack's order, with Slack's icons; VIP where the plan
/// offers VIPs.
static NSArray<NSArray *> *Sections(id<SNSource> source) {
    NSArray *vip = source.offersVIPs ? @[ @[ @(SNPrefsVIP), @"vip", @"vip" ] ] : @[];
    return [@[ @[ @(SNPrefsNotifications), @"notifications", @"notifications" ] ] arrayByAddingObjectsFromArray:[vip arrayByAddingObjectsFromArray:@[
        @[ @(SNPrefsHome), @"home", @"home" ],
        @[ @(SNPrefsMessages), @"messages", @"threads" ], @[ @(SNPrefsLanguage), @"language", @"globe" ],
        @[ @(SNPrefsAccessibility), @"accessibility", @"laptop" ], @[ @(SNPrefsMarkAsRead), @"read", @"check-circle" ],
        @[ @(SNPrefsAdvanced), @"advanced", @"settings" ]
    ]]];
}

- (NSArray<NSNumber *> *)sections {
    NSMutableArray *sections = [NSMutableArray new];
    for (NSArray *section in Sections(_source)) [sections addObject:section[0]];
    return sections;
}

- (void)buildInHost:(NSView *)host {
    __weak SNPreferencesDialog *weakSelf = self;
    _backdrop = [[SNPrefsBackdrop alloc] initWithFrame:host.bounds];
    _backdrop.wantsLayer = YES;
    _backdrop.layer.backgroundColor = SNCGColor(SNColorBaseModal);
    _backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _backdrop.clicked = ^{ [weakSelf close]; };
    [host addSubview:_backdrop];

    CGFloat width = MIN(kWidth, NSWidth(host.bounds) - 2 * kMargin), height = MIN(kHeight, NSHeight(host.bounds) - 2 * kMargin);
    SNShadowStack shadow = {2, {{0, 0, 0, 1, 0xe8e8e821, NO}, {0, 18, 48, 0, 0x00000059, NO}}};
    _panel = [[SNPanelView alloc] initWithFill:SNColorBasePry radius:SNRadiusLarge shadow:shadow];
    _panel.frame = NSMakeRect(round((NSWidth(host.bounds) - width) / 2), round((NSHeight(host.bounds) - height) / 2), width, height);
    _panel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    _content = [[SNPrefsFlippedView alloc] initWithFrame:_panel.contentView.bounds];
    _content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_panel.contentView addSubview:_content];

    SNLabel *title = [SNLabel labelWithText:L(@"title") font:SNFont(SNFontSizeTitle, SNFontWeightBlack) color:SNColorContentPry];
    title.lineHeight = kTitleLine;
    title.frame = NSMakeRect(kSide, kTitleTop, width - 2 * kSide - kClose, kTitleLine);
    SNButton *close = [SNButton iconButtonNamed:@"close" size:kClose iconSize:20];
    close.hoverColor = SNOverlayHover;
    close.tooltip = L(@"close");
    close.frame = NSMakeRect(width - kCloseInset - kClose, kTitleTop, kClose, kClose);
    close.action = ^(SNButton *button) { [weakSelf close]; };
    NSView *rule = [[NSView alloc] initWithFrame:NSMakeRect(0, kHeader, width, 1)];
    rule.wantsLayer = YES;
    rule.layer.backgroundColor = SNCGColor(kRule);
    for (NSView *view in @[ title, close, rule ]) [_content addSubview:view];

    NSMutableArray *tabs = [NSMutableArray new];
    CGFloat y = kHeader + 1 + kNavInset;
    for (NSArray *section in Sections(_source)) {
        SNPrefsTab *tab = [[SNPrefsTab alloc] initWithFrame:NSMakeRect(kNavInset, y, kNav - kNavInset, kTab)];
        tab.title = L([NSString stringWithFormat:@"section.%@", section[1]]);
        tab.icon = section[2];
        SNPrefsSection value = (SNPrefsSection)[section[0] integerValue];
        tab.action = ^(SNPrefsTab *chosen) { weakSelf.section = value; };
        [tabs addObject:tab];
        [_content addSubview:tab];
        y += kTab + kTabGap;
    }
    _tabs = tabs;
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(kNav, kHeader + 1, width - kNav, height - kHeader - 1)];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _document = [[SNPrefsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(_scroll.frame), 0)];
    _scroll.documentView = _document;
    [_content addSubview:_scroll];
    [host addSubview:_panel];
    // Typing goes nowhere behind the dialog, as behind Slack's modal.
    [host.window makeFirstResponder:nil];
    self.section = _section;

    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode != kEscape || SNPopover.current) return event;
        [weakSelf close];
        return nil;
    }];
    [_source addChangeObserver:self];
}

- (void)close {
    if (!_panel.superview) return;
    if (current == self) current = nil;
    [SNPopover.current close];
    [NSEvent removeMonitor:_monitor];
    _monitor = nil;
    [_panel.window makeFirstResponder:nil];
    [_backdrop removeFromSuperview];
    [_panel removeFromSuperview];
}

- (void)setSection:(SNPrefsSection)section {
    BOOL moved = section != _section;
    _section = section;
    NSArray *sections = Sections(_source);
    for (NSUInteger i = 0; i < _tabs.count; i++) _tabs[i].current = [sections[i][0] integerValue] == section;
    [self showRows];
    if (moved) [_scroll.documentView scrollPoint:NSZeroPoint];
}

// A change from elsewhere (pref_change, the store's own revert) shows at once; the field being
// typed in keeps its text.
- (void)sourceChanged:(SNChange *)change {
    if (!change.preferences || !_panel.superview) return;
    NSResponder *responder = _panel.window.firstResponder;
    if ([responder isKindOfClass:NSTextView.class] && [(NSView *)responder isDescendantOf:_document]) return;
    [self showRows];
}

#pragma mark Laying out

- (void)showRows {
    _customView = nil;
    _rows = [self rowsForSection:_section];
    for (NSView *view in _document.subviews.copy) [view removeFromSuperview];
    CGFloat width = NSWidth(_scroll.frame) - 2 * kSide, y = kPanelTop;
    NSMutableArray *controls = [NSMutableArray new];
    for (SNPrefsRow *row in _rows) {
        CGFloat x = kSide + row.indent, rowWidth = width - row.indent;
        NSView *view = nil;
        CGFloat height = 0, after = 0;
        switch (row.kind) {
        case SNPrefsRowHeading:
        case SNPrefsRowLegend:
        case SNPrefsRowSubtext:
        case SNPrefsRowText: {
            BOOL heading = row.kind == SNPrefsRowHeading, legend = row.kind == SNPrefsRowLegend;
            SNLabel *label = [SNLabel labelWithText:row.title
                                               font:SNFont(heading ? SNFontSizeSubtitle : SNFontSizeBase, heading || legend ? SNFontWeightBold : SNFontWeightRegular)
                                              color:row.kind == SNPrefsRowSubtext ? SNColorContentSec : SNColorContentPry];
            label.lineHeight = heading ? kHeadingLine : legend ? 22 : kLine;
            label.maximumLines = 0;
            height = [label heightForWidth:rowWidth];
            after = heading ? 8 : legend ? 4 : row.kind == SNPrefsRowSubtext ? 8 : 16;
            view = label;
            break;
        }
        case SNPrefsRowCheck:
        case SNPrefsRowRadio: {
            SNPrefsToggle *toggle = [[SNPrefsToggle alloc] initWithRow:row];
            height = [toggle heightForWidth:rowWidth];
            after = kRowGap;
            view = toggle;
            break;
        }
        case SNPrefsRowSelect: {
            view = [[SNPrefsSelect alloc] initWithRow:row];
            rowWidth = row.width ?: rowWidth;
            height = kSelect;
            after = 16;
            break;
        }
        case SNPrefsRowField: {
            view = [[SNPrefsField alloc] initWithRow:row];
            height = kSelect + (row.hint.length ? 4 + SNLineCount(row.hint, SNFont(SNFontSizeCaption, SNFontWeightRegular), rowWidth, 0) * 18 : 0);
            after = 20;
            break;
        }
        case SNPrefsRowView: {
            SNPrefsVIPList *list = row.makeView();
            height = [list heightForWidth:rowWidth];
            // It grows and shrinks by itself; nothing comes after it.
            __weak SNPrefsVIPList *weakList = list;
            __weak NSView *document = _document;
            __weak NSScrollView *scroll = _scroll;
            list.heightChanged = ^{
                SNPrefsVIPList *shown = weakList;
                NSRect frame = shown.frame;
                frame.size.height = [shown heightForWidth:NSWidth(frame)];
                shown.frame = frame;
                document.frame = NSMakeRect(0, 0, NSWidth(document.frame), MAX(NSMaxY(frame) + 20, NSHeight(scroll.contentView.bounds)));
            };
            view = list;
            _customView = list;
            break;
        }
        case SNPrefsRowRule: {
            // hr: 20 pt above and below; the gap a group leaves is folded into it.
            y += 20 - (y > kPanelTop ? kGroupGap - 16 : 0);
            view = [[NSView alloc] initWithFrame:NSZeroRect];
            view.wantsLayer = YES;
            view.layer.backgroundColor = SNCGColor(kRule);
            height = 1;
            after = 20;
            break;
        }
        }
        view.frame = NSMakeRect(x, y, rowWidth, height);
        [_document addSubview:view];
        [controls addObject:view];
        y += height + after;
    }
    _controls = controls;
    _document.frame = NSMakeRect(0, 0, NSWidth(_scroll.frame), MAX(y + 20, NSHeight(_scroll.contentView.bounds)));
}

#pragma mark Sections

- (NSArray<SNPrefsRow *> *)rowsForSection:(SNPrefsSection)section {
    switch (section) {
    case SNPrefsNotifications: return [self notificationRows];
    case SNPrefsVIP: return [self vipRows];
    case SNPrefsHome: return [self homeRows];
    case SNPrefsMessages: return [self messageRows];
    case SNPrefsLanguage: return [self languageRows];
    case SNPrefsAccessibility: return [self accessibilityRows];
    case SNPrefsMarkAsRead: return [self readRows];
    case SNPrefsAdvanced: return [self advancedRows];
    }
    return @[];
}

/// A check saved as a users.prefs boolean ("true"/"false"); `inverted` for Slack's "disable_…"
/// prefs shown as what they enable.
- (SNPrefsRow *)check:(NSString *)key pref:(NSString *)name fallback:(BOOL)fallback inverted:(BOOL)inverted {
    SNPrefsRow *row = Row(SNPrefsRowCheck, L(key));
    row.on = SNPreferenceBool(_source.preferences, name, fallback) != inverted;
    id<SNSource> source = _source;
    row.changed = ^(NSNumber *on) { [source setPreference:name value:on.boolValue != inverted ? @"true" : @"false"]; };
    return row;
}

/// A check saved in all_notifications_prefs' global (users.prefs.setNotifications).
- (SNPrefsRow *)notificationCheck:(NSString *)key pref:(NSString *)name fallback:(BOOL)fallback inverted:(BOOL)inverted reason:(NSString *)reason {
    SNPrefsRow *row = Row(SNPrefsRowCheck, L(key));
    id value = SNNotificationPreference(_source.preferences, name);
    row.on = (value ? [value boolValue] : fallback) != inverted;
    id<SNSource> source = _source;
    row.changed = ^(NSNumber *on) { [source setNotificationPreferences:@{name : on.boolValue != inverted ? @"true" : @"false"} reason:reason]; };
    return row;
}

/// A radio of a group saved as one users.prefs value.
- (SNPrefsRow *)radio:(NSString *)key pref:(NSString *)name value:(NSString *)value current:(NSString *)current {
    SNPrefsRow *row = Row(SNPrefsRowRadio, L(key));
    row.on = [value isEqualToString:current];
    id<SNSource> source = _source;
    row.changed = ^(id unused) { [source setPreference:name value:value]; };
    return row;
}

- (NSArray<SNPrefsRow *> *)notificationRows {
    NSDictionary *prefs = _source.preferences;
    id<SNSource> source = _source;
    NSMutableArray *rows = [NSMutableArray new];
    [rows addObject:Row(SNPrefsRowHeading, L(@"notify.defaults"))];
    [rows addObject:Row(SNPrefsRowSubtext, L(@"notify.defaults.text"))];
    [rows addObject:Row(SNPrefsRowLegend, L(@"notify.how"))];
    [rows addObject:Row(SNPrefsRowSubtext, L(@"notify.how.text"))];
    [rows addObject:[self notificationCheck:@"notify.desktop" pref:@"global_desktop_push_enabled" fallback:YES inverted:NO reason:@"NotificationsGlobalPrefCheckbox"]];
    [rows addObject:Row(SNPrefsRowLegend, L(@"notify.what"))];
    // "mention" is the value older accounts keep for "Mentions and direct messages".
    id level = SNNotificationPreference(prefs, @"global_desktop");
    SNPrefsRow *what = Row(SNPrefsRowSelect, L(@"notify.what"));
    what.width = 300;
    what.choices = @[ @[ L(@"notify.everything"), @"everything" ], @[ L(@"notify.mentions"), @"mentions_dms" ] ];
    what.value = [level isEqual:@"everything"] ? @"everything" : @"mentions_dms";
    // Without mobile overrides the mobile level follows the desktop's.
    what.changed = ^(NSString *value) { [source setNotificationPreferences:@{@"global_desktop" : value, @"global_mobile" : value} reason:@"NotificationsChannelDefaults"]; };
    [rows addObject:what];
    [rows addObject:Row(SNPrefsRowLegend, L(@"notify.keywords"))];
    [rows addObject:Row(SNPrefsRowSubtext, L(@"notify.keywords.text"))];
    SNPrefsRow *keywords = Row(SNPrefsRowField, L(@"notify.keywords"));
    id words = SNNotificationPreference(prefs, @"global_keywords");
    keywords.value = [words isKindOfClass:NSString.class] ? words : @"";
    keywords.hint = L(@"notify.keywords.hint");
    keywords.changed = ^(NSString *value) {
        // Comma-separated, ", " collapsed to ",", as Slack keeps them.
        NSString *joined = [[value componentsSeparatedByString:@", "] componentsJoinedByString:@","];
        [source setNotificationPreferences:@{@"global_keywords" : joined} reason:@"NotificationsKeywordsInput"];
    };
    [rows addObject:keywords];
    // "Also notify you about:", of which this client honours the VIPs' (priority_dnd_override).
    [rows addObject:Row(SNPrefsRowLegend, L(@"notify.also"))];
    [rows addObject:[self check:@"notify.vips" pref:@"priority_dnd_override" fallback:NO inverted:NO]];
    [rows addObject:Row(SNPrefsRowRule, @"")];
    [rows addObject:Row(SNPrefsRowHeading, L(@"notify.sounds"))];
    [rows addObject:[self notificationCheck:@"notify.preview" pref:@"no_text_in_notifications" fallback:NO inverted:YES reason:@""]];
    [rows addObject:[self check:@"notify.mute" pref:@"mute_sounds" fallback:NO inverted:NO]];
    [rows addObject:[self check:@"notify.badge" pref:@"mac_ssb_bullet" fallback:YES inverted:NO]];
    // mac_ssb_bounce: "" off; "short" once, "long" until the app is active.
    NSString *bounce = SNPreferenceString(prefs, @"mac_ssb_bounce") ?: @"";
    SNPrefsRow *bounces = Row(SNPrefsRowCheck, L(@"notify.bounce"));
    bounces.on = bounce.length > 0;
    bounces.changed = ^(NSNumber *on) { [source setPreference:@"mac_ssb_bounce" value:on.boolValue ? @"long" : @""]; };
    [rows addObject:bounces];
    SNPrefsRow *once = Row(SNPrefsRowCheck, L(@"notify.bounce.once"));
    once.indent = 24;
    once.on = [bounce isEqualToString:@"short"];
    once.disabled = !bounce.length;
    once.changed = ^(NSNumber *on) { [source setPreference:@"mac_ssb_bounce" value:on.boolValue ? @"short" : @"long"]; };
    [rows addObject:once];
    return rows;
}

/// PrefsSectionVIP: "VIP Notifications" (priority_dnd_override), then the VIP list. Its sidebar
/// section and sound choices are left out: this client has neither.
- (NSArray<SNPrefsRow *> *)vipRows {
    SNPrefsRow *override = [self check:@"vip.override" pref:@"priority_dnd_override" fallback:NO inverted:NO];
    override.hint = L(@"vip.override.hint");
    SNPrefsRow *list = Row(SNPrefsRowView, L(@"vip.list"));
    id<SNSource> source = _source;
    list.makeView = ^SNPrefsVIPList * { return [[SNPrefsVIPList alloc] initWithSource:source]; };
    return @[ Row(SNPrefsRowLegend, L(@"vip.notifications")), override, Row(SNPrefsRowRule, @""), Row(SNPrefsRowLegend, L(@"vip.list")), Row(SNPrefsRowSubtext, L(@"vip.list.text")), list ];
}

- (NSArray<SNPrefsRow *> *)homeRows {
    NSString *behavior = SNPreferenceString(_source.preferences, @"sidebar_behavior") ?: @"";
    return @[
        Row(SNPrefsRowLegend, L(@"home.show")), [self radio:@"home.show.all" pref:@"sidebar_behavior" value:@"" current:behavior],
        [self radio:@"home.show.unreads" pref:@"sidebar_behavior" value:@"hide_read_channels" current:behavior],
        [self radio:@"home.show.mentions" pref:@"sidebar_behavior" value:@"show_mentions_only" current:behavior],
        [self radio:@"home.show.starred" pref:@"sidebar_behavior" value:@"hide_read_channels_unless_starred" current:behavior]
    ];
}

- (NSArray<SNPrefsRow *> *)messageRows {
    NSDictionary *prefs = _source.preferences;
    id<SNSource> source = _source;
    NSMutableArray *rows = [NSMutableArray new];
    // display_real_names_override against the workspace's display_real_names: with it on, full
    // names are 0 (its default) and display names -1; with it off, 1 and 0.
    BOOL workspace = [[_source.workspace.json[@"prefs"] valueForKey:@"display_real_names"] boolValue];
    NSInteger override = SNPreferenceString(prefs, @"display_real_names_override").integerValue;
    BOOL full = override == 1 || (override == 0 && workspace);
    NSString *fullValue = workspace ? @"0" : @"1", *displayValue = workspace ? @"-1" : @"0";
    [rows addObject:Row(SNPrefsRowLegend, L(@"messages.names"))];
    SNPrefsRow *fullNames = Row(SNPrefsRowRadio, L(@"messages.names.full"));
    fullNames.on = full;
    fullNames.changed = ^(id unused) { [source setPreference:@"display_real_names_override" value:fullValue]; };
    SNPrefsRow *displayNames = Row(SNPrefsRowRadio, L(@"messages.names.display"));
    displayNames.on = !full;
    displayNames.changed = ^(id unused) { [source setPreference:@"display_real_names_override" value:displayValue]; };
    [rows addObjectsFromArray:@[ fullNames, displayNames ]];
    [rows addObject:Row(SNPrefsRowRule, @"")];
    [rows addObject:Row(SNPrefsRowLegend, L(@"messages.more"))];
    [rows addObject:[self check:@"messages.typing" pref:@"show_typing" fallback:YES inverted:NO]];
    [rows addObject:Row(SNPrefsRowRule, @"")];
    [rows addObject:Row(SNPrefsRowHeading, L(@"messages.emoji"))];
    [rows addObject:Row(SNPrefsRowLegend, L(@"messages.skin"))];
    [rows addObject:Row(SNPrefsRowSubtext, L(@"messages.skin.text"))];
    // preferred_skin_tone "1" (or none) is the default yellow; 2-6 the tones.
    NSInteger tone = MAX(1, SNPreferenceString(prefs, @"preferred_skin_tone").integerValue);
    for (NSInteger choice = 1; choice <= 6; choice++) {
        SNPrefsRow *row = Row(SNPrefsRowRadio, L([NSString stringWithFormat:@"messages.skin.%ld", (long)choice]));
        row.on = tone == choice;
        row.changed = ^(id unused) { [source setPreference:@"preferred_skin_tone" value:@(choice).stringValue]; };
        [rows addObject:row];
    }
    return rows;
}

- (NSArray<SNPrefsRow *> *)languageRows {
    id<SNSource> source = _source;
    NSString *locale = SNPreferenceString(_source.preferences, @"locale") ?: _source.me.locale ?: @"en-US";
    SNPrefsRow *language = Row(SNPrefsRowSelect, L(@"language.title"));
    // The languages this app has words for, as Slack names them.
    language.choices = @[ @[ @"English (UK)", @"en-GB" ], @[ @"English (US)", @"en-US" ], @[ @"Português (Brasil)", @"pt-BR" ] ];
    language.value = locale;
    language.changed = ^(NSString *value) {
        [source setPreference:@"locale" value:value];
        // Slack's client reloads in the new language.
        [NSApp sendAction:@selector(reloadLanguage:) to:nil from:nil];
    };
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:Row(SNPrefsRowLegend, L(@"language.title")), Row(SNPrefsRowSubtext, L(@"language.text")), language,
                                                            Row(SNPrefsRowRule, @""), nil];
    [rows addObjectsFromArray:[self timeZoneRowsInLocale:locale]];
    [rows addObjectsFromArray:@[
        Row(SNPrefsRowRule, @""), Row(SNPrefsRowLegend, L(@"language.spellcheck")),
        [self check:@"language.spellcheck.enable" pref:@"webapp_spellcheck" fallback:NO inverted:NO]
    ]];
    return rows;
}

/// Slack's TimezonePref: set_tz_automatically, and the tz picker it disables.
- (NSArray<SNPrefsRow *> *)timeZoneRowsInLocale:(NSString *)locale {
    id<SNSource> source = _source;
    BOOL automatic = SNPreferenceBool(_source.preferences, @"set_tz_automatically", YES);
    SNPrefsRow *check = Row(SNPrefsRowCheck, L(@"language.timezone.automatic"));
    check.on = automatic;
    check.changed = ^(NSNumber *on) {
        [source setPreference:@"set_tz_automatically" value:on.boolValue ? @"true" : @"false"];
        // Turned on, times follow the Mac's zone at once, and Slack's client saves it as tz.
        NSString *detected = on.boolValue ? SNTimeZoneChoiceForZone(NSTimeZone.defaultTimeZone) : nil;
        if (detected) [source setPreference:@"tz" value:detected];
    };
    SNPrefsRow *zone = Row(SNPrefsRowSelect, L(@"language.timezone"));
    zone.choices = SNTimeZoneChoices(locale);
    zone.value = SNTimeZoneChoiceForZone(NSTimeZone.defaultTimeZone);
    zone.disabled = automatic;
    zone.changed = ^(NSString *value) { [source setPreference:@"tz" value:value]; };
    return @[ Row(SNPrefsRowLegend, L(@"language.timezone")), check, zone, Row(SNPrefsRowSubtext, L(@"language.timezone.text")) ];
}

- (NSArray<SNPrefsRow *> *)accessibilityRows {
    return @[ Row(SNPrefsRowLegend, L(@"accessibility.display")), [self check:@"accessibility.underline" pref:@"underline_links" fallback:NO inverted:NO] ];
}

- (NSArray<SNPrefsRow *> *)readRows {
    NSDictionary *prefs = _source.preferences;
    id<SNSource> source = _source;
    // Slack always sends both; without them the list reads only what was scrolled to (ui/channel).
    BOOL immediately = SNPreferenceBool(prefs, @"mark_msgs_read_immediately", NO), oldest = SNPreferenceBool(prefs, @"start_scroll_at_oldest", NO);
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:Row(SNPrefsRowText, L(@"read.text")), Row(SNPrefsRowLegend, L(@"read.view")), nil];
    // One radio, two prefs saved together.
    NSArray *choices = @[ @[ @"read.where", @YES, @YES ], @[ @"read.newest", @YES, @NO ], @[ @"read.unread", @NO, @NO ] ];
    for (NSArray *choice in choices) {
        BOOL read = [choice[1] boolValue], start = [choice[2] boolValue];
        SNPrefsRow *row = Row(SNPrefsRowRadio, L(choice[0]));
        row.on = immediately == read && (oldest == start || !read);
        row.changed = ^(id unused) {
            [source setPreferences:@{@"mark_msgs_read_immediately" : read ? @"true" : @"false", @"start_scroll_at_oldest" : start ? @"true" : @"false"}];
        };
        [rows addObject:row];
    }
    return rows;
}

- (NSArray<SNPrefsRow *> *)advancedRows {
    NSDictionary *prefs = _source.preferences;
    id<SNSource> source = _source;
    BOOL newline = SNPreferenceBool(prefs, @"msg_input_send_btn", NO);
    SNPrefsRow *send = Row(SNPrefsRowRadio, L(@"advanced.enter.send"));
    send.on = !newline;
    send.changed = ^(id unused) { [source setPreference:@"msg_input_send_btn" value:@"false"]; };
    SNPrefsRow *line = Row(SNPrefsRowRadio, L(@"advanced.enter.line"));
    line.on = newline;
    line.changed = ^(id unused) { [source setPreference:@"msg_input_send_btn" value:@"true"]; };
    // Launching at login belongs to this Mac, as the desktop app's does.
    SNPrefsRow *login = Row(SNPrefsRowCheck, L(@"advanced.login"));
    login.on = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    login.changed = ^(NSNumber *on) {
        NSError *error = nil;
        if (on.boolValue) [SMAppService.mainAppService registerAndReturnError:&error];
        else [SMAppService.mainAppService unregisterAndReturnError:&error];
    };
    return @[
        Row(SNPrefsRowLegend, L(@"advanced.input")), [self check:@"advanced.smart" pref:@"disable_smart_symbols" fallback:YES inverted:YES],
        [self check:@"advanced.code" pref:@"enter_is_special_in_tbt" fallback:NO inverted:NO], Row(SNPrefsRowRule, @""),
        Row(SNPrefsRowLegend, L(@"advanced.enter")), send, line, Row(SNPrefsRowRule, @""), Row(SNPrefsRowLegend, L(@"advanced.other")), login
    ];
}

#pragma mark Tests

- (NSArray<NSString *> *)optionTitles {
    NSMutableArray *titles = [NSMutableArray new];
    for (SNPrefsRow *row in _rows) {
        if (row.kind == SNPrefsRowCheck || row.kind == SNPrefsRowRadio) [titles addObject:row.title];
        else if (row.kind == SNPrefsRowSelect) [titles addObject:row.title];
    }
    return titles;
}

- (BOOL)chooseOption:(NSString *)title value:(NSString *)value {
    for (NSUInteger i = 0; i < _rows.count; i++) {
        SNPrefsRow *row = _rows[i];
        if (![row.title isEqualToString:title] || row.disabled) continue;
        NSView *control = _controls[i];
        if ([control isKindOfClass:SNPrefsToggle.class]) [(SNPrefsToggle *)control toggle];
        else if ([control isKindOfClass:SNPrefsSelect.class] && value) [(SNPrefsSelect *)control choose:value];
        else if ([control isKindOfClass:SNPrefsField.class] && value) {
            ((SNPrefsField *)control).field.stringValue = value;
            [(SNPrefsField *)control save];
        } else continue;
        return YES;
    }
    return NO;
}

@end
