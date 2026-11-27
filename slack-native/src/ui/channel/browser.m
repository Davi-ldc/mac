// Owns the channel browser: its search, sort, pages, rows and what they join, leave and open.
#import "render/format.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/channel/browser.h"
#import "ui/kit/button.h"
#import "ui/kit/dialog.h"
#import "ui/kit/forms.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

/// The view header: 52 pt, the 18 pt black title 20 pt in; the tab under it 38 pt.
static const CGFloat kHeader = 52, kTabs = 38, kSide = 20;
/// .p-explorer_search__content: 1000 pt at most, 16 pt in; 16 pt above the field, 16 under it; the
/// controls' 13 pt line and 8 pt under it.
static const CGFloat kContentMax = 1000, kContentInset = 16, kSearchTop = 16, kControls = 26;
/// .c-channel_search_result__channel: 16 pt in, 72 pt at least, 1 pt otl-ter borders, the outer
/// corners 12; the name 15 bold on 22.5, the details 13 pt 4 pt under it; the actions 12 pt in.
static const CGFloat kRowPadding = 16, kRow = 74, kNameLine = 22.5, kDetailLine = 16.25, kActionInset = 12;
static const CGFloat kPager = 56;
static const NSUInteger kPageButtons = 7;

/// Sort menu entries: the title key, Slack's sort and its direction.
static NSArray<NSArray *> *SortChoices(BOOL query) {
    NSMutableArray *choices = [NSMutableArray arrayWithObject:query ? @[ @"channel.browser.sort.relevant", @"relevant", @NO ] : @[ @"channel.browser.sort.recommended", @"recommended", @NO ]];
    [choices addObjectsFromArray:@[
        @[ @"channel.browser.sort.az", @"name", @YES ], @[ @"channel.browser.sort.za", @"name", @NO ], @[ @"channel.browser.sort.newest", @"created", @NO ],
        @[ @"channel.browser.sort.oldest", @"created", @YES ], @[ @"channel.browser.sort.most", @"member_count", @NO ], @[ @"channel.browser.sort.fewest", @"member_count", @YES ]
    ]];
    return choices;
}

@class SNChannelBrowserRow;

/// Join / Joined / Leave: its words follow the pointer on it.
@interface SNBrowserMembershipButton : SNButton
@property (nonatomic, copy) void (^stateChanged)(void);
@end

@implementation SNBrowserMembershipButton
- (void)stateDidChange {
    [super stateDidChange];
    if (self.stateChanged) self.stateChanged();
}
@end

@interface SNChannelBrowserView ()
- (void)rowClicked:(SNChannelBrowserRow *)row;
- (void)rowToggled:(SNChannelBrowserRow *)row;
@end

/// One channel of the list.
@interface SNChannelBrowserRow : SNHoverView
@property (nonatomic) SNConversation *channel;
@property (nonatomic) BOOL first, last;
@property (nonatomic, weak) SNChannelBrowserView *browser;
@property (nonatomic, readonly) SNButton *button;
@end

@implementation SNChannelBrowserRow {
    SNButton *_button;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    SNBrowserMembershipButton *button = [SNBrowserMembershipButton outlineButtonWithTitle:@""];
    _button = button;
    _button.font = SNFont(SNFontSizeBase, SNFontWeightBold);
    _button.hidden = YES;
    __weak SNChannelBrowserRow *weakSelf = self;
    button.stateChanged = ^{ [weakSelf placeButton]; };
    _button.action = ^(SNButton *button) { [weakSelf.browser rowToggled:weakSelf]; };
    [self addSubview:_button];
    self.action = ^(SNChannelBrowserRow *row) { [row.browser rowClicked:row]; };
    return self;
}

- (BOOL)isFlipped { return YES; }

/// Join, or Leave for a channel the user is in ("Joined" until the pointer is on it); nothing
/// for #general and archived channels, which say why instead.
- (NSString *)buttonTitle {
    if (_channel.isArchived || (_channel.isMember && _channel.isGeneral)) return nil;
    if (!_channel.isMember) return SNLocalized(@"channel.browser.join");
    return SNLocalized(_button.hovered ? @"channel.browser.leave" : @"channel.browser.joined");
}

- (void)layout {
    [super layout];
    [self placeButton];
}

- (void)placeButton {
    NSString *title = self.buttonTitle;
    _button.hidden = !self.hovered || !title;
    if (!title) return;
    if (![_button.title isEqualToString:title]) _button.title = title;
    CGFloat width = MAX(80, ceil(_button.fittingContentSize.width) + 24);
    _button.frame = NSMakeRect(NSWidth(self.bounds) - kActionInset - 4 - width, (NSHeight(self.bounds) - 36) / 2, width, 36);
}

- (void)stateDidChange {
    [super stateDidChange];
    [self placeButton];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    CGFloat radius = SNRadiusXlarge;
    NSBezierPath *frame = [NSBezierPath bezierPath];
    NSRect box = NSInsetRect(bounds, 0.5, 0.5);
    box.size.height += _last ? 0 : 1;
    CGFloat top = _first ? radius : 0, bottom = _last ? radius : 0;
    [frame moveToPoint:NSMakePoint(NSMinX(box) + top, NSMinY(box))];
    [frame lineToPoint:NSMakePoint(NSMaxX(box) - top, NSMinY(box))];
    if (top) [frame curveToPoint:NSMakePoint(NSMaxX(box), NSMinY(box) + top) controlPoint1:NSMakePoint(NSMaxX(box), NSMinY(box)) controlPoint2:NSMakePoint(NSMaxX(box), NSMinY(box))];
    [frame lineToPoint:NSMakePoint(NSMaxX(box), NSMaxY(box) - bottom)];
    if (bottom) [frame curveToPoint:NSMakePoint(NSMaxX(box) - bottom, NSMaxY(box)) controlPoint1:NSMakePoint(NSMaxX(box), NSMaxY(box)) controlPoint2:NSMakePoint(NSMaxX(box), NSMaxY(box))];
    [frame lineToPoint:NSMakePoint(NSMinX(box) + bottom, NSMaxY(box))];
    if (bottom) [frame curveToPoint:NSMakePoint(NSMinX(box), NSMaxY(box) - bottom) controlPoint1:NSMakePoint(NSMinX(box), NSMaxY(box)) controlPoint2:NSMakePoint(NSMinX(box), NSMaxY(box))];
    [frame lineToPoint:NSMakePoint(NSMinX(box), NSMinY(box) + top)];
    if (top) [frame curveToPoint:NSMakePoint(NSMinX(box) + top, NSMinY(box)) controlPoint1:NSMakePoint(NSMinX(box), NSMinY(box)) controlPoint2:NSMakePoint(NSMinX(box), NSMinY(box))];
    [frame closePath];
    [SNColor(self.hovered ? SNColorBaseTer : SNColorBasePry) setFill];
    [frame fill];
    [SNColor(SNColorOtlTer) setStroke];
    [frame stroke];

    NSFont *name = SNFont(SNFontSizeBase, SNFontWeightBold), *small = SNFont(SNFontSizeCaption, SNFontWeightRegular), *smallBold = SNFont(SNFontSizeCaption, SNFontWeightBold);
    CGFloat x = kRowPadding, y = kRowPadding, right = NSWidth(bounds) - kRowPadding - (_button.hidden ? 0 : NSWidth(_button.frame) + 12);
    BOOL priv = _channel.kind == SNConversationPrivateChannel;
    SNDrawIcon(priv ? @"lock" : @"channel", 16, SNColorContentPry, NSMakeRect(x, y + (kNameLine - 16) / 2, 16, 16));
    x += 16 + 6;
    CGFloat nameWidth = MIN(right - x, ceil(SNTextWidth(_channel.name, name)));
    SNDrawText(_channel.name, name, SNColorContentPry, kNameLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, nameWidth, kNameLine));
    x += nameWidth + 8;
    if (_channel.isArchived) {
        SNDrawText(SNLocalized(@"channel.browser.archived"), small, SNColorContentSec, kNameLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, MAX(0, right - x), kNameLine));
        x += ceil(SNTextWidth(SNLocalized(@"channel.browser.archived"), small)) + 8;
    }
    if (self.hovered && x < right)
        SNDrawText(SNLocalized(@"channel.browser.view"), small, SNColorWithAlpha(SNLegacyForegroundMax, 0.7), kNameLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, right - x, kNameLine));

    // ✓ Joined · 12 members · the purpose.
    x = kRowPadding;
    y += kNameLine + 4;
    NSString *separator = @"  ·  ";
    if (_channel.isMember) {
        SNDrawIcon(@"check", 14, SNColorContentHgl2, NSMakeRect(x, y + (kDetailLine - 14) / 2, 14, 14));
        x += 16;
        NSString *joined = SNLocalized(@"channel.browser.joinedLabel");
        SNDrawText(joined, smallBold, SNColorContentHgl2, kDetailLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, MAX(0, right - x), kDetailLine));
        x += ceil(SNTextWidth(joined, smallBold));
        SNDrawText(separator, small, SNColorContentSec, kDetailLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, MAX(0, right - x), kDetailLine));
        x += ceil(SNTextWidth(separator, small));
    }
    NSString *members = SNLocalizedFormat(_channel.memberCount == 1 ? @"channel.browser.members.one" : @"channel.browser.members.other", @(_channel.memberCount));
    NSString *details = _channel.purpose.length ? [NSString stringWithFormat:@"%@%@%@", members, separator, _channel.purpose] : members;
    if (x < right) SNDrawText(details, small, SNColorContentSec, kDetailLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, right - x, kDetailLine));
}

@end

@interface SNChannelBrowserList : NSView
@end

@implementation SNChannelBrowserList
- (BOOL)isFlipped { return YES; }
@end

@implementation SNChannelBrowserView {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNLabel *_title, *_tab, *_empty, *_emptyHint;
    NSView *_headerLine, *_tabUnderline;
    SNFormInput *_field;
    SNButton *_sortButton, *_retry;
    NSScrollView *_scroll;
    SNChannelBrowserList *_list;
    NSMutableArray<SNChannelBrowserRow *> *_rows;
    NSMutableArray<SNButton *> *_pageButtons;
    NSString *_query, *_sort;
    BOOL _ascending, _failed;
    NSInteger _request;
}

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 800)])) return nil;
    _source = source;
    _navigator = navigator;
    _query = @"";
    _sort = @"recommended";
    _page = 1;
    _pageCount = 1;
    _channels = @[];
    _rows = [NSMutableArray new];
    _pageButtons = [NSMutableArray new];
    _title = [SNLabel labelWithText:SNLocalized(@"channel.browser.title") font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNColorContentPry];
    _title.lineHeight = kHeader;
    _tab = [SNLabel labelWithText:SNLocalized(@"channel.browser.tab") font:SNFont(SNFontSizeBase, SNFontWeightBold) color:SNColorContentPry];
    _tab.lineHeight = kTabs;
    _field = [[SNFormInput alloc] initWithPlaceholder:SNLocalized(@"channel.browser.search") icon:@"search"];
    __weak SNChannelBrowserView *weakSelf = self;
    _field.keyCommand = ^BOOL(SEL command) {
        if (command != @selector(insertNewline:)) return NO;
        SNChannelBrowserView *browser = weakSelf;
        [browser search:browser->_field.text];
        return YES;
    };
    _sortButton = [SNButton outlineButtonWithTitle:@""];
    _sortButton.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    _sortButton.borderColor = 0;
    _sortButton.action = ^(SNButton *button) { [weakSelf showSortMenu]; };
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _list = [[SNChannelBrowserList alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _list;
    _empty = [SNLabel labelWithText:SNLocalized(@"channel.browser.empty") font:SNFont(SNFontSizeSubtitle, SNFontWeightBold) color:SNColorContentPry];
    _empty.alignment = NSTextAlignmentCenter;
    _emptyHint = [SNLabel labelWithText:SNLocalized(@"channel.browser.emptyHint") font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNColorContentSec];
    _emptyHint.alignment = NSTextAlignmentCenter;
    _retry = [SNButton outlineButtonWithTitle:SNLocalized(@"channel.browser.retry")];
    _retry.font = SNFont(SNFontSizeBase, SNFontWeightBold);
    _retry.action = ^(SNButton *button) {
        SNChannelBrowserView *browser = weakSelf;
        if (browser) [browser showPage:browser->_page];
    };
    _empty.hidden = _emptyHint.hidden = _retry.hidden = YES;
    _headerLine = [[NSView alloc] initWithFrame:NSZeroRect];
    _headerLine.wantsLayer = YES;
    _headerLine.layer.backgroundColor = SNCGColor(SNColorOtlTer);
    _tabUnderline = [[NSView alloc] initWithFrame:NSZeroRect];
    _tabUnderline.wantsLayer = YES;
    _tabUnderline.layer.backgroundColor = SNCGColor(SNColorContentPry);
    for (NSView *view in @[ _title, _tab, _headerLine, _tabUnderline, _field, _sortButton, _scroll, _empty, _emptyHint, _retry ]) [self addSubview:view];
    [self updateSortTitle];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)showsError { return _failed; }

- (NSRect)contentRect {
    CGFloat width = MIN(kContentMax, NSWidth(self.bounds)) - 2 * kContentInset;
    return NSMakeRect(round((NSWidth(self.bounds) - width) / 2), 0, width, 0);
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _title.frame = NSMakeRect(kSide, 0, width - 2 * kSide, kHeader);
    _tab.frame = NSMakeRect(kSide, kHeader, ceil(_tab.textWidth), kTabs);
    _headerLine.frame = NSMakeRect(0, kHeader + kTabs - 1, width, 1);
    _tabUnderline.frame = NSMakeRect(NSMinX(_tab.frame), kHeader + kTabs - 2, NSWidth(_tab.frame), 2);
    NSRect content = self.contentRect;
    CGFloat y = kHeader + kTabs + kSearchTop;
    _field.frame = NSMakeRect(NSMinX(content), y, NSWidth(content), SNFormControlHeight);
    y += SNFormControlHeight + 16;
    CGFloat sortWidth = ceil(_sortButton.fittingContentSize.width) + 16;
    _sortButton.frame = NSMakeRect(NSMaxX(content) - sortWidth, y, sortWidth, kControls);
    y += kControls + 8;
    _scroll.frame = NSMakeRect(0, y, width, MAX(0, NSHeight(self.bounds) - y));
    _empty.frame = NSMakeRect(NSMinX(content), y + 48, NSWidth(content), 24);
    _emptyHint.frame = NSMakeRect(NSMinX(content), y + 80, NSWidth(content), 22);
    CGFloat retryWidth = MAX(80, ceil(_retry.fittingContentSize.width) + 24);
    _retry.frame = NSMakeRect(NSMinX(content) + round((NSWidth(content) - retryWidth) / 2), y + 116, retryWidth, 36);
    [self layoutRows];
}

- (void)layoutRows {
    NSRect content = self.contentRect;
    CGFloat y = 0;
    for (SNChannelBrowserRow *row in _rows) {
        row.frame = NSMakeRect(NSMinX(content), y, NSWidth(content), kRow);
        y += kRow;
    }
    CGFloat x = NSMinX(content);
    if (_pageButtons.count) y += 16;
    for (SNButton *button in _pageButtons) {
        CGFloat buttonWidth = MAX(36, ceil(button.fittingContentSize.width) + 20);
        button.frame = NSMakeRect(x, y, buttonWidth, 36);
        x += buttonWidth + 4;
    }
    CGFloat pagerWidth = x - NSMinX(content);
    for (SNButton *button in _pageButtons) button.frame = NSOffsetRect(button.frame, round((NSWidth(content) - pagerWidth) / 2), 0);
    _list.frame = NSMakeRect(0, 0, NSWidth(_scroll.frame), y + (_pageButtons.count ? kPager : 24));
}

- (void)focusSearch { [_field focus]; }

#pragma mark Sorting

- (NSString *)sort { return _sort; }

- (void)updateSortTitle {
    NSString *title = nil;
    for (NSArray *choice in SortChoices(_query.length))
        if ([choice[1] isEqualToString:_sort] && ([_sort isEqualToString:@"recommended"] || [_sort isEqualToString:@"relevant"] || [choice[2] boolValue] == _ascending)) title = SNLocalized(choice[0]);
    _sortButton.title = SNLocalizedFormat(@"channel.browser.sort", title ?: @"");
    self.needsLayout = YES;
}

- (void)showSortMenu {
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray arrayWithObject:[SNMenuItem headerWithTitle:SNLocalized(@"channel.browser.sortHeader")]];
    __weak SNChannelBrowserView *weakSelf = self;
    for (NSArray *choice in SortChoices(_query.length)) {
        NSString *sort = choice[1];
        BOOL ascending = [choice[2] boolValue];
        SNMenuItem *item = [SNMenuItem itemWithTitle:SNLocalized(choice[0]) action:^{ [weakSelf sortBy:sort ascending:ascending]; }];
        item.checked = [sort isEqualToString:_sort] && (ascending == _ascending || [sort isEqualToString:@"recommended"] || [sort isEqualToString:@"relevant"]);
        [items addObject:item];
    }
    [[[SNMenu alloc] initWithItems:items width:240] showForRect:_sortButton.bounds inView:_sortButton placement:SNPlacementBelow];
}

- (void)sortBy:(NSString *)sort ascending:(BOOL)ascending {
    _sort = [sort copy];
    _ascending = ascending;
    [self updateSortTitle];
    [self showPage:1];
}

#pragma mark Loading

- (void)reload {
    _query = @"";
    _field.text = @"";
    // A fresh browser without a query starts with Slack's recommendations.
    _sort = @"recommended";
    _ascending = NO;
    [self updateSortTitle];
    [self showPage:1];
}

// Submitting a query sorts by relevance.
- (void)search:(NSString *)query {
    _query = [[query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] copy];
    _field.text = query;
    if (_query.length) _sort = @"relevant";
    else if ([_sort isEqualToString:@"relevant"]) _sort = @"recommended";
    [self updateSortTitle];
    [self showPage:1];
}

- (void)showPage:(NSInteger)page {
    NSInteger request = ++_request;
    __weak SNChannelBrowserView *weakSelf = self;
    [_source browseChannels:_query sort:_sort ascending:_ascending page:page completion:^(NSArray<SNConversation *> *channels, NSInteger pages, NSString *error) {
        SNChannelBrowserView *browser = weakSelf;
        if (!browser || request != browser->_request) return;
        browser->_page = page;
        browser->_failed = error != nil || !channels;
        browser->_pageCount = browser->_failed ? 0 : pages;
        [browser showChannels:browser->_failed ? @[] : channels];
    }];
}

- (void)showChannels:(NSArray<SNConversation *> *)channels {
    _channels = [channels copy];
    for (NSView *view in [(NSArray<NSView *> *)_rows arrayByAddingObjectsFromArray:_pageButtons]) [view removeFromSuperview];
    [_rows removeAllObjects];
    [_pageButtons removeAllObjects];
    for (NSUInteger i = 0; i < channels.count; i++) {
        SNChannelBrowserRow *row = [[SNChannelBrowserRow alloc] initWithFrame:NSZeroRect];
        row.channel = channels[i];
        row.browser = self;
        row.first = i == 0;
        row.last = i + 1 == channels.count;
        [_rows addObject:row];
        [_list addSubview:row];
    }
    if (_pageCount > 1) [self makePager];
    if (_failed) {
        _empty.text = SNLocalized(@"channel.browser.error");
        _emptyHint.text = SNLocalized(@"channel.browser.errorHint");
        _empty.hidden = _emptyHint.hidden = _retry.hidden = NO;
    } else {
        _empty.text = SNLocalized(@"channel.browser.empty");
        _emptyHint.text = SNLocalized(@"channel.browser.emptyHint");
        // "No results" only for a search that found nothing.
        _empty.hidden = _emptyHint.hidden = channels.count || !_query.length;
        _retry.hidden = YES;
    }
    [self layoutRows];
    [_scroll.contentView scrollToPoint:NSZeroPoint];
    [_scroll reflectScrolledClipView:_scroll.contentView];
}

/// Numbered pages around the current one, with the previous and next arrows.
- (void)makePager {
    NSInteger first = MAX(1, MIN(_page - (NSInteger)kPageButtons / 2, _pageCount - (NSInteger)kPageButtons + 1)), last = MIN(_pageCount, first + (NSInteger)kPageButtons - 1);
    __weak SNChannelBrowserView *weakSelf = self;
    void (^add)(NSString *, NSString *, NSInteger, BOOL) = ^(NSString *title, NSString *icon, NSInteger target, BOOL current) {
        SNButton *button = icon ? [SNButton iconButtonNamed:icon size:36 iconSize:16] : [SNButton outlineButtonWithTitle:title];
        if (current) {
            button.fillColor = button.hoverFillColor = SNColorBaseInvHgl1;
            button.borderColor = 0;
        }
        button.enabled = target >= 1 && target <= self->_pageCount && !current;
        button.action = ^(SNButton *clicked) { [weakSelf showPage:target]; };
        [self->_pageButtons addObject:button];
        [self->_list addSubview:button];
    };
    add(nil, @"caret-left", _page - 1, NO);
    for (NSInteger page = first; page <= last; page++) add(@(page).stringValue, nil, page, page == _page);
    add(nil, @"caret-right", _page + 1, NO);
}

#pragma mark Rows

- (void)rowClicked:(SNChannelBrowserRow *)row { [_navigator openConversation:row.channel.conversationID]; }

- (void)openChannelAtIndex:(NSUInteger)index {
    if (index < _rows.count) [self rowClicked:_rows[index]];
}

- (void)toggleMembershipOfChannelAtIndex:(NSUInteger)index {
    if (index < _rows.count) [self rowToggled:_rows[index]];
}

- (void)rowToggled:(SNChannelBrowserRow *)row {
    SNConversation *channel = row.channel;
    if (channel.isArchived) return;
    __weak SNChannelBrowserRow *weakRow = row;
    void (^member)(BOOL) = ^(BOOL isMember) {
        SNChannelBrowserRow *shown = weakRow;
        shown.channel = [shown.channel conversationByMergingJSON:@{@"is_member" : @(isMember)}];
        [shown placeButton];
        shown.needsDisplay = YES;
    };
    if (!channel.isMember) {
        [_source joinChannelFromBrowser:channel.conversationID completion:^(NSString *error) {
            if (!error) member(YES);
        }];
        return;
    }
    if (channel.isGeneral) return;
    id<SNSource> source = _source;
    void (^leave)(void) = ^{
        member(NO);
        [source leaveConversation:channel.conversationID completion:^(NSString *error) {
            if (error) member(YES);
        }];
    };
    // A private channel asks first, as /leave does.
    if (channel.kind != SNConversationPrivateChannel || !self.window) return leave();
    [SNConfirmDialog showInWindow:self.window
                            title:SNLocalizedFormat(@"composer.command.leave.title", [@"#" stringByAppendingString:channel.name])
                             text:SNLocalized(@"composer.command.leave.private")
                        accessory:nil
                     confirmTitle:SNLocalized(@"composer.command.leave.confirm")
                       completion:^(BOOL confirmed) {
                           if (confirmed) leave();
                       }];
}

@end
