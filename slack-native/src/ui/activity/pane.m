// Owns the Activity tab: the source's feed made into rows, its filters, list and peek.
#import "render/strings.h"
#import "ui/activity/pane.h"
#import "ui/kit/container.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/present/names.h"
#import "ui/present/preview.h"

/// The filter tabs: 13 pt bold labels 16 pt apart on a 36 pt row, the current one #f8f8f8 over a
/// 2 pt underline, like the conversation's tabs.
static const CGFloat kTabsHeight = 36, kTabPadding = 8, kTabsInset = 8, kUnderline = 2;

#pragma mark Tabs

@interface SNActivityTab : SNHoverView
@property (nonatomic, readonly) SNLabel *label;
@property (nonatomic) BOOL current;
@end

@implementation SNActivityTab {
    CALayer *_underline;
}

- (instancetype)initWithTitle:(NSString *)title {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.hoverColor = self.pressedColor = SNThemeSurfInvTer;
    self.overlayRadius = 6;
    self.transitionDuration = 0;
    _label = [SNLabel labelWithText:title font:SNFont(SNFontSizeCaption, SNFontWeightBold) color:SNThemeContentInvSec];
    _label.lineHeight = kTabsHeight;
    _label.alignment = NSTextAlignmentCenter;
    [self addSubview:_label];
    _underline = [CALayer layer];
    _underline.backgroundColor = SNCGColor(SNThemeBasePry);
    [self.layer addSublayer:_underline];
    return self;
}

- (CGFloat)fittingWidth { return ceil(_label.textWidth) + 2 * kTabPadding; }

- (void)setCurrent:(BOOL)current {
    _current = current;
    [self stateDidChange];
}

- (void)stateDidChange {
    [super stateDidChange];
    _label.color = self.current || self.hovered ? SNThemeContentInvPry : SNThemeContentInvSec;
    _underline.hidden = !self.current;
}

- (void)layout {
    [super layout];
    _label.frame = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _underline.frame = CGRectMake(0, self.bounds.size.height - kUnderline, self.bounds.size.width, kUnderline);
    [CATransaction commit];
}

@end

#pragma mark Pane

/// The pane's view, which tells the pane when it comes on screen.
@interface SNActivityPaneView : SNContainerView
@property (nonatomic, copy) void (^appeared)(void);
@end

@implementation SNActivityPaneView
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && self.appeared) self.appeared();
}
@end

/// An entry, its message once known, and its rows for each list style.
@interface SNActivityRow : NSObject
@property (nonatomic) SNActivityEntry *entry;
@property (nonatomic, nullable) SNMessage *message;
/// The people the row names (the actor, its message's mentions).
@property (nonatomic, copy) NSSet<NSString *> *userIDs;
@property (nonatomic) NSMutableDictionary<NSNumber *, SNActivityListItem *> *items;
@end

@implementation SNActivityRow
@end

/// The filters are the web client's tabs over the "all" feed; a filter showing fewer rows than
/// kFilledList asks for the next page while the feed holds fewer than kFillLimit entries.
static const NSUInteger kFilledList = 10, kFillLimit = 100;

@interface SNActivityPane () <SNChangeObserver>
@end

@implementation SNActivityPane {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNActivityPaneView *_view;
    NSArray<SNActivityTab *> *_tabs;
    /// The filter of each tab, in order.
    NSArray<NSNumber *> *_tabFilters;
    CALayer *_tabsLine;
    SNLabel *_empty;
    BOOL _current;
    /// Rows by entry key, made again only when something they show changed; while neither the
    /// tab nor its peek shows, changes only mark them.
    NSMutableDictionary<NSString *, SNActivityRow *> *_rows;
    NSMutableSet<NSString *> *_dirty;
    BOOL _feedChanged;
    /// The open peek's list, spinner, empty label and switch, kept in step with the feed.
    __weak SNActivityListView *_peekList;
    __weak NSProgressIndicator *_peekSpinner;
    __weak SNLabel *_peekEmpty;
    __weak SNUnreadsToggle *_peekToggle;
}

+ (void)load { SNRegisterTabPane(SNTabActivity, self); }

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _source = source;
    _navigator = navigator;
    _rows = [NSMutableDictionary new];
    _dirty = [NSMutableSet new];
    _feedChanged = YES;
    _view = [[SNActivityPaneView alloc] initWithFrame:NSMakeRect(0, 0, 516, 800)];
    _view.wantsLayer = YES;
    _header = [[SNListHeader alloc] initWithTitle:SNLocalized(@"activity.title") style:SNListHeaderPage caret:NO compose:NO];
    __weak SNActivityPane *weakSelf = self;
    _view.appeared = ^{ [weakSelf update]; };
    [self bindToggle:_header.unreadsToggle];
    [self makeTabs];
    _tabsLine = [CALayer layer];
    _tabsLine.backgroundColor = SNCGColor(SNThemeOtlInvPry);
    [_view.layer addSublayer:_tabsLine];
    _list = [self makeListWithStyle:SNActivityListSidebar];
    _empty = [self makeEmptyLabelWithColor:SNThemeContentInvSec];
    for (NSView *view in @[ _header, _list, _empty ]) [_view addSubview:view];
    self.filter = SNActivityAll;
    _view.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resized:) name:NSViewFrameDidChangeNotification object:_view];
    [source addChangeObserver:self];
    [self resized:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (NSView *)view { return _view; }

/// ActivityPageTabs: VIP follows All while the plan offers VIPs and the user has some.
- (void)makeTabs {
    BOOL vip = _source.offersVIPs && _source.vipUserIDs.count > 0;
    NSArray *filters = vip ? @[ @(SNActivityAll), @(SNActivityVIP), @(SNActivityMentions), @(SNActivityThreads), @(SNActivityReactions) ]
                           : @[ @(SNActivityAll), @(SNActivityMentions), @(SNActivityThreads), @(SNActivityReactions) ];
    if ([filters isEqualToArray:_tabFilters]) return;
    static NSString *const keys[] = {[SNActivityAll] = @"activity.all", [SNActivityMentions] = @"activity.mentions", [SNActivityThreads] = @"activity.threads",
                                     [SNActivityReactions] = @"activity.reactions", [SNActivityVIP] = @"activity.vip"};
    for (SNActivityTab *tab in _tabs) [tab removeFromSuperview];
    NSMutableArray *tabs = [NSMutableArray new];
    __weak SNActivityPane *weakSelf = self;
    for (NSNumber *value in filters) {
        SNActivityFilter filter = (SNActivityFilter)value.integerValue;
        SNActivityTab *tab = [[SNActivityTab alloc] initWithTitle:SNLocalized(keys[filter])];
        tab.action = ^(SNActivityTab *chosen) { weakSelf.filter = filter; };
        tab.current = filter == _filter;
        [tabs addObject:tab];
        [_view addSubview:tab];
    }
    _tabs = tabs;
    _tabFilters = filters;
    if (![filters containsObject:@(_filter)]) self.filter = SNActivityAll;
    [self resized:nil];
}

- (void)setFilter:(SNActivityFilter)filter {
    _filter = filter;
    for (NSUInteger i = 0; i < _tabs.count; i++) _tabs[i].current = _tabFilters[i].integerValue == filter;
    // The VIP tab has a feed of its own; the peek shows the whole feed.
    if (_current) _source.activityVIPOnly = filter == SNActivityVIP;
    _empty.text = SNLocalized(filter == SNActivityVIP ? @"activity.vip.empty" : @"activity.empty");
    [self showItems];
}

- (SNActivityListView *)makeListWithStyle:(SNActivityListStyle)style {
    SNActivityListView *list = [[SNActivityListView alloc] initWithStyle:style];
    __weak SNActivityPane *weakSelf = self;
    __weak id<SNSource> source = _source;
    list.chosen = ^(SNActivityListItem *item) { [weakSelf open:item.identifier]; };
    list.nearEnd = ^{ [source loadMoreActivity]; };
    __weak SNActivityListView *weakList = list;
    list.actionChosen = ^(SNActivityListItem *item, SNActivityAction action, NSRect rect) { [weakSelf perform:action on:item.identifier rect:rect inList:weakList]; };
    return list;
}

- (void)perform:(SNActivityAction)action on:(NSString *)identifier rect:(NSRect)rect inList:(SNActivityListView *)list {
    SNActivityEntry *entry = _rows[identifier].entry;
    if (!entry) return;
    switch (action) {
    case SNActivityActionMarkRead: [_source markActivityEntry:entry read:YES]; break;
    case SNActivityActionMarkUnread: [_source markActivityEntry:entry read:NO]; break;
    case SNActivityActionClear: [_source clearActivityEntry:entry]; break;
    case SNActivityActionMore: [self showMoreFor:entry rect:rect inList:list]; break;
    }
}

/// The overflow menu (ITY6, origin overflow_menu) with what this client can do: read state, Later,
/// the message's link and opening it. 300 pt wide, its right edge under the button's, 6 pt below.
- (void)showMoreFor:(SNActivityEntry *)entry rect:(NSRect)rect inList:(SNActivityListView *)list {
    id<SNSource> source = _source;
    __weak SNActivityPane *weakSelf = self;
    SNMenuItem * (^item)(NSString *, NSString *, NSString *, void (^)(void)) = ^(NSString *key, NSString *icon, NSString *shortcut, void (^action)(void)) {
        SNMenuItem *menuItem = [SNMenuItem itemWithTitle:SNLocalized(key) action:action];
        menuItem.icon = icon;
        menuItem.iconSize = 18;
        menuItem.shortcut = shortcut;
        return menuItem;
    };
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    if (entry.isUnread) [items addObject:item(@"activity.menu.read", @"mark-as-read", @"U", ^{ [source markActivityEntry:entry read:YES]; })];
    else if (entry.kind != SNActivityReaction) [items addObject:item(@"activity.menu.unread", @"mark-as-unread", @"U", ^{ [source markActivityEntry:entry read:NO]; })];
    BOOL saved = [source isMessageSavedWithTS:entry.messageTS inConversation:entry.conversationID];
    [items addObject:item(saved ? @"activity.menu.unsave" : @"activity.menu.save", saved ? @"bookmark-filled" : @"bookmark", @"A", ^{
               [source setSaved:!saved messageWithTS:entry.messageTS inConversation:entry.conversationID];
           })];
    [items addObject:SNMenuItem.separator];
    NSString *link = [NSString stringWithFormat:@"%@archives/%@/p%@", source.workspace.url.absoluteString ?: @"", entry.conversationID,
                                                [entry.messageTS stringByReplacingOccurrencesOfString:@"." withString:@""]];
    if (entry.threadTS && ![entry.threadTS isEqualToString:entry.messageTS])
        link = [link stringByAppendingFormat:@"?thread_ts=%@&cid=%@", entry.threadTS, entry.conversationID];
    [items addObject:item(@"activity.menu.link", @"link", nil, ^{
               [NSPasteboard.generalPasteboard clearContents];
               [NSPasteboard.generalPasteboard setString:link forType:NSPasteboardTypeString];
           })];
    [items addObject:SNMenuItem.separator];
    NSString *key = entry.key;
    [items addObject:item(@"activity.menu.open", @"home", nil, ^{ [weakSelf open:key]; })];
    SNMenu *menu = [[SNMenu alloc] initWithItems:items width:300];
    list.holdsHover = YES;
    // SNMenu opens 4 pt from its target; Slack's is 6 below the button, right-aligned with it.
    NSRect target = NSMakeRect(NSMaxX(rect) - 300, NSMinY(rect), 300, NSHeight(rect) + 2);
    SNPopover *popover = [menu showForRect:target inView:list placement:SNPlacementBelow];
    __weak SNActivityListView *weakList = list;
    popover.onClose = ^{ weakList.holdsHover = NO; };
    if (!popover) list.holdsHover = NO;
}

- (SNLabel *)makeEmptyLabelWithColor:(SNColorToken)color {
    SNLabel *label = [SNLabel labelWithText:SNLocalized(@"activity.empty") font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:color];
    label.alignment = NSTextAlignmentCenter;
    label.lineHeight = 22;
    label.hidden = YES;
    return label;
}

/// The switch shows and sets the source's unreads mode, which the tab and the peek share.
- (void)bindToggle:(SNUnreadsToggle *)toggle {
    toggle.on = _source.activityUnreadsOnly;
    __weak id<SNSource> source = _source;
    toggle.changed = ^(BOOL on) { source.activityUnreadsOnly = on; };
}

- (void)resized:(NSNotification *)notification {
    NSSize size = _view.bounds.size;
    _header.frame = NSMakeRect(0, 0, size.width, _header.height);
    CGFloat x = kTabsInset, top = _header.height;
    for (SNActivityTab *tab in _tabs) {
        CGFloat width = [tab fittingWidth];
        tab.frame = NSMakeRect(x, top, width, kTabsHeight);
        x += width;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tabsLine.frame = CGRectMake(0, top + kTabsHeight, size.width, 1);
    [CATransaction commit];
    top += kTabsHeight + 1;
    _list.frame = NSMakeRect(0, top, size.width, MAX(0, size.height - top));
    _empty.frame = NSMakeRect(0, top + 24, size.width, 22);
}

- (void)showLocation:(SNLocation *)location {
    BOOL current = location.tab == SNTabActivity, appeared = current && !_current, left = !current && _current;
    _current = current;
    BOOL vip = _filter == SNActivityVIP;
    // Changing the VIP mode asks for the feed itself.
    if (appeared && _source.activityVIPOnly != vip) _source.activityVIPOnly = vip;
    else if (appeared) [_source loadActivity];
    if (left) _source.activityVIPOnly = NO;
}

- (void)open:(NSString *)identifier {
    SNActivityEntry *entry = _rows[identifier].entry;
    if (!entry) return;
    // Opening an unread entry reads it (activity.markRead), as Slack's client does.
    if (entry.isUnread) [_source markActivityEntry:entry read:YES];
    if (entry.threadTS) [_navigator openThread:entry.threadTS inConversation:entry.conversationID];
    else [_navigator openConversation:entry.conversationID];
}

- (NSView *)peekView {
    [_source loadActivity];
    SNContainerView *view = [[SNContainerView alloc] initWithFrame:NSMakeRect(0, 0, SNPeekWidth, 600)];
    SNListHeader *header = [[SNListHeader alloc] initWithTitle:SNLocalized(@"activity.title") style:SNListHeaderPeek caret:NO compose:NO];
    header.frame = NSMakeRect(0, 0, SNPeekWidth, header.height);
    header.autoresizingMask = NSViewWidthSizable;
    [self bindToggle:header.unreadsToggle];
    SNActivityListView *list = [self makeListWithStyle:SNActivityListPeek];
    list.frame = NSMakeRect(0, header.height, SNPeekWidth, 600 - header.height);
    list.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // The live peek shows a spinner 18 pt under its header until the feed arrives.
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect((SNPeekWidth - 16) / 2, header.height + 18, 16, 16)];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    spinner.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    SNLabel *empty = [self makeEmptyLabelWithColor:SNColorContentSec];
    empty.frame = NSMakeRect(0, header.height + 24, SNPeekWidth, 22);
    empty.autoresizingMask = NSViewWidthSizable;
    for (NSView *subview in @[ header, list, spinner, empty ]) [view addSubview:subview];
    _peekList = list;
    _peekSpinner = spinner;
    _peekEmpty = empty;
    _peekToggle = header.unreadsToggle;
    _feedChanged = YES;
    [self update];
    return view;
}

#pragma mark Feed

/// The tab or its peek is on screen.
- (BOOL)isShowing { return _view.window || _peekList; }

- (void)sourceChanged:(SNChange *)change {
    if (change.vips) [self makeTabs];
    BOOL activity = change.activity;
    if (activity) _feedChanged = YES;
    // Another zone rewords every time and date; new custom emoji can redraw previews and reactions.
    if (change.timeZone || change.emoji) [_dirty addObjectsFromArray:_rows.allKeys];
    NSSet *messages = change.messages, *messageKeys = change.messageKeys, *threads = change.threads, *users = change.users, *conversations = change.conversations;
    if (activity || messages.count || messageKeys.count || threads.count || users.count || conversations.count)
        [_rows enumerateKeysAndObjectsUsingBlock:^(NSString *key, SNActivityRow *row, BOOL *stop) {
            SNActivityEntry *entry = row.entry;
            BOOL touched = entry.threadTS ? [threads containsObject:SNThreadKey(entry.conversationID, entry.threadTS)]
                                          : [messages containsObject:entry.conversationID];
            BOOL messageChanged = NO;
            if (!row.message) {
                messageChanged = activity || touched;
            } else if (touched || [messageKeys containsObject:SNMessageKey(row.message)]) {
                SNMessage *current = [self->_source messageForActivityEntry:entry];
                messageChanged = current != row.message;
            }
            if (messageChanged || [conversations containsObject:entry.conversationID] || [row.userIDs intersectsSet:users])
                [self->_dirty addObject:key];
        }];
    if ((_feedChanged || _dirty.count) && self.isShowing) [self update];
}

/// Makes the rows of new entries and of what changed, and shows them.
- (void)update {
    if (!_feedChanged && !_dirty.count) {
        [self showItems];
        return;
    }
    NSMutableDictionary<NSString *, SNActivityRow *> *rows = [NSMutableDictionary new];
    for (SNActivityEntry *entry in _source.activityEntries) {
        SNActivityRow *row = _rows[entry.key];
        if (!row || row.entry.isUnread != entry.isUnread || row.entry.unreadCount != entry.unreadCount ||
            ![row.entry.messageTS isEqualToString:entry.messageTS] || ![row.entry.feedTS isEqualToString:entry.feedTS] || [_dirty containsObject:entry.key])
            row = [self rowForEntry:entry];
        row.entry = entry;
        rows[entry.key] = row;
    }
    _rows = rows;
    [_dirty removeAllObjects];
    _feedChanged = NO;
    [self showItems];
}

- (void)showItems {
    _header.unreadsToggle.on = _source.activityUnreadsOnly;
    _peekToggle.on = _source.activityUnreadsOnly;
    BOOL waiting = _source.isLoadingActivity;
    if (_view.window) {
        _list.items = [self itemsWithFilter:self.filter style:SNActivityListSidebar];
        _empty.hidden = _list.items.count > 0 || waiting;
        if (_list.items.count < kFilledList && _source.activityEntries.count < kFillLimit && _source.hasMoreActivity && !waiting) [_source loadMoreActivity];
    }
    SNActivityListView *peek = _peekList;
    if (!peek) return;
    peek.items = [self itemsWithFilter:SNActivityAll style:SNActivityListPeek];
    _peekEmpty.hidden = peek.items.count > 0 || waiting;
    if (waiting && !peek.items.count) [_peekSpinner startAnimation:nil];
    else [_peekSpinner stopAnimation:nil];
}

- (NSArray<SNActivityListItem *> *)itemsWithFilter:(SNActivityFilter)filter style:(SNActivityListStyle)style {
    static const SNActivityKind kinds[] = {[SNActivityMentions] = SNActivityMention, [SNActivityThreads] = SNActivityThreadReply,
                                           [SNActivityReactions] = SNActivityReaction};
    NSMutableArray<SNActivityListItem *> *items = [NSMutableArray new];
    for (SNActivityEntry *entry in _source.activityEntries) {
        if (filter != SNActivityAll && filter != SNActivityVIP && entry.kind != kinds[filter]) continue;
        SNActivityRow *row = _rows[entry.key];
        if (!row) continue;
        SNActivityListItem *item = row.items[@(style)];
        if (!item) row.items[@(style)] = item = [self itemForRow:row style:style];
        [items addObject:item];
    }
    return items;
}

- (SNActivityRow *)rowForEntry:(SNActivityEntry *)entry {
    SNActivityRow *row = [SNActivityRow new];
    row.entry = entry;
    row.message = [_source messageForActivityEntry:entry];
    row.items = [NSMutableDictionary new];
    NSMutableSet<NSString *> *userIDs = [NSMutableSet new];
    NSString *actorID = entry.actorUserID ?: row.message.userID;
    if (actorID) [userIDs addObject:actorID];
    if (row.message) [userIDs unionSet:SNPreviewUserIDs(row.message)];
    row.userIDs = userIDs;
    return row;
}

- (SNActivityListItem *)itemForRow:(SNActivityRow *)row style:(SNActivityListStyle)style {
    SNActivityEntry *entry = row.entry;
    SNMessage *message = row.message;
    SNActivityListItem *item = [SNActivityListItem new];
    item.identifier = entry.key;
    item.unread = entry.isUnread;
    item.date = [NSDate dateWithTimeIntervalSince1970:entry.feedTS.doubleValue];
    NSString *actorID = entry.actorUserID ?: message.userID;
    SNUser *actor = actorID ? [_source userWithID:actorID] : nil;
    item.sender = actor.visibleName ?: message.username ?: @"";
    item.avatarURL = actor ? [actor avatarURLForPixels:72] : message.botIconURLs[@72] ?: message.botIconURLs.allValues.firstObject;
    BOOL reaction = entry.kind == SNActivityReaction;
    item.bodyLines = reaction ? 1 : 2;
    if (message) {
        BOOL peek = style == SNActivityListPeek;
        // ActivityMessage: the message in content-pry when unread, content-sec when read; a
        // reaction's (the user's own message) in content-ter in the peek.
        SNColorToken color = reaction ? (peek ? SNColorContentTer : SNThemeContentInvTer)
                                      : entry.isUnread ? (peek ? SNColorContentPry : SNThemeContentInvPry)
                                                       : (peek ? SNColorContentSec : SNThemeContentInvSec);
        item.body = SNPreviewDocumentWithStyle(message, _source, (SNTextStyle){SNFontSizeBase, SNFontWeightRegular, 22.5, color}, reaction);
    }
    SNConversation *conversation = [_source conversationWithID:entry.conversationID];
    NSString *place = conversation.isDirect ? SNConversationTitle(conversation, _source)
                      : conversation.name ? [@"#" stringByAppendingString:conversation.name] : nil;
    NSString *format = entry.kind == SNActivityThreadReply ? @"activity.footer.thread" : reaction ? @"activity.footer.reaction" : @"activity.footer.mention";
    item.footer = place ? SNLocalizedFormat(format, place) : nil;
    if (reaction) {
        item.reactionName = entry.reactionName;
        for (SNReaction *held in message.reactions)
            if ([held.name isEqualToString:entry.reactionName]) item.reactionCount = held.count;
    }
    if (entry.kind == SNActivityThreadReply) item.unreadReplies = entry.unreadCount;
    return item;
}

@end
