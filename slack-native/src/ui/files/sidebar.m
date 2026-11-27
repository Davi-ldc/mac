// Owns the Files tab's sidebar: its header, pages and recently viewed files.
#import "render/icon.h"
#import "render/strings.h"
#import "ui/files/fileview.h"
#import "ui/files/rows.h"
#import "ui/files/sidebar.h"
#import "ui/kit/button.h"
#import "ui/kit/container.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

/// The column's 49 pt header (as the DMs list's): the 18 pt black title 16 pt in (.p-browse_sidebar
/// .p-ia4_sidebar_header: 0 8 0 16), the 28 pt Create new button 8 pt from the right.
static const CGFloat kHeader = 49, kTitleX = 16, kButton = 28, kButtonRight = 8;
/// .p-browse_sidebar__item: 28 pt in an 8 pt container padding, 8 pt in, radius 4, 15 pt on a
/// 22 pt line; the 16 pt icon 8 pt before the label; the list 4 pt under the header.
static const CGFloat kRow = 28, kContainer = 8, kItemPadding = 8, kIcon = 16, kIconGap = 8, kListTop = 4;
/// .p-browse_sidebar__divider: a 1 pt rgba(foreground-low, .13) line with 12 pt around it.
static const CGFloat kDivider = 25;
/// The remove button: 20 pt, 64% until the pointer is on it.
static const CGFloat kClose = 20;

typedef NS_ENUM(NSInteger, SNFilesSidebarRowKind) {
    SNFilesSidebarRowPage,
    SNFilesSidebarRowDivider,
    SNFilesSidebarRowHeading,
    SNFilesSidebarRowFile,
};

@interface SNFilesSidebarRow : SNHoverView
@property (nonatomic) SNFilesSidebarRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *icon, *page;
@property (nonatomic, nullable) SNFile *file;
@property (nonatomic) BOOL selected, collapsed;
@property (nonatomic, readonly, nullable) SNButton *close;
@end

@implementation SNFilesSidebarRow

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.hoverColor = self.pressedColor = SNThemeSurfInvTer;
    self.overlayRadius = SNRadiusBase;
    self.overlayInsets = NSEdgeInsetsMake(0, kContainer, 0, kContainer);
    self.transitionDuration = 0;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setKind:(SNFilesSidebarRowKind)kind {
    _kind = kind;
    // Lines and headings take no hover fill.
    if (kind == SNFilesSidebarRowDivider) self.hoverColor = self.pressedColor = 0, self.enabled = NO;
    if (kind == SNFilesSidebarRowFile && !_close) {
        _close = [SNButton iconButtonNamed:@"close" size:kClose iconSize:16];
        _close.contentColor = SNColorWithAlpha(SNThemeContentInvPry, (SNThemeContentInvPry & 0xff) / 255.0 * 0.64);
        _close.hoverContentColor = _close.pressedContentColor = SNThemeContentInvPry;
        _close.hoverFillColor = 0;
        _close.alphaValue = 0;
        _close.tooltip = SNLocalized(@"files.recent.remove");
        [self addSubview:_close];
    }
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    // A selected row keeps its fill under the pointer.
    self.hoverColor = self.pressedColor = selected || _kind == SNFilesSidebarRowDivider ? 0 : SNThemeSurfInvTer;
    self.needsDisplay = YES;
}

- (void)stateDidChange {
    [super stateDidChange];
    _close.alphaValue = self.hovered || self.pressed ? 1 : 0;
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    _close.frame = NSMakeRect(NSWidth(self.bounds) - kContainer - 4 - kClose, (kRow - kClose) / 2, kClose, kClose);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    if (_kind == SNFilesSidebarRowDivider) {
        [SNColor(SNLegacyHairline) setFill];
        NSRectFillUsingOperation(NSMakeRect(12, 12, NSWidth(bounds) - 24, 1), NSCompositingOperationSourceOver);
        return;
    }
    if (_selected) {
        [SNColor(SNThemeBaseHgl1) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(kContainer, 0, NSWidth(bounds) - 2 * kContainer, kRow) xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
    }
    SNColorToken color = _selected ? SNThemeContentHgl1 : self.hovered || self.pressed ? SNThemeContentInvPry : SNThemeContentInvSec;
    CGFloat x = kContainer + kItemPadding;
    NSRect slot = NSMakeRect(x, (kRow - kIcon) / 2, kIcon, kIcon);
    if (_kind == SNFilesSidebarRowHeading) SNDrawIcon(_collapsed ? @"caret-right" : @"caret-down", kIcon, color, slot);
    else if (_icon) SNDrawIcon(_icon, kIcon, color, slot);
    x += kIcon + kIconGap;
    CGFloat right = NSWidth(bounds) - kContainer - kItemPadding - (_close && (self.hovered || self.pressed) ? kClose + 4 : 0);
    SNDrawText(_title, SNFont(SNFontSizeBase, SNFontWeightRegular), color, kRow, NSTextAlignmentLeft, 1, NSMakeRect(x, 0, MAX(0, right - x), kRow));
}

@end

/// The pane's view, which tells the pane when it comes on screen and when it is laid out.
@interface SNFilesSidebarView : SNContainerView
@property (nonatomic, copy) void (^appeared)(void), (^laidOut)(void);
@end

@implementation SNFilesSidebarView
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && self.appeared) self.appeared();
}
- (void)layout {
    [super layout];
    if (self.laidOut) self.laidOut();
}
@end

@interface SNFilesSidebarPane () <SNChangeObserver>
@end

@implementation SNFilesSidebarPane {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNFilesSidebarView *_view;
    SNLabel *_title;
    SNButton *_create;
    NSScrollView *_scroll;
    SNContainerView *_list;
    NSMutableArray<SNFilesSidebarRow *> *_rows;
    NSString *_page;
    BOOL _recentCollapsed;
}

+ (void)load { SNRegisterTabPane(SNTabFiles, self); }

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _source = source;
    _navigator = navigator;
    _rows = [NSMutableArray new];
    _view = [[SNFilesSidebarView alloc] initWithFrame:NSMakeRect(0, 0, 516, 800)];
    __weak SNFilesSidebarPane *weakSelf = self;
    _view.appeared = ^{ [weakSelf rebuild]; };
    _view.laidOut = ^{ [weakSelf layout]; };
    _title = [SNLabel labelWithText:SNLocalized(@"files.title") font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNThemeContentInvPry];
    _title.lineHeight = round(SNFontSizeSubtitle * 1.25);
    _create = [SNButton iconButtonNamed:@"plus" size:kButton iconSize:20];
    _create.contentColor = SNThemeContentInvSec;
    _create.hoverContentColor = _create.pressedContentColor = SNThemeContentInvPry;
    _create.hoverFillColor = 0;
    _create.hoverColor = _create.pressedColor = SNThemeSurfInvTer;
    _create.tooltip = SNLocalized(@"files.create");
    _create.tooltipPlacement = SNPlacementBelow;
    _create.action = ^(SNButton *button) { [weakSelf showCreateMenu]; };
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _list = [[SNContainerView alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _list;
    for (NSView *view in @[ _title, _create, _scroll ]) [_view addSubview:view];
    [source addChangeObserver:self];
    [self rebuild];
    return self;
}

- (NSView *)view { return _view; }
- (NSView *)createButton { return _create; }
- (NSArray<NSView *> *)rows { return _rows; }

- (void)sourceChanged:(SNChange *)change {
    if (change.recentFiles) [self rebuild];
}

- (void)showLocation:(SNLocation *)location {
    NSString *page = location.tab == SNTabFiles && !location.conversationID ? location.page : nil;
    if (page == _page || [page isEqualToString:_page]) return;
    _page = [page copy];
    for (SNFilesSidebarRow *row in _rows) row.selected = row.page && [row.page isEqualToString:page];
}

- (SNFilesSidebarRow *)rowOfKind:(SNFilesSidebarRowKind)kind title:(NSString *)title {
    SNFilesSidebarRow *row = [[SNFilesSidebarRow alloc] initWithFrame:NSZeroRect];
    row.kind = kind;
    row.title = title;
    [_rows addObject:row];
    [_list addSubview:row];
    return row;
}

- (void)rebuild {
    for (NSView *row in _rows) [row removeFromSuperview];
    [_rows removeAllObjects];
    __weak SNFilesSidebarPane *weakSelf = self;
    for (NSArray<NSString *> *page in @[ @[ SNPageFiles, @"canvas-browser", @"files.nav.all" ], @[ SNPageFilesCanvases, @"canvas-content", @"files.nav.canvases" ],
                                         @[ SNPageFilesLists, @"lists", @"files.nav.lists" ] ]) {
        SNFilesSidebarRow *row = [self rowOfKind:SNFilesSidebarRowPage title:SNLocalized(page[2])];
        row.icon = page[1];
        row.page = page[0];
        row.selected = [_page isEqualToString:page[0]];
        NSString *target = page[0];
        row.action = ^(SNFilesSidebarRow *clicked) { [weakSelf openPage:target]; };
    }
    // The recently viewed collection, under a divider, once a file was opened here.
    NSArray<SNFile *> *recent = _source.recentFiles;
    if (recent.count) {
        [self rowOfKind:SNFilesSidebarRowDivider title:@""];
        SNFilesSidebarRow *heading = [self rowOfKind:SNFilesSidebarRowHeading title:SNLocalized(@"files.recent")];
        heading.collapsed = _recentCollapsed;
        heading.action = ^(SNFilesSidebarRow *clicked) {
            SNFilesSidebarPane *pane = weakSelf;
            if (!pane) return;
            pane->_recentCollapsed = !pane->_recentCollapsed;
            [pane rebuild];
        };
        if (!_recentCollapsed)
            for (SNFile *file in recent) {
                SNFilesSidebarRow *row = [self rowOfKind:SNFilesSidebarRowFile title:file.title.length ? file.title : file.name];
                row.file = file;
                row.icon = SNFileTypeGlyph(file);
                id<SNSource> source = _source;
                row.action = ^(SNFilesSidebarRow *clicked) { SNOpenFile(file, source); };
                NSString *fileID = file.fileID;
                row.close.action = ^(SNButton *button) { [source forgetRecentFile:fileID]; };
            }
    }
    [self layout];
}

- (void)openPage:(NSString *)page {
    id<SNNavigator> navigator = _navigator;
    [navigator go:[SNLocation locationWithTab:SNTabFiles conversation:nil thread:nil page:page panel:navigator.location.panel]];
}

- (void)showCreateMenu {
    NSString *domain = _source.workspace.domain;
    void (^open)(void) = ^{
        if (domain.length) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@.slack.com/", domain]]];
    };
    SNMenuItem *canvas = [SNMenuItem itemWithTitle:SNLocalized(@"files.create.canvas") action:open];
    canvas.icon = @"add-channel-canvas";
    canvas.iconSize = 20;
    SNMenuItem *list = [SNMenuItem itemWithTitle:SNLocalized(@"files.create.list") action:open];
    list.icon = @"lists";
    list.iconSize = 20;
    [[[SNMenu alloc] initWithItems:@[ canvas, list ] width:0] showForRect:_create.bounds inView:_create placement:SNPlacementBelow];
}

- (void)layout {
    CGFloat width = NSWidth(_view.bounds);
    _create.frame = NSMakeRect(width - kButtonRight - kButton, (kHeader - kButton) / 2, kButton, kButton);
    _title.frame = NSMakeRect(kTitleX, (kHeader - _title.lineHeight) / 2, MAX(0, NSMinX(_create.frame) - kTitleX - 8), _title.lineHeight);
    _scroll.frame = NSMakeRect(0, kHeader, width, MAX(0, NSHeight(_view.bounds) - kHeader));
    CGFloat y = kListTop;
    for (SNFilesSidebarRow *row in _rows) {
        CGFloat height = row.kind == SNFilesSidebarRowDivider ? kDivider : kRow;
        row.frame = NSMakeRect(0, y, width, height);
        y += height;
    }
    _list.frame = NSMakeRect(0, 0, width, MAX(y, NSHeight(_scroll.frame)));
}

@end
