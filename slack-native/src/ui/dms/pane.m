// Owns the DMs tab: its header, filter, list and peek, kept in step with the source. Each DM's
// row is made once and again only when something it shows changed (its conversation, its
// latest message, a person it names); while neither the tab nor its peek shows, changes only
// mark the rows for later.
#import "render/strings.h"
#import "ui/dms/list.h"
#import "ui/dms/pane.h"
#import "ui/kit/container.h"
#import "ui/kit/filter.h"
#import "ui/kit/listheader.h"
#import "ui/present/names.h"
#import "ui/present/preview.h"
#import "ui/shell/tabs.h"

/// Measured on the captures: the filter 8 pt in from the column's edges under the 49 pt header,
/// the first row 5 pt below it.
static const CGFloat kFilterInset = 8, kFilterHeight = 28, kListGap = 5;

/// The pane's view, which tells the pane when it comes on screen.
@interface SNDMsPaneView : SNContainerView
@property (nonatomic, copy) void (^appeared)(void);
@end

@implementation SNDMsPaneView
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && self.appeared) self.appeared();
}
@end

/// A DM's row and what it was made from.
@interface SNDMRow : NSObject
@property (nonatomic) SNDMListItem *item;
/// The users whose names, pictures or presence the row shows, its preview's mentions included.
@property (nonatomic, copy) NSSet<NSString *> *userIDs;
/// The latest message's key and edit, which the preview was made from, and the people it names
/// (a change to one makes it again: a mention shows a user ID until its user is known).
@property (nonatomic, copy, nullable) NSString *previewKey;
@property (nonatomic, copy) NSSet<NSString *> *mentionedIDs;
/// A group DM member is not known yet: any user who arrives may be them.
@property (nonatomic) BOOL waitsForPeople;
@end

@implementation SNDMRow
@end

@interface SNDMsPane () <SNChangeObserver>
@end

@implementation SNDMsPane {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNDMsPaneView *_view;
    SNFilterField *_filter;
    NSString *_query;
    NSMutableDictionary<NSString *, SNDMRow *> *_rows;
    /// A DM's person -> the DM's conversation ID, made with the rows.
    NSDictionary<NSString *, NSString *> *_dmByUser;
    /// Rows to make again before they show (conversation IDs), or all of them.
    NSMutableSet<NSString *> *_dirty;
    NSMutableDictionary<NSString *, SNDMListItem *> *_headers;
    BOOL _allDirty, _orderChanged;
    __weak SNDMListView *_peekList;
    __weak SNUnreadsToggle *_peekToggle;
}

+ (void)load { SNRegisterTabPane(SNTabDirectMessages, self); }

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _source = source;
    _navigator = navigator;
    _rows = [NSMutableDictionary new];
    _dirty = [NSMutableSet new];
    _allDirty = YES;
    _view = [[SNDMsPaneView alloc] initWithFrame:NSMakeRect(0, 0, 516, 800)];
    _header = [[SNListHeader alloc] initWithTitle:SNLocalized(@"dms.title") style:SNListHeaderPage caret:YES compose:YES];
    __weak SNDMsPane *weakSelf = self;
    _view.appeared = ^{ [weakSelf update]; };
    _header.unreadsToggle.changed = ^(BOOL on) { [weakSelf showItems]; };
    _filter = [[SNFilterField alloc] initWithPlaceholder:SNLocalized(@"dms.filter.placeholder")];
    _filter.textChanged = ^(NSString *text) {
        SNDMsPane *pane = weakSelf;
        if (!pane) return;
        pane->_query = text;
        [pane showItems];
    };
    _list = [self makeList];
    for (NSView *view in @[ _header, _filter, _list ]) [_view addSubview:view];
    _view.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resized:) name:NSViewFrameDidChangeNotification object:_view];
    [source addChangeObserver:self];
    [self resized:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (NSView *)view { return _view; }

- (SNDMListView *)makeList {
    SNDMListView *list = [[SNDMListView alloc] initWithFrame:NSZeroRect];
    __weak id<SNNavigator> navigator = _navigator;
    list.chosen = ^(SNDMListItem *item) { [navigator openConversation:item.identifier]; };
    return list;
}

- (void)resized:(NSNotification *)notification {
    NSSize size = _view.bounds.size;
    _header.frame = NSMakeRect(0, 0, size.width, _header.height);
    _filter.frame = NSMakeRect(kFilterInset, _header.height, MAX(0, size.width - 2 * kFilterInset), kFilterHeight);
    CGFloat top = NSMaxY(_filter.frame) + kListGap;
    _list.frame = NSMakeRect(0, top, size.width, MAX(0, size.height - top));
}

- (void)showLocation:(SNLocation *)location {
    _list.selectedIdentifier = location.conversationID;
}

- (NSView *)peekView {
    SNContainerView *view = [[SNContainerView alloc] initWithFrame:NSMakeRect(0, 0, SNPeekWidth, 600)];
    SNListHeader *header = [[SNListHeader alloc] initWithTitle:SNLocalized(@"dms.title") style:SNListHeaderPeek caret:NO compose:NO];
    header.frame = NSMakeRect(0, 0, SNPeekWidth, header.height);
    header.autoresizingMask = NSViewWidthSizable;
    SNDMListView *list = [self makeList];
    list.frame = NSMakeRect(0, header.height, SNPeekWidth, 600 - header.height);
    list.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    list.selectedIdentifier = _navigator.location.conversationID;
    __weak SNDMsPane *weakSelf = self;
    header.unreadsToggle.changed = ^(BOOL on) { [weakSelf showItems]; };
    [view addSubview:header];
    [view addSubview:list];
    _peekList = list;
    _peekToggle = header.unreadsToggle;
    [self update];
    return view;
}

#pragma mark Rows

/// The tab or its peek is on screen.
- (BOOL)isShowing { return _view.window || _peekList; }

- (void)sourceChanged:(SNChange *)change {
    if (change.lists || change.vips) _orderChanged = YES;
    // Another zone rewords every date, and any <!date> in the previews.
    if (change.timeZone) {
        _allDirty = YES;
        for (SNDMRow *row in _rows.allValues) row.previewKey = nil;
    }
    for (NSSet<NSString *> *conversationIDs in @[ change.conversations ?: @[], change.counts ?: @[], change.messages ?: @[] ])
        for (NSString *conversationID in conversationIDs)
            if (_rows[conversationID]) [_dirty addObject:conversationID];
    NSSet *users = change.users, *presences = change.presence;
    if (users.count)
        [_rows enumerateKeysAndObjectsUsingBlock:^(NSString *conversationID, SNDMRow *row, BOOL *stop) {
            BOOL mentioned = [row.mentionedIDs intersectsSet:users];
            if (mentioned) row.previewKey = nil;
            if (row.waitsForPeople || mentioned || [row.userIDs intersectsSet:users]) [self->_dirty addObject:conversationID];
        }];
    for (NSString *userID in presences) {
        NSString *conversationID = _dmByUser[userID];
        if (conversationID && _rows[conversationID]) [_dirty addObject:conversationID];
    }
    if ((_orderChanged || _allDirty || _dirty.count) && self.isShowing) [self update];
}

/// Makes the rows that changed again and shows them.
- (void)update {
    if (!_orderChanged && !_allDirty && !_dirty.count) return;
    NSMutableDictionary<NSString *, SNDMRow *> *rows = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *dmByUser = [NSMutableDictionary new];
    for (SNConversation *conversation in _source.directMessages) {
        NSString *conversationID = conversation.conversationID;
        if (conversation.kind == SNConversationDirect && conversation.userID) dmByUser[conversation.userID] = conversationID;
        SNDMRow *row = _rows[conversationID];
        if (!row || _allDirty || [_dirty containsObject:conversationID]) row = [self rowForConversation:conversation previous:row];
        rows[conversationID] = row;
    }
    _rows = rows;
    _dmByUser = dmByUser;
    [_dirty removeAllObjects];
    _allDirty = _orderChanged = NO;
    [self showItems];
}

- (void)showItems {
    if (!self.isShowing) return;
    if (_view.window) _list.items = [self itemsUnreadOnly:_header.unreadsToggle.on query:_query headers:YES];
    _peekList.items = [self itemsUnreadOnly:_peekToggle.on query:nil headers:NO];
}

/// The DMs newest first; where the plan offers VIPs, the unread ones with a VIP float to the top
/// under "VIP unreads", the rest under "Everything else" (headers left out of the peek).
- (NSArray<SNDMListItem *> *)itemsUnreadOnly:(BOOL)unreadOnly query:(NSString *)query headers:(BOOL)headers {
    NSMutableArray *vips = [NSMutableArray new], *items = [NSMutableArray new];
    NSSet *vipIDs = _source.offersVIPs ? [NSSet setWithArray:_source.vipUserIDs] : [NSSet set];
    for (SNConversation *conversation in _source.directMessages) {
        SNDMRow *row = _rows[conversation.conversationID];
        SNDMListItem *item = row.item;
        if (!item || (unreadOnly && !item.unread) || (query.length && ![item.title localizedStandardContainsString:query])) continue;
        [item.unread && [row.userIDs intersectsSet:vipIDs] ? vips : items addObject:item];
    }
    if (!vips.count) return items;
    if (!headers) return [vips arrayByAddingObjectsFromArray:items];
    [vips insertObject:[self header:@"dms.vip" rule:YES] atIndex:0];
    [vips addObject:[self header:@"dms.everything" rule:NO]];
    return [vips arrayByAddingObjectsFromArray:items];
}

/// Kept per pane so the list reuses their rows while language reloads refresh their titles.
- (SNDMListItem *)header:(NSString *)key rule:(BOOL)rule {
    if (!_headers) _headers = [NSMutableDictionary new];
    SNDMListItem *item = _headers[key];
    if (!item) {
        item = _headers[key] = [SNDMListItem new];
        item.identifier = [@"header:" stringByAppendingString:key];
        item.header = YES;
        item.rule = rule;
    }
    item.title = SNLocalized(key);
    return item;
}

- (SNDMRow *)rowForConversation:(SNConversation *)conversation previous:(SNDMRow *)previous {
    SNDMRow *row = [SNDMRow new];
    SNDMListItem *item = [SNDMListItem new];
    item.identifier = conversation.conversationID;
    item.title = SNConversationTitle(conversation, _source);
    item.unread = conversation.hasUnreads && !conversation.isMuted;
    NSMutableSet<NSString *> *userIDs = [NSMutableSet new];
    NSArray<SNUser *> *people = SNConversationPeople(conversation, _source);
    for (SNUser *person in people) [userIDs addObject:person.userID];
    row.waitsForPeople = conversation.kind == SNConversationGroupDirect && people.count < SNGroupDMHandles(conversation, _source).count;
    if (conversation.userID) [userIDs addObject:conversation.userID];
    if (conversation.kind == SNConversationDirect) {
        SNUser *user = conversation.userID ? [_source userWithID:conversation.userID] : nil;
        item.avatarURL = [user avatarURLForPixels:72];
        item.presence = SNAvatarPresenceOfUser(user, _source);
        item.doNotDisturb = conversation.userID && [_source doNotDisturbOfUser:conversation.userID];
    }
    SNMessage *latest = [_source latestMessageInConversation:conversation.conversationID];
    if (latest) {
        // The preview is kept while its message and the people it names stay the same.
        row.previewKey = [SNMessageKey(latest) stringByAppendingString:latest.editedTS ?: @""];
        row.mentionedIDs = SNPreviewUserIDs(latest);
        item.preview = [row.previewKey isEqualToString:previous.previewKey] && previous.item.preview ? previous.item.preview : SNPreviewDocument(latest, _source);
    }
    NSString *ts = latest.ts ?: conversation.latest;
    if (ts.doubleValue > 0) item.date = [NSDate dateWithTimeIntervalSince1970:ts.doubleValue];
    row.item = item;
    row.userIDs = userIDs;
    return row;
}

@end
