// Owns composing the window, the panes and navigation.
#import "render/images.h"
#import "render/strings.h"
#import "ui/kit/popover.h"
#import "ui/present/names.h"
#import "ui/shell/background.h"
#import "ui/shell/search.h"
#import "ui/shell/shell.h"
#import "ui/shell/tabs.h"
#import "ui/shell/workspacemenu.h"
#import "ui/shell/youmenu.h"

static NSString *const kSidebarWidthKey = @"SNSidebarWidth", *const kSecondaryWidthKey = @"SNSecondaryWidth";
static NSString *const kLocationKey = @"SNLocation";
/// The sidebar's width in the reference captures, until the user drags it.
static const CGFloat kDefaultSidebarWidth = 516;
/// The thread column's width before the user drags it, measured live at the default window size.
static const CGFloat kDefaultSecondaryWidth = 393;

/// The window's content: lays the background, top bar, rail and card out by Slack's grid.
@interface SNShellView : NSView
@property (nonatomic) NSView *background, *topBar, *rail, *card;
@end

@implementation SNShellView

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    self.background.frame = self.bounds;
    self.topBar.frame = NSMakeRect(0, 0, size.width, SNTopBarHeight);
    self.rail.frame = NSMakeRect(0, SNTopBarHeight, SNRailWidth, size.height - SNTopBarHeight);
    self.card.frame = NSMakeRect(SNRailWidth, SNTopBarHeight, MAX(0, size.width - SNRailWidth - SNCardInset),
                                 MAX(0, size.height - SNTopBarHeight - SNCardInset));
}

@end

@interface SNShell () <SNChangeObserver>
@end

@implementation SNShell {
    NSUserDefaults *_defaults;
    NSMutableArray<SNLocation *> *_back, *_forward;
    NSMutableArray *_panes;
    /// Tab panes, created the first time their tab shows or peeks.
    NSMutableDictionary<NSNumber *, id<SNTabPane>> *_tabPanes;
    /// Where the Files tab was last, and where the window was last outside it: each comes back
    /// when its side is chosen again, as Slack keeps the Files tab's view apart from the others'.
    SNLocation *_lastFiles, *_lastElsewhere;
    SNBackgroundView *_background;
    SNConnectionState _connectionState;
}

@synthesize location = _location;

- (instancetype)initWithSource:(id<SNSource>)source defaults:(NSUserDefaults *)defaults {
    if (!(self = [super init])) return nil;
    _source = source;
    _defaults = defaults;
    _back = [NSMutableArray new];
    _forward = [NSMutableArray new];
    _window = [[SNMainWindow alloc] initWithSize:SNWindowDefaultSize];
    if (defaults) _window.frameAutosaveName = @"SNMainWindow";

    SNShellView *root = [[SNShellView alloc] initWithFrame:NSMakeRect(0, 0, SNWindowDefaultSize.width, SNWindowDefaultSize.height)];
    _background = [[SNBackgroundView alloc] initWithFrame:NSZeroRect];
    _topBar = [[SNTopBar alloc] initWithFrame:NSZeroRect];
    _rail = [[SNRail alloc] initWithSource:source];
    _card = [[SNContentCard alloc] initWithFrame:NSZeroRect];
    root.background = _background, root.topBar = _topBar, root.rail = _rail, root.card = _card;
    for (NSView *view in @[ _background, _rail, _card, _topBar ]) [root addSubview:view];
    _window.contentView = root;

    _topBar.searchPlaceholder = SNLocalizedFormat(@"shell.search.placeholder", source.workspace.name);
    _topBar.backButton.tooltip = SNLocalized(@"shell.back");
    _topBar.forwardButton.tooltip = SNLocalized(@"shell.forward");
    _topBar.historyButton.tooltip = SNLocalized(@"shell.history");
    _topBar.helpButton.tooltip = SNLocalized(@"shell.help");
    _topBar.sidebarButton.tooltip = SNLocalized(@"shell.sidebar.toggle");
    _topBar.backButton.tooltipShortcut = @"⌘ [";
    _topBar.forwardButton.tooltipShortcut = @"⌘ ]";
    _topBar.helpButton.tooltipShortcut = @"F1";
    __weak SNShell *weakSelf = self;
    _topBar.backButton.action = ^(SNButton *button) { [weakSelf goBack]; };
    _topBar.forwardButton.action = ^(SNButton *button) { [weakSelf goForward]; };
    _topBar.historyButton.action = ^(SNButton *button) { [weakSelf showHistoryMenu:button]; };
    _topBar.helpButton.action = ^(SNButton *button) { [weakSelf openHelp]; };
    _topBar.sidebarButton.action = ^(SNButton *button) {
        SNContentCard *card = weakSelf.card;
        [card setSidebarCollapsed:!card.sidebarCollapsed animated:YES];
    };
    _topBar.searchPressed = ^{ [weakSelf openSearch]; };
    _rail.tabChosen = ^(SNTab tab) {
        // Choosing Home again empties its sidebar's filter, as in Slack.
        if (tab == SNTabHome && weakSelf.location.tab == SNTabHome) [weakSelf resetSidebarFilter];
        [weakSelf selectTab:tab];
    };
    _rail.workspaceChosen = ^(NSView *tile) {
        SNShell *shell = weakSelf;
        if (shell) [SNWorkspaceMenu showForRect:tile.bounds inView:tile placement:SNPlacementRight source:shell.source];
    };
    _rail.youChosen = ^(NSView *button) {
        SNShell *shell = weakSelf;
        if (shell) SNShowYouMenu(button, shell.source, shell);
    };
    _rail.peekContent = ^NSView *(SNTab tab) {
        id pane = [weakSelf paneForTab:tab];
        return [pane respondsToSelector:@selector(peekView)] ? [pane peekView] : nil;
    };
    _window.keyStateChanged = ^(BOOL key) { [weakSelf setWindowActive:key]; };

    _panes = [NSMutableArray new];
    _tabPanes = [NSMutableDictionary new];
    // The secondary column (threads/panels) is built only when first opened, keeping its list and
    // second composer off the launch critical path.
    for (SNPaneSlot slot = SNPaneSlotSidebar; slot <= SNPaneSlotSecondary; slot++) {
        Class paneClass = slot == SNPaneSlotSecondary ? Nil : SNRegisteredPane(slot);
        id<SNPane> pane = paneClass ? [(id<SNPane>)[paneClass alloc] initWithSource:source navigator:self] : nil;
        [_panes addObject:pane ? (id)pane : NSNull.null];
    }
    id<SNPane> sidebar = [self paneInSlot:SNPaneSlotSidebar];
    _card.sidebarView = sidebar.view;
    _card.primaryView = [self paneInSlot:SNPaneSlotPrimary].view;
    if ([sidebar respondsToSelector:@selector(minimumWidth)]) _card.sidebarMinimumWidth = MAX(SNSidebarMinimumWidth, sidebar.minimumWidth);
    _card.sidebarWidth = [defaults doubleForKey:kSidebarWidthKey] ?: kDefaultSidebarWidth;
    _card.secondaryWidth = [defaults doubleForKey:kSecondaryWidthKey] ?: kDefaultSecondaryWidth;
    _card.widthsChanged = ^{ [weakSelf saveLayout]; };

    // Size the columns to their real saved/default widths before apply: loads the first
    // conversation so neither the sidebar nor the message list lays out twice before frame 1.
    [root layoutSubtreeIfNeeded];

    _connectionState = source.connectionState;
    [source addChangeObserver:self];
    [self apply:[self restoredLocation]];
    // A window starts in the background until AppKit makes it key.
    [self setWindowActive:NO];
    return self;
}

- (id<SNPane>)paneInSlot:(SNPaneSlot)slot { return [self paneInSlot:slot syncLocation:YES]; }

- (id<SNPane>)paneInSlot:(SNPaneSlot)slot syncLocation:(BOOL)sync {
    id pane = _panes[(NSUInteger)slot];
    if (pane == NSNull.null && slot == SNPaneSlotSecondary) {
        Class paneClass = SNRegisteredPane(slot);
        if (!paneClass) return nil;
        pane = [(id<SNPane>)[paneClass alloc] initWithSource:self.source navigator:self];
        _panes[(NSUInteger)slot] = pane;
        _card.secondaryView = ((id<SNPane>)pane).view;
        if (sync && _location && [pane respondsToSelector:@selector(showLocation:)]) [pane showLocation:_location];
    }
    return pane == NSNull.null ? nil : pane;
}

- (id<SNPane>)paneForTab:(SNTab)tab { return [self paneForTab:tab syncLocation:YES]; }

- (id<SNPane>)paneForTab:(SNTab)tab syncLocation:(BOOL)sync {
    Class paneClass = SNRegisteredTabPane(tab);
    if (!paneClass) return tab == SNTabHome ? [self paneInSlot:SNPaneSlotSidebar] : nil;
    id<SNTabPane> pane = _tabPanes[@(tab)];
    if (!pane) {
        pane = [(id<SNTabPane>)[paneClass alloc] initWithSource:self.source navigator:self];
        _tabPanes[@(tab)] = pane;
        if (sync && _location && [pane respondsToSelector:@selector(showLocation:)]) [pane showLocation:_location];
    }
    return pane;
}

- (void)setWindowActive:(BOOL)active {
    _background.dimmed = _rail.dimmed = _topBar.dimmed = !active;
}

- (void)sourceChanged:(SNChange *)change {
    if (change.connection) {
        SNConnectionState state = self.source.connectionState;
        if (state == SNConnectionConnected && _connectionState != SNConnectionConnected) SNRetryFailedImages();
        _connectionState = state;
    }
    SNUser *me = self.source.me;
    if (![change.users containsObject:me.userID] && ![change.presence containsObject:me.userID]) return;
    _rail.avatar.imageURL = [me avatarURLForPixels:72];
    _rail.avatar.presence = SNAvatarPresenceOfUser(me, self.source);
    _rail.avatar.doNotDisturb = [self.source doNotDisturbOfUser:me.userID];
}

- (void)showHistoryMenu:(SNButton *)button {
    NSMutableArray<NSString *> *seen = [NSMutableArray new];
    if (_location.conversationID) [seen addObject:_location.conversationID];
    for (SNLocation *loc in _back.reverseObjectEnumerator) {
        if (loc.conversationID && ![seen containsObject:loc.conversationID]) [seen addObject:loc.conversationID];
        if (seen.count >= 10) break;
    }
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    __weak SNShell *weakSelf = self;
    for (NSString *conversationID in seen) {
        SNConversation *conversation = [self.source conversationWithID:conversationID];
        if (!conversation) continue;
        NSString *title = SNConversationTitle(conversation, self.source);
        if (!title.length) continue;
        SNMenuItem *item = [SNMenuItem itemWithTitle:title action:^{ [weakSelf openConversation:conversationID]; }];
        if (!conversation.isDirect) item.icon = conversation.kind == SNConversationPrivateChannel ? @"lock-filled" : @"channel-filled";
        item.checked = [conversationID isEqualToString:_location.conversationID];
        [items addObject:item];
    }
    if (!items.count) return;
    [[[SNMenu alloc] initWithItems:items width:260] showForRect:button.bounds inView:button placement:SNPlacementBelow];
}

- (void)resetSidebarFilter {
    id<SNPane> sidebar = [self paneInSlot:SNPaneSlotSidebar];
    if ([sidebar respondsToSelector:@selector(resetFilters)]) [sidebar resetFilters];
}

- (void)openSearch {
    NSMutableArray *recent = [NSMutableArray new];
    for (SNLocation *location in _back.reverseObjectEnumerator)
        if (location.conversationID) [recent addObject:location.conversationID];
    [SNSearchModal showOverField:_topBar.searchField source:self.source navigator:self recent:recent];
}

- (void)openSearchWithQuery:(NSString *)query {
    [self openSearch];
    [SNSearchModal.current runQuery:query];
}

#pragma mark Navigation

- (SNLocation *)restoredLocation {
    NSDictionary *saved = [_defaults dictionaryForKey:kLocationKey];
    NSString *conversationID = saved[@"conversation"];
    if ([conversationID isKindOfClass:NSString.class] && [self.source conversationWithID:conversationID])
        return [SNLocation locationWithTab:(SNTab)[saved[@"tab"] integerValue] conversation:conversationID thread:nil];
    // Slack opens on Home at the first conversation of the sidebar.
    for (SNSection *section in self.source.sections)
        for (NSString *candidate in section.conversationIDs)
            if ([self.source conversationWithID:candidate]) return [SNLocation locationWithTab:SNTabHome conversation:candidate thread:nil];
    return [SNLocation locationWithTab:SNTabHome conversation:self.source.directMessages.firstObject.conversationID thread:nil];
}

- (void)go:(SNLocation *)location {
    if ([location isEqual:_location]) {
        if (location.messageTS) [self apply:location];
        return;
    }
    if (_location) [_back addObject:_location];
    [_forward removeAllObjects];
    [self apply:location];
}

- (void)goBack {
    if (!_back.count) return;
    [_forward addObject:_location];
    SNLocation *location = _back.lastObject;
    [_back removeLastObject];
    [self apply:location];
}

- (void)goForward {
    if (!_forward.count) return;
    [_back addObject:_location];
    SNLocation *location = _forward.lastObject;
    [_forward removeLastObject];
    [self apply:location];
}

- (void)openHelp { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://slack.com/help"]]; }

- (void)apply:(SNLocation *)location {
    _location = location;
    if (location.tab == SNTabFiles) _lastFiles = location;
    else _lastElsewhere = location;
    [_rail closePeek];
    _rail.currentTab = location.tab;
    _card.secondaryVisible = location.threadTS || location.panel;
    if (_card.secondaryVisible) (void)[self paneInSlot:SNPaneSlotSecondary syncLocation:NO];
    _topBar.backButton.enabled = _back.count > 0;
    _topBar.forwardButton.enabled = _forward.count > 0;
    NSView *sidebar = (SNRegisteredTabPane(location.tab) ? [self paneForTab:location.tab syncLocation:NO] : [self paneInSlot:SNPaneSlotSidebar]).view;
    if (_card.sidebarView != sidebar) _card.sidebarView = sidebar;
    for (id pane in [_panes arrayByAddingObjectsFromArray:_tabPanes.allValues])
        if (pane != NSNull.null && [pane respondsToSelector:@selector(showLocation:)]) [pane showLocation:location];
    // As in Slack, typing goes to the conversation (or thread) just opened.
    id<SNPane> typing = [self paneInSlot:location.threadTS || location.panel ? SNPaneSlotSecondary : SNPaneSlotPrimary];
    if ((location.conversationID || location.page) && [typing respondsToSelector:@selector(focusForTyping)]) [typing focusForTyping];
    if (location.conversationID) [_defaults setObject:@{@"tab" : @(location.tab), @"conversation" : location.conversationID} forKey:kLocationKey];
}

- (void)saveLayout {
    [_defaults setDouble:_card.sidebarWidth forKey:kSidebarWidthKey];
    [_defaults setDouble:_card.secondaryWidth forKey:kSecondaryWidthKey];
}

// A panel (Slack's flexpane) stays open beside the next conversation; a thread does not.
- (void)openConversation:(NSString *)conversationID {
    [self go:[SNLocation locationWithTab:self.location.tab conversation:conversationID thread:nil page:nil panel:self.location.panel]];
}

- (void)openThread:(NSString *)threadTS inConversation:(NSString *)conversationID {
    [self go:[SNLocation locationWithTab:self.location.tab conversation:conversationID thread:threadTS]];
}

- (void)closeThread {
    [self go:[SNLocation locationWithTab:self.location.tab conversation:self.location.conversationID thread:nil]];
}

- (void)selectTab:(SNTab)tab {
    SNLocation *here = self.location;
    if (tab == SNTabFiles) here = _lastFiles ?: [SNLocation locationWithTab:SNTabFiles conversation:nil thread:nil page:SNPageFiles panel:here.panel];
    else if (here.tab == SNTabFiles && _lastElsewhere) here = _lastElsewhere;
    [self go:[SNLocation locationWithTab:tab conversation:here.conversationID thread:here.threadTS page:here.page panel:here.panel]];
}

@end
