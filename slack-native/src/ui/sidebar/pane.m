// Owns what the Home sidebar lists and keeping it current: the entries are rebuilt from the
// source's sections only when what is listed can have changed (the lists, a collapsed section's
// unreads, a name that orders a section); otherwise only the rows of what changed are drawn
// again. While neither the sidebar nor a Home peek shows, changes only mark it for a rebuild. Each
// list (the sidebar's, a peek's) is filtered by its own header's field.
#import "render/strings.h"
#import "ui/huddle/footer.h"
#import "ui/huddle/huddle.h"
#import "ui/kit/container.h"
#import "ui/present/names.h"
#import "ui/shell/workspacemenu.h"
#import "ui/sidebar/pane.h"

/// Measured live: 6 pt above the first link, sections 10 pt apart, the divider under the links
/// 24 pt with its line in the middle, and the empty Favoritos hint keeps 16 pt of drop space
/// under its line.
static const CGFloat kListInset = 6, kSectionGap = 10, kDividerHeight = 24, kHintHeight = 44, kPeekHeight = 600;
/// Slack filters once the text has not changed for 150 ms; its no-results entry is 130 px.
static const NSTimeInterval kFilterSettle = 0.15;
static const CGFloat kNoResultsHeight = 130;


/// What Slack's filter compares: lowercased, without hyphens and spaces.
static NSString *FilterKey(NSString *text) {
    return [[text.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""] stringByReplacingOccurrencesOfString:@" "
                                                                                                                   withString:@""];
}

/// A section the sidebar lists and all its conversations, the ones it hides included.
@interface SNSidebarSectionEntry : NSObject
@property (nonatomic) SNSection *section;
@property (nonatomic, copy) NSArray<SNConversation *> *conversations;
@end

@implementation SNSidebarSectionEntry
@end

@interface SNSidebarPaneView : NSView
@property (nonatomic, weak) SNSidebarPane *pane;
@end

@interface SNSidebarPane () <SNSidebarListDelegate, SNChangeObserver>
- (void)layout;
- (void)appeared;
@end

@implementation SNSidebarPaneView
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    [self.pane layout];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self.pane appeared];
}
@end

@implementation SNSidebarPane {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNSidebarPaneView *_view;
    NSView *_scrolledLine;
    SNHuddleSidebarFooter *_huddleFooter;
    /// Every list on screen (the sidebar's, and the Home peeks' while they are open) with its
    /// header, and the text its filter field last filtered it by (trimmed; empty for none).
    NSMapTable<SNSidebarListView *, SNSidebarHeaderView *> *_headers;
    NSMapTable<SNSidebarListView *, NSString *> *_queries;
    /// The entries without a filter, and the sections they come from.
    NSArray<SNSidebarItem *> *_items;
    NSArray<SNSidebarSectionEntry *> *_sections;
    NSString *_selectedID;
    /// conversation ID -> its rows' keys; user ID -> the keys of their DMs (shown or not).
    NSDictionary<NSString *, NSArray<NSString *> *> *_keysByConversation, *_keysByUser;
    /// What makes the entries change: the conversations of collapsed sections (they show while
    /// unread or open) and the people whose names order a section.
    NSSet<NSString *> *_collapsedIDs, *_orderingUserIDs;
    /// Group DMs with a member not known yet: their rows follow any users change.
    NSSet<NSString *> *_waitingIDs;
    /// Something changed while nothing showed; the next showing rebuilds.
    BOOL _stale;
    /// The user's call's conversation as last drawn.
    NSSet<NSString *> *_callConversations;
}

+ (void)load { SNRegisterPane(SNPaneSlotSidebar, self); }

+ (NSString *)keyForConversation:(NSString *)conversationID inSection:(NSString *)sectionID {
    return [NSString stringWithFormat:@"%@/%@", sectionID, conversationID];
}

+ (NSString *)keyForSection:(NSString *)sectionID { return [@"section:" stringByAppendingString:sectionID]; }

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _source = source;
    _navigator = navigator;
    _view = [[SNSidebarPaneView alloc] initWithFrame:NSZeroRect];
    _view.pane = self;
    _headers = [NSMapTable weakToWeakObjectsMapTable];
    _queries = [NSMapTable weakToStrongObjectsMapTable];
    _list = [[SNSidebarListView alloc] initWithFrame:NSZeroRect];
    _list.topInset = kListInset;
    _list.delegate = self;
    _header = [self makeHeaderForList:_list];
    [_view addSubview:_list];
    [_view addSubview:_header];
    // components.json sidebar_header: a 0 1px 0 rgba(232,232,232,0.13) line once the list scrolls.
    _scrolledLine = [[NSView alloc] initWithFrame:NSZeroRect];
    _scrolledLine.wantsLayer = YES;
    _scrolledLine.layer.backgroundColor = SNCGColor(SNLegacyHairline);
    _scrolledLine.hidden = YES;
    [_view addSubview:_scrolledLine];
    _huddleFooter = [[SNHuddleSidebarFooter alloc] initWithSource:source];
    __weak SNSidebarPane *weakPane = self;
    _huddleFooter.heightChanged = ^{ [weakPane layout]; };
    [_view addSubview:_huddleFooter];
    [self layout];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(listScrolled) name:NSViewBoundsDidChangeNotification object:_list.scrollView.contentView];
    [source addChangeObserver:self];
    [self reload];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (SNSidebarHeaderView *)makeHeaderForList:(SNSidebarListView *)list {
    SNSidebarHeaderView *header = [[SNSidebarHeaderView alloc] initWithFrame:NSZeroRect];
    header.workspaceName = _source.workspace.name;
    [_headers setObject:header forKey:list];
    __weak SNSidebarPane *weakSelf = self;
    __weak SNSidebarListView *weakList = list;
    // Typing filters once the text settles; the clear button and Escape filter at once.
    header.filterField.textChanged = ^(NSString *text) { [weakSelf filterSoon:weakList]; };
    header.filterField.cleared = ^{ [weakSelf filter:weakList]; };
    header.filterField.downPressed = ^{ [weakList focusFirstItem]; };
    __weak SNSidebarHeaderView *weakHeader = header;
    id<SNSource> source = _source;
    header.titleButton.action = ^(SNHoverView *button) {
        // Measured: the menu's box starts 12 pt left of the column and 50 pt under its top
        // (the popover adds 4 pt below the rect).
        [SNWorkspaceMenu showForRect:NSMakeRect(-12, 0, NSMaxX(button.frame) + 12, 46) inView:weakHeader placement:SNPlacementBelow source:source];
        // Live, the title shows no fill while its menu is open (the CSS keeps it).
        button.hovered = NO;
    };
    return header;
}

/// The Home tab's peek: the same header and list in the rail's peek card, 600 pt tall like the
/// DMs peek.
- (NSView *)peekView {
    if (_stale) [self reload];
    SNContainerView *view = [[SNContainerView alloc] initWithFrame:NSMakeRect(0, 0, SNPeekWidth, kPeekHeight)];
    SNSidebarListView *list = [[SNSidebarListView alloc] initWithFrame:NSMakeRect(0, SNSidebarHeaderHeight, SNPeekWidth, kPeekHeight - SNSidebarHeaderHeight)];
    list.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    list.topInset = kListInset;
    list.delegate = self;
    [list showItems:_items];
    SNSidebarHeaderView *header = [self makeHeaderForList:list];
    header.frame = NSMakeRect(0, 0, SNPeekWidth, SNSidebarHeaderHeight);
    header.autoresizingMask = NSViewWidthSizable;
    [view addSubview:list];
    [view addSubview:header];
    return view;
}

- (NSView *)view { return _view; }

- (void)layout {
    NSRect bounds = _view.bounds;
    _header.frame = NSMakeRect(0, 0, bounds.size.width, SNSidebarHeaderHeight);
    _huddleFooter.frame = NSMakeRect(0, bounds.size.height, bounds.size.width, 0);
    CGFloat footer = _huddleFooter.preferredHeight;
    _huddleFooter.frame = NSMakeRect(0, bounds.size.height - footer, bounds.size.width, footer);
    _list.frame = NSMakeRect(0, SNSidebarHeaderHeight, bounds.size.width, MAX(0, bounds.size.height - SNSidebarHeaderHeight - footer));
    _scrolledLine.frame = NSMakeRect(0, SNSidebarHeaderHeight, bounds.size.width, 1);
}

- (void)listScrolled { _scrolledLine.hidden = _list.scrollView.contentView.bounds.origin.y <= 0; }

- (void)showLocation:(SNLocation *)location {
    // Slack's Home sidebar starts afresh when another tab replaces it.
    if (location.tab != SNTabHome) [self clearFilterOf:_list];
    NSString *selected = location.conversationID;
    if (selected == _selectedID || [selected isEqualToString:_selectedID]) return;
    NSMutableSet *changed = [NSMutableSet new];
    if (_selectedID) [changed addObject:_selectedID];
    if (selected) [changed addObject:selected];
    _selectedID = [selected copy];
    // A collapsed section shows its open conversation.
    [self changedConversations:changed users:nil structure:[changed intersectsSet:_collapsedIDs] threads:NO];
    if (!self.isShowing) return;
    for (NSString *key in _keysByConversation[selected ?: @""])
        if ([_list itemForKey:key]) return [_list revealKey:key];
}

/// The lists on screen: the sidebar's and the open Home peeks'.
- (NSArray<SNSidebarListView *> *)lists { return _headers.keyEnumerator.allObjects; }

/// The sidebar or a Home peek is on screen.
- (BOOL)isShowing { return _view.window || self.lists.count > 1; }

- (void)appeared {
    if (_stale) [self reload];
}

#pragma mark Entries

- (SNSidebarItem *)item:(SNSidebarItemKind)kind key:(NSString *)key height:(CGFloat)height {
    SNSidebarItem *item = [SNSidebarItem new];
    item.kind = kind;
    item.key = key;
    item.height = height;
    return item;
}

- (NSArray<SNSidebarItem *> *)buildItems {
    NSMutableArray<SNSidebarItem *> *items = [NSMutableArray new];
    NSString *behavior = SNPreferenceString(_source.preferences, @"sidebar_behavior") ?: @"";
    for (SNSidebarPage page = SNSidebarPageThreads; page <= SNSidebarPageDirectories; page++) {
        SNSidebarItem *item = [self item:SNSidebarItemPage key:[NSString stringWithFormat:@"page:%ld", (long)page] height:SNSpace7];
        item.page = page;
        [items addObject:item];
    }
    [items addObject:[self item:SNSidebarItemDivider key:@"divider" height:kDividerHeight]];

    NSArray<SNSection *> *sections = _source.sections;
    NSMutableSet<NSString *> *collapsed = [NSMutableSet new], *ordering = [NSMutableSet new], *waiting = [NSMutableSet new];
    // Channels and DMs in no other section fall into the built-in ones, as in Slack.
    NSMutableSet<NSString *> *placed = [NSMutableSet new];
    for (SNSection *section in sections)
        if (![section.type isEqualToString:SNSectionChannels] && ![section.type isEqualToString:SNSectionDirectMessages])
            [placed addObjectsFromArray:section.conversationIDs];

    NSMutableArray<SNSidebarSectionEntry *> *entries = [NSMutableArray new];
    BOOL first = YES;
    for (SNSection *section in sections) {
        NSString *sectionID = section.sectionID;
        NSArray<SNConversation *> *conversations = [self conversationsInSection:section placed:placed];
        // Slack's own sections (Slack Connect, Salesforce, temporary channels, apps...) show only
        // with something in them; Starred, Channels, DMs and the user's sections always show.
        BOOL builtIn = ![section.type isEqualToString:SNSectionStarred] && ![section.type isEqualToString:SNSectionChannels] &&
                       ![section.type isEqualToString:SNSectionDirectMessages] && ![section.type isEqualToString:SNSectionCustom];
        if (builtIn && !conversations.count) continue;
        SNSidebarSectionEntry *entry = [SNSidebarSectionEntry new];
        entry.section = section;
        entry.conversations = conversations;
        [entries addObject:entry];
        if (!first) [items addObject:[self item:SNSidebarItemGap key:[@"gap:" stringByAppendingString:sectionID] height:kSectionGap]];
        first = NO;
        if (section.isCollapsed) [collapsed addObjectsFromArray:[conversations valueForKey:@"conversationID"]];
        for (SNConversation *conversation in conversations) {
            if (conversation.kind != SNConversationGroupDirect && ![self sortsByTitle:section]) continue;
            NSArray<SNUser *> *people = SNConversationPeople(conversation, _source);
            if ([self sortsByTitle:section])
                for (SNUser *person in people) [ordering addObject:person.userID];
            if (conversation.kind == SNConversationGroupDirect && people.count < SNGroupDMHandles(conversation, _source).count)
                [waiting addObject:conversation.conversationID];
        }
        SNSidebarItem *heading = [self item:SNSidebarItemHeading key:[SNSidebarPane keyForSection:sectionID] height:SNSpace7];
        heading.section = section;
        heading.sectionConversationIDs = [conversations valueForKey:@"conversationID"];
        [items addObject:heading];
        for (SNConversation *conversation in conversations) {
            // A collapsed section still shows what is unread and the open conversation; so does
            // the Preferences' "Show…" when it is not "All your conversations".
            BOOL unread = conversation.hasUnreads && !conversation.isMuted;
            BOOL filtered = [behavior isEqualToString:@"show_mentions_only"] ? conversation.mentionCount > 0 || (conversation.isDirect && unread)
                          : [behavior isEqualToString:@"hide_read_channels"] ||
                                    ([behavior isEqualToString:@"hide_read_channels_unless_starred"] && ![section.type isEqualToString:SNSectionStarred])
                              ? unread
                              : YES;
            BOOL shown = [conversation.conversationID isEqualToString:_selectedID] || (filtered && (!section.isCollapsed || unread));
            if (!shown) continue;
            SNSidebarItem *item = [self item:SNSidebarItemConversation
                                         key:[SNSidebarPane keyForConversation:conversation.conversationID inSection:sectionID]
                                      height:SNSpace7];
            item.section = section;
            item.conversationID = conversation.conversationID;
            [items addObject:item];
        }
        if (section.isCollapsed) continue;
        if ([section.type isEqualToString:SNSectionStarred] && !conversations.count) {
            SNSidebarItem *hint = [self item:SNSidebarItemHint key:[@"hint:" stringByAppendingString:sectionID] height:kHintHeight];
            hint.section = section;
            [items addObject:hint];
        }
        if ([section.type isEqualToString:SNSectionChannels]) {
            SNSidebarItem *add = [self item:SNSidebarItemAdd key:[@"add:" stringByAppendingString:sectionID] height:SNSpace7];
            add.section = section;
            [items addObject:add];
        }
    }
    _collapsedIDs = collapsed;
    _orderingUserIDs = ordering;
    _waitingIDs = waiting;
    _sections = entries;
    return items;
}

#pragma mark Filter

/// What the filter shows for `query` (trimmed, not empty): each section with a match, open, with
/// only its matches in the sidebar's order (Slack's sidebar_text_filter; the closed-DMs and fuzzy
/// variants are other experiments).
- (NSArray<SNSidebarItem *> *)itemsMatching:(NSString *)query {
    NSString *needle = FilterKey(query);
    NSMutableArray<SNSidebarItem *> *items = [NSMutableArray new];
    for (SNSidebarSectionEntry *entry in _sections) {
        NSString *sectionID = entry.section.sectionID;
        NSMutableArray<SNConversation *> *matches = [NSMutableArray new];
        for (SNConversation *conversation in entry.conversations) {
            NSString *name = [self filterNameOf:conversation];
            // Like JavaScript's includes, an empty needle (the text was only hyphens) matches.
            if (name && (!needle.length || [FilterKey(name) containsString:needle])) [matches addObject:conversation];
        }
        if (!matches.count) continue;
        if (items.count) [items addObject:[self item:SNSidebarItemGap key:[@"gap:" stringByAppendingString:sectionID] height:kSectionGap]];
        SNSidebarItem *heading = [self item:SNSidebarItemHeading key:[SNSidebarPane keyForSection:sectionID] height:SNSpace7];
        heading.section = entry.section;
        heading.sectionConversationIDs = [matches valueForKey:@"conversationID"];
        heading.filtered = YES;
        [items addObject:heading];
        for (SNConversation *conversation in matches) {
            SNSidebarItem *item = [self item:SNSidebarItemConversation key:[SNSidebarPane keyForConversation:conversation.conversationID inSection:sectionID]
                                      height:SNSpace7];
            item.section = entry.section;
            item.conversationID = conversation.conversationID;
            item.filtered = YES;
            [items addObject:item];
        }
    }
    if (!items.count) [items addObject:[self item:SNSidebarItemNoResults key:@"noResults" height:kNoResultsHeight]];
    return items;
}

/// The name Slack's filter matches a conversation by: a channel's, the DM person's, a group DM's
/// other members' sorted and joined by commas; nil while unknown.
- (NSString *)filterNameOf:(SNConversation *)conversation {
    if (conversation.kind == SNConversationDirect) return [_source userWithID:conversation.userID ?: @""].visibleName;
    if (conversation.kind != SNConversationGroupDirect) return conversation.name;
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (SNUser *person in SNConversationPeople(conversation, _source))
        if (person.visibleName.length) [names addObject:person.visibleName];
    [names sortUsingSelector:@selector(localizedCompare:)];
    return names.count ? [names componentsJoinedByString:@","] : nil;
}

- (NSArray<SNSidebarItem *> *)itemsForList:(SNSidebarListView *)list {
    NSString *query = [_queries objectForKey:list];
    return query.length ? [self itemsMatching:query] : _items;
}

- (BOOL)isFiltering {
    for (SNSidebarListView *list in self.lists)
        if ([_queries objectForKey:list].length) return YES;
    return NO;
}

- (void)filterSoon:(SNSidebarListView *)list {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(filter:) object:list];
    [self performSelector:@selector(filter:) withObject:list afterDelay:kFilterSettle];
}

/// Filters `list` by what its field holds now.
- (void)filter:(SNSidebarListView *)list {
    if (!list) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(filter:) object:list];
    NSString *query = [[_headers objectForKey:list].filterField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([query isEqualToString:[_queries objectForKey:list] ?: @""]) return;
    [_queries setObject:query forKey:list];
    if (_stale) [self reload];
    else [list showItems:[self itemsForList:list]];
    [list.scrollView.contentView scrollToPoint:NSZeroPoint];
    [list.scrollView reflectScrolledClipView:list.scrollView.contentView];
}

- (void)clearFilterOf:(SNSidebarListView *)list {
    [_headers objectForKey:list].filterField.text = @"";
    [self filter:list];
}

- (void)resetFilters {
    for (SNSidebarListView *list in self.lists) [self clearFilterOf:list];
}

- (BOOL)sortsByTitle:(SNSection *)section {
    return ![section.type isEqualToString:SNSectionStarred] && ![section.type isEqualToString:SNSectionDirectMessages];
}

- (NSArray<SNConversation *> *)conversationsInSection:(SNSection *)section placed:(NSSet<NSString *> *)placed {
    NSMutableArray<SNConversation *> *list = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    void (^add)(SNConversation *) = ^(SNConversation *conversation) {
        if (!conversation || conversation.isArchived || [seen containsObject:conversation.conversationID]) return;
        if (conversation.isDirect ? !conversation.isOpen : !conversation.isMember) return;
        [seen addObject:conversation.conversationID];
        [list addObject:conversation];
    };
    for (NSString *conversationID in section.conversationIDs) add([_source conversationWithID:conversationID]);
    if ([section.type isEqualToString:SNSectionDirectMessages]) {
        // Newest activity first, as the source orders them.
        for (SNConversation *conversation in _source.directMessages)
            if (![placed containsObject:conversation.conversationID]) add(conversation);
        NSDictionary *order = [self orderOf:_source.directMessages];
        [list sortUsingComparator:^NSComparisonResult(SNConversation *a, SNConversation *b) {
            return [order[a.conversationID] ?: @(NSIntegerMax) compare:order[b.conversationID] ?: @(NSIntegerMax)];
        }];
        return list;
    }
    if ([section.type isEqualToString:SNSectionChannels])
        for (SNConversation *conversation in _source.memberChannels)
            if (![placed containsObject:conversation.conversationID]) add(conversation);
    if ([self sortsByTitle:section]) {
        NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary dictionaryWithCapacity:list.count];
        for (SNConversation *conversation in list) titles[conversation.conversationID] = SNConversationTitle(conversation, _source);
        [list sortUsingComparator:^NSComparisonResult(SNConversation *a, SNConversation *b) {
            return [titles[a.conversationID] localizedStandardCompare:titles[b.conversationID]];
        }];
    }
    return list;
}

- (NSDictionary<NSString *, NSNumber *> *)orderOf:(NSArray<SNConversation *> *)conversations {
    NSMutableDictionary *order = [NSMutableDictionary dictionaryWithCapacity:conversations.count];
    [conversations enumerateObjectsUsingBlock:^(SNConversation *conversation, NSUInteger index, BOOL *stop) {
        order[conversation.conversationID] = @(index);
    }];
    return order;
}

- (void)reload {
    _stale = NO;
    _items = [self buildItems];
    // Every row a conversation can have, so a filter's rows (some hidden without it) follow too.
    NSMutableDictionary<NSString *, NSMutableArray *> *byConversation = [NSMutableDictionary new], *byUser = [NSMutableDictionary new];
    for (SNSidebarSectionEntry *entry in _sections) {
        for (SNConversation *conversation in entry.conversations) {
            NSString *key = [SNSidebarPane keyForConversation:conversation.conversationID inSection:entry.section.sectionID];
            NSMutableArray *forConversation = byConversation[conversation.conversationID] ?: (byConversation[conversation.conversationID] = [NSMutableArray new]);
            [forConversation addObject:key];
            if (conversation.userID) {
                NSMutableArray *forUser = byUser[conversation.userID] ?: (byUser[conversation.userID] = [NSMutableArray new]);
                [forUser addObject:key];
            }
        }
    }
    _keysByConversation = byConversation;
    _keysByUser = byUser;
    for (SNSidebarListView *list in self.lists) [list showItems:[self itemsForList:list]];
}

/// Rebuilds when the entries may have changed (`structure`), else redraws only the rows of these
/// conversations and users, their sections' headings and the Threads link.
- (void)changedConversations:(NSSet<NSString *> *)conversationIDs users:(NSSet<NSString *> *)userIDs structure:(BOOL)structure threads:(BOOL)threads {
    if (!self.isShowing) {
        _stale = YES;
        return;
    }
    if (structure) return [self reload];
    // A collapsed heading turns bold with its unreads, so it follows its rows.
    NSMutableSet<NSString *> *keys = [NSMutableSet new];
    if (threads) [keys addObject:[NSString stringWithFormat:@"page:%ld", (long)SNSidebarPageThreads]];
    for (NSString *conversationID in conversationIDs) {
        for (NSString *key in _keysByConversation[conversationID]) {
            [keys addObject:key];
            [keys addObject:[SNSidebarPane keyForSection:[key componentsSeparatedByString:@"/"].firstObject]];
        }
    }
    for (NSString *userID in userIDs) [keys addObjectsFromArray:_keysByUser[userID]];
    for (SNSidebarListView *list in self.lists) [list refreshKeys:keys];
}

- (void)sourceChanged:(SNChange *)change {
    NSMutableSet<NSString *> *conversations = [NSMutableSet new];
    for (NSSet<NSString *> *identifiers in @[ change.conversations ?: @[], change.counts ?: @[], change.drafts ?: @[] ])
        for (NSString *identifier in identifiers)
            // Drafts in threads do not mark the conversation.
            if (![identifier containsString:@"/"]) [conversations addObject:identifier];
    NSSet *users = change.users;
    // Redraw-only user changes (presence, huddles, custom status emoji) refresh DM rows in place
    // without forcing a full O(N) structural sidebar rebuild.
    NSMutableSet<NSString *> *redrawUsers = [NSMutableSet new];
    if (change.huddles) {
        [conversations unionSet:change.huddles];
        [redrawUsers addObjectsFromArray:_keysByUser.allKeys];
    }
    if (change.emoji) [redrawUsers addObjectsFromArray:_keysByUser.allKeys];
    // The user's call turns their own huddle's badge.
    if (change.call) {
        [conversations unionSet:_callConversations];
        _callConversations = _source.call ? [NSSet setWithObject:_source.call.conversationID] : [NSSet set];
        [conversations unionSet:_callConversations];
    }
    BOOL threads = change.counts != nil, lists = change.lists || change.preferences;
    NSSet *presences = change.presence;
    if (presences.count) [redrawUsers unionSet:presences];
    if (!lists && !threads && !conversations.count && !users.count && !redrawUsers.count) return;
    // The source reports joins, leaves, renames and order as lists; archiving comes as a change.
    // While the sidebar shows unreads or mentions only, a count can add or remove a row.
    BOOL filtering = SNPreferenceString(_source.preferences, @"sidebar_behavior").length > 0;
    BOOL structure = lists || [conversations intersectsSet:_collapsedIDs] || [users intersectsSet:_orderingUserIDs] || (filtering && (threads || conversations.count));
    // A person's new name can make a filtered list find their DMs, or no longer.
    if (users.count && self.isFiltering) structure = YES;
    for (NSString *conversationID in change.conversations)
        if (_keysByConversation[conversationID] && [_source conversationWithID:conversationID].isArchived) structure = YES;
    if (users.count) [conversations unionSet:_waitingIDs];
    if (redrawUsers.count) users = users ? [users setByAddingObjectsFromSet:redrawUsers] : redrawUsers;
    [self changedConversations:conversations users:users structure:structure threads:threads];
}

#pragma mark Row state

- (SNSidebarRowState *)sidebarList:(SNSidebarListView *)list stateForItem:(SNSidebarItem *)item {
    SNSidebarRowState *state = [SNSidebarRowState new];
    state.title = @"";
    switch (item.kind) {
    case SNSidebarItemPage: {
        static NSString *const keys[] = {@"sidebar.page.threads", @"sidebar.page.huddles", @"sidebar.page.drafts", @"sidebar.page.directories"};
        static NSString *const icons[] = {@"threads", @"headphones", @"send", @"user-directory"};
        state.title = SNLocalized(keys[item.page]);
        state.icon = icons[item.page];
        if (item.page == SNSidebarPageThreads) {
            state.unread = _source.hasUnreadThreads;
            state.mentions = _source.threadMentionCount;
        }
        break;
    }
    case SNSidebarItemHeading: {
        SNSection *section = item.section;
        state.title = section.name.length ? section.name : [self builtInName:section.type];
        state.icon = [self iconForSection:section.type];
        state.collapsed = section.isCollapsed && !item.filtered;
        for (NSString *conversationID in state.collapsed ? item.sectionConversationIDs : @[]) {
            SNConversation *conversation = [_source conversationWithID:conversationID];
            if (conversation.hasUnreads && !conversation.isMuted) state.unread = YES;
        }
        break;
    }
    case SNSidebarItemHint: state.title = SNLocalized(@"sidebar.stars.hint"); break;
    case SNSidebarItemAdd:
        state.title = SNLocalized(@"sidebar.add.channels");
        break;
    case SNSidebarItemNoResults:
        state.title = SNLocalized(@"sidebar.filter.empty");
        state.buttonTitle = SNLocalizedFormat(@"sidebar.filter.search", _source.workspace.name ?: @"");
        break;
    case SNSidebarItemConversation: {
        SNConversation *conversation = [_source conversationWithID:item.conversationID];
        state.title = SNConversationTitle(conversation, _source);
        state.selected = [item.conversationID isEqualToString:_selectedID];
        state.muted = conversation.isMuted;
        state.unread = conversation.hasUnreads;
        state.mentions = conversation.isMuted ? 0 : conversation.mentionCount;
        state.draft = [_source draftInConversation:item.conversationID threadTS:nil].length > 0;
        SNHuddle *huddle = SNActiveHuddle(_source, item.conversationID);
        state.huddleCount = (NSInteger)huddle.participantIDs.count;
        state.huddleFaces = huddle ? SNFacepileUsers(SNFacepileUserIDs(huddle, 2), _source) : nil;
        state.myHuddle = huddle && SNInCallInConversation(_source, item.conversationID);
        switch (conversation.kind) {
        case SNConversationChannel: state.icon = conversation.hasUnreads && !conversation.isMuted ? @"channel-filled" : @"channel"; break;
        case SNConversationPrivateChannel: state.icon = @"lock"; break;
        case SNConversationDirect:
            state.user = [_source userWithID:conversation.userID ?: @""];
            state.presence = SNAvatarPresenceOfUser(state.user, _source);
            state.doNotDisturb = conversation.userID && [_source doNotDisturbOfUser:conversation.userID];
            state.userInHuddle = conversation.userID && [_source isUserInHuddle:conversation.userID];
            break;
        case SNConversationGroupDirect: state.memberCount = (NSInteger)SNGroupDMHandles(conversation, _source).count; break;
        }
        break;
    }
    default: break;
    }
    return state;
}

- (NSString *)builtInName:(SNSectionType)type {
    if ([type isEqualToString:SNSectionStarred]) return SNLocalized(@"sidebar.section.stars");
    if ([type isEqualToString:SNSectionChannels]) return SNLocalized(@"sidebar.section.channels");
    if ([type isEqualToString:SNSectionDirectMessages]) return SNLocalized(@"sidebar.section.dms");
    if ([type isEqualToString:SNSectionApps]) return SNLocalized(@"sidebar.section.apps");
    if ([type isEqualToString:SNSectionSlackConnect]) return SNLocalized(@"sidebar.section.connect");
    return @"";
}

- (NSString *)iconForSection:(SNSectionType)type {
    if ([type isEqualToString:SNSectionStarred]) return @"star";
    if ([type isEqualToString:SNSectionChannels]) return @"channel-section";
    if ([type isEqualToString:SNSectionDirectMessages]) return @"direct-messages";
    if ([type isEqualToString:SNSectionApps]) return @"apps";
    if ([type isEqualToString:SNSectionSlackConnect]) return @"buildings";
    return @"section";
}

#pragma mark Actions

- (void)sidebarRowClicked:(SNSidebarRowView *)row {
    SNSidebarItem *item = row.item;
    if (item.kind == SNSidebarItemConversation) {
        [_navigator openConversation:item.conversationID];
    } else if (item.kind == SNSidebarItemHeading) {
        SNSection *section = item.section;
        // The caret turns at once; the rows follow in the same frame when the source answers.
        // While filtering, Slack keeps the section open and only saves the choice.
        if (!item.filtered) [row setCollapsed:!section.isCollapsed animated:YES];
        [_source setSection:section.sectionID collapsed:!section.isCollapsed];
    }
}

- (void)sidebarRow:(SNSidebarRowView *)row action:(NSString *)action fromView:(NSView *)view {
    // Adding to and filtering a section and the section menu are not captured yet.
    if ([action isEqualToString:@"close"] && row.item.conversationID) [_source closeConversation:row.item.conversationID];
    if ([action isEqualToString:@"search"]) {
        // Nothing found: Slack searches the workspace for the text and empties the filter.
        for (SNSidebarListView *list in self.lists) {
            if (![row isDescendantOf:list]) continue;
            NSString *query = [_queries objectForKey:list];
            [_navigator openSearchWithQuery:query];
            [self clearFilterOf:list];
        }
    }
}

- (void)sidebarListShiftTabbed:(SNSidebarListView *)list { [[_headers objectForKey:list].filterField focus]; }

@end
