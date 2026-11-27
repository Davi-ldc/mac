// Owns the header row, the tab bar and opening the files peek.
#import "render/format.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/channel/header.h"
#import "ui/channel/kebab.h"
#import "ui/files/fileview.h"
#import "ui/files/peek.h"
#import "ui/kit/avatar.h"
#import "ui/kit/dialog.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/present/names.h"
#import "ui/profile/vip.h"

/// Measured on channel_header_tabs_default: the row is 49 pt, the star's 28 pt button starts
/// 18 pt in, the title 4 pt after it (a DM's avatar 3 pt further in, the name 9 pt after the
/// avatar); the icon buttons' centres sit these distances from the right edge.
static const CGFloat kRowHeight = 49, kTabHeight = 38, kStarX = 18, kButton = 28;
static const CGFloat kFirstFromRight = 26, kStep[] = {32, 35, 34, 30};
/// The huddle control's right edge is 10 pt past the options caret's centre; the members button's
/// centre stays 26 pt left of the control whatever its width.
static const CGFloat kHuddleRight = 10, kMembersFromHuddle = 26;
/// Tabs: 16 pt in, 4 pt apart, 8 pt padding, a 16 pt icon 4 pt before the 13 pt bold label; the
/// selected tab's icon is the filled variant.
static const CGFloat kTabsLeft = 16, kTabGap = 4, kTabPadding = 8, kTabIcon = 16, kTabIconGap = 4;

@interface SNChannelTab : SNHoverView
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic) BOOL selected;
@property (nonatomic, readonly) CGFloat preferredWidth;
@end

@implementation SNChannelTab

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.transitionDuration = SNLiveTabHover;
    self.overlayRadius = SNRadiusLarge;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    // Only the top corners are rounded; the overlay's layer is flipped with the view.
    self.overlayLayer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    return self;
}

- (NSFont *)font { return SNFont(SNFontSizeCaption, SNFontWeightBold); }

- (CGFloat)preferredWidth {
    CGFloat text = self.title ? ceil(SNTextWidth(self.title, self.font)) + kTabIconGap : 0;
    return kTabPadding + kTabIcon + text + kTabPadding;
}

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSSize size = self.bounds.size;
    SNColorToken color = self.selected || self.hovered || self.pressed ? SNColorContentPry : SNColorContentSec;
    NSString *icon = self.selected ? [self.icon stringByAppendingString:@"-filled"] : self.icon;
    SNDrawIcon(icon, kTabIcon, color, NSMakeRect(kTabPadding, (size.height - kTabIcon) / 2, kTabIcon, kTabIcon));
    if (self.title)
        SNDrawText(self.title, self.font, color, size.height, NSTextAlignmentLeft, 1,
                   NSMakeRect(kTabPadding + kTabIcon + kTabIconGap, 0, size.width - kTabPadding * 2 - kTabIcon - kTabIconGap, size.height));
    if (self.selected) {
        [SNColor(SNThemeBasePry) setFill];
        NSRectFill(NSMakeRect(0, size.height - 2, size.width, 2));
    }
}

@end

@implementation SNChannelHeader {
    id<SNSource> _source;
    CALayer *_bottomLine;
    SNButton *_titleIcon;
    SNAvatarView *_avatar;
    SNLabel *_title;
    NSArray<SNButton *> *_rightButtons;
    NSUInteger _filesHover;
}

static SNButton *IconButton(NSString *icon, CGFloat size, SNColorToken hoverFill, NSString *tip) {
    SNButton *button = [SNButton iconButtonNamed:icon size:kButton iconSize:size];
    button.hoverFillColor = hoverFill;
    button.transitionDuration = SNLiveHeaderIconButtonHover;
    button.tooltip = SNLocalized(tip);
    button.tooltipPlacement = SNPlacementBelow;
    return button;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, SNChannelHeaderHeight)])) return nil;
    _source = source;
    self.wantsLayer = YES;
    // A 1 pt sublayer instead of -drawRect:, so the whole 88 pt header needs no backing store.
    _bottomLine = [CALayer layer];
    _bottomLine.backgroundColor = SNCGColor(SNLegacyForegroundLowSolid);
    [self.layer addSublayer:_bottomLine];
    _star = IconButton(@"star", 20, SNMeasuredHeaderStarHover, @"channel.header.star");
    _star.contentColor = SNLegacyPrimaryForeground;
    _star.hoverContentColor = 0xffffffff;
    _star.enabled = NO;
    // The prefix has no size of its own: it takes the title's 18 px.
    _titleIcon = IconButton(@"channel-filled", SNFontSizeSubtitle, 0, @"channel.header.details");
    _titleIcon.contentColor = _titleIcon.hoverContentColor = SNColorContentPry;
    _titleIcon.tooltip = nil;
    _titleIcon.enabled = NO;
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, 24, 24)];
    _title = [SNLabel labelWithText:@"" font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNColorContentPry];
    _title.lineHeight = kRowHeight;
    _members = IconButton(@"user", 20, SNMeasuredHeaderMembersHover, @"channel.header.members");
    _members.font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    _members.spacing = 4;
    _members.enabled = NO;
    _huddle = [[SNHuddleHeaderControl alloc] initWithSource:source];
    _bell = IconButton(@"notifications", 20, 0, @"channel.header.notifications");
    _bell.enabled = NO;
    _search = IconButton(@"search", 20, 0, @"channel.header.search");
    _more = [SNKebabButton kebabWithSize:kButton iconSize:16];
    _more.tooltip = SNLocalized(@"channel.header.more");
    _more.tooltipPlacement = SNPlacementBelow;
    // A small icon button: its x is 16 pt (11 pt across on channel_header_tabs_default), not the
    // 20 pt of the thread's close.
    _close = IconButton(@"close", 16, SNMeasuredHeaderKebabHover, @"channel.header.close");
    __weak SNChannelHeader *weakSelf = self;
    _close.action = ^(SNButton *button) {
        SNChannelHeader *header = weakSelf;
        if (header.closeAction) header.closeAction();
    };
    _more.action = ^(SNButton *button) { [weakSelf showMoreMenu]; };
    _huddle.widthChanged = ^{ weakSelf.needsLayout = YES; };
    _rightButtons = @[ _close, _more, _search, _bell ];
    for (NSView *view in @[ _star, _titleIcon, _avatar, _title, _huddle, _members ]) [self addSubview:view];
    for (NSView *view in _rightButtons) [self addSubview:view];

    NSArray *tabs = @[ @[ @"message", @"channel.tab.messages" ], @[ @"add-channel-canvas", @"channel.tab.canvas" ], @[ @"canvas-browser", @"channel.tab.files" ],
                       @[ @"plus-filled", @"" ] ];
    NSMutableArray<SNHoverView *> *tabViews = [NSMutableArray new];
    for (NSArray<NSString *> *spec in tabs) {
        SNChannelTab *tab = [[SNChannelTab alloc] initWithFrame:NSZeroRect];
        tab.icon = spec[0];
        tab.title = spec[1].length ? SNLocalized(spec[1]) : nil;
        if (!tab.title) {
            tab.tooltip = SNLocalized(@"channel.tab.add");
            tab.tooltipPlacement = SNPlacementBelow;
        }
        [self addSubview:tab];
        [tabViews addObject:tab];
    }
    ((SNChannelTab *)tabViews[0]).selected = YES;
    tabViews[1].enabled = NO;
    tabViews[3].enabled = NO;
    for (NSNumber *number in @[ @0, @2 ]) {
        NSUInteger index = number.unsignedIntegerValue;
        tabViews[index].action = ^(SNHoverView *tab) {
            SNChannelHeader *header = weakSelf;
            [header closeFilesPreview];
            if (header.tabChosen) header.tabChosen(index);
        };
    }
    _tabs = tabViews;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setSelectedTab:(NSUInteger)selectedTab {
    _selectedTab = selectedTab;
    for (NSUInteger i = 0; i < _tabs.count; i++) ((SNChannelTab *)_tabs[i]).selected = i == selectedTab;
}

/// The card lays the header out at this height (SNCardHeaderProvider).
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, _collapsed ? 0 : SNChannelHeaderHeight); }

- (void)setCollapsed:(BOOL)collapsed {
    if (collapsed == _collapsed) return;
    _collapsed = collapsed;
    self.hidden = collapsed;
    [self invalidateIntrinsicContentSize];
    // The card lays the header out across its columns.
    for (NSView *view = self.superview; view; view = view.superview) view.needsLayout = YES;
}

- (void)showConversation:(SNConversation *)conversation closable:(BOOL)closable {
    _conversation = conversation;
    SNUser *other = conversation.userID ? [_source userWithID:conversation.userID] : nil;
    BOOL direct = conversation.kind == SNConversationDirect;
    _avatar.hidden = !direct;
    _titleIcon.hidden = direct || conversation.kind == SNConversationGroupDirect;
    _titleIcon.icon.iconName = conversation.kind == SNConversationPrivateChannel ? @"lock-filled" : @"channel-filled";
    if (direct) {
        // 72 px rather than 48: the size every avatar of the workspace is already cached at.
        _avatar.imageURL = [other avatarURLForPixels:72];
        _avatar.presence = [_source presenceOfUser:conversation.userID] == SNPresenceActive ? SNAvatarPresenceActive : SNAvatarPresenceAway;
        _avatar.doNotDisturb = [_source doNotDisturbOfUser:conversation.userID];
    }
    _title.text = SNConversationTitle(conversation, _source);
    _members.hidden = direct || conversation.kind == SNConversationGroupDirect;
    _members.title = conversation.memberCount > 0 ? @(conversation.memberCount).stringValue : nil;
    _close.hidden = !closable;
    _huddle.conversationID = conversation.conversationID;
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    CGFloat width = self.bounds.size.width, centre = kRowHeight / 2;
    _star.frame = NSMakeRect(kStarX, centre - kButton / 2, kButton, kButton);
    CGFloat x = NSMaxX(_star.frame) + 4;
    if (!_avatar.hidden) {
        _avatar.frame = NSMakeRect(x + 3, centre - 12, 24, 24);
        x = NSMaxX(_avatar.frame) + 9;
    } else if (!_titleIcon.hidden) {
        _titleIcon.frame = NSMakeRect(x, centre - 10, 20, 20);
        x = NSMaxX(_titleIcon.frame) + 4;
    }
    // Buttons right to left by their measured centres; without the close button the rest move
    // to its place.
    CGFloat centreX = width - kFirstFromRight, leftmost = width;
    BOOL first = YES;
    for (NSUInteger i = 0; i < _rightButtons.count; i++) {
        SNButton *button = _rightButtons[i];
        if (button.hidden) continue;
        if (!first) centreX -= kStep[i - 1];
        first = NO;
        button.frame = NSMakeRect(round(centreX - kButton / 2), centre - kButton / 2, kButton, kButton);
        leftmost = NSMinX(button.frame);
    }
    CGFloat huddleRight = centreX - kStep[3] + kHuddleRight;
    _huddle.frame = NSMakeRect(huddleRight - _huddle.preferredWidth, centre - kButton / 2, _huddle.preferredWidth, kButton);
    leftmost = NSMinX(_huddle.frame);
    if (!_members.hidden) {
        CGFloat membersWidth = _members.fittingContentSize.width + 16;
        _members.frame = NSMakeRect(round(leftmost - kMembersFromHuddle - membersWidth / 2), centre - kButton / 2, membersWidth, kButton);
        leftmost = NSMinX(_members.frame);
    }
    CGFloat titleRight = leftmost - 16;
    _title.frame = NSMakeRect(x, 0, MAX(0, MIN(ceil(_title.textWidth), titleRight - x)), kRowHeight);
    CGFloat tabX = kTabsLeft;
    for (SNChannelTab *tab in _tabs) {
        tab.frame = NSMakeRect(tabX, kRowHeight, tab.preferredWidth, kTabHeight);
        tabX += tab.preferredWidth + kTabGap;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bottomLine.frame = CGRectMake(0, SNChannelHeaderHeight - 1, self.bounds.size.width, 1);
    [CATransaction commit];
}

#pragma mark Files peek

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)event {
    SNHoverView *files = self.tabs[2];
    BOOL over = _selectedTab != 2 && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], files.frame);
    if (over && !_filesHover) {
        NSUInteger due = ++_filesHover;
        __weak SNChannelHeader *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLiveFilesTabPreviewDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SNChannelHeader *header = weakSelf;
            if (header && header->_filesHover == due) [header showFilesPreview];
        });
    } else if (!over && _filesHover) {
        // Leaving before the delay cancels it; an open preview stays (measured live).
        _filesHover = 0;
    }
}

- (void)mouseExited:(NSEvent *)event { _filesHover = 0; }

- (void)showFilesPreview {
    SNConversationAttachments *attachments = self.attachments ? self.attachments() : nil;
    // Coming back to the tab while its peek is open leaves it be.
    if (!attachments || !self.window || [SNFilesPeek.current.panel isDescendantOf:self.window.contentView]) return;
    [attachments loadIfNeeded];
    [SNFilesPeek showUnderTab:self.tabs[2] source:_source attachments:attachments];
}

- (void)closeFilesPreview {
    _filesHover = 0;
    if ([SNFilesPeek.current.panel isDescendantOf:self.window.contentView]) [SNFilesPeek.current close];
}

#pragma mark Menu

- (void)leaveCurrentChannel {
    SNConversation *conversation = self.conversation;
    if (!conversation || conversation.isDirect || !conversation.isMember || conversation.isGeneral) return;
    id<SNSource> source = _source;
    BOOL priv = conversation.kind == SNConversationPrivateChannel;
    if ((!priv && !conversation.isShared) || !self.window) {
        [source leaveConversation:conversation.conversationID completion:nil];
        return;
    }
    NSString *label = [@"#" stringByAppendingString:conversation.name ?: @""];
    [SNConfirmDialog showInWindow:self.window
                            title:SNLocalizedFormat(@"composer.command.leave.title", label)
                             text:SNLocalized(priv ? @"composer.command.leave.private" : @"composer.command.leave.shared")
                        accessory:nil
                     confirmTitle:SNLocalized(@"composer.command.leave.confirm")
                       completion:^(BOOL confirmed) {
                           if (confirmed) [source leaveConversation:conversation.conversationID completion:nil];
                       }];
}

- (void)showMoreMenu {
    SNMenuItem * (^disabledItem)(NSString *, NSString *, NSString *) = ^(NSString *key, NSString *icon, NSString *shortcut) {
        SNMenuItem *menuItem = [SNMenuItem itemWithTitle:SNLocalized(key) action:nil];
        menuItem.icon = icon;
        menuItem.shortcut = shortcut;
        menuItem.disabled = YES;
        return menuItem;
    };
    SNMenuItem * (^submenu)(NSString *) = ^(NSString *key) {
        SNMenuItem *menuItem = disabledItem(key, nil, nil);
        menuItem.submenu = YES;
        return menuItem;
    };
    SNConversation *conversation = self.conversation;
    BOOL canLeave = conversation && !conversation.isDirect && conversation.isMember && !conversation.isGeneral;
    __weak SNChannelHeader *weakSelf = self;
    SNMenuItem *leave = [SNMenuItem itemWithTitle:SNLocalized(@"channel.header.leave") action:canLeave ? ^{ [weakSelf leaveCurrentChannel]; } : nil];
    leave.danger = YES;
    leave.disabled = !canLeave;
    // canToggleVipInChannel: a DM with someone who can be a VIP offers "Add to VIP" / "Remove from VIP".
    SNUser *other = conversation.kind == SNConversationDirect && conversation.userID ? [_source userWithID:conversation.userID] : nil;
    SNMenuItem *vip = nil;
    if (other && SNCanToggleVIP(_source, other)) {
        id<SNSource> source = _source;
        vip = [SNMenuItem itemWithTitle:SNLocalized(SNIsVIP(source, other.userID) ? @"profile.vip.remove" : @"profile.vip.add")
                                 action:^{ SNToggleVIP(source, other, weakSelf.window); }];
        vip.icon = @"vip";
    }
    NSArray *items = @[
        submenu(@"channel.header.details"), submenu(@"channel.header.copy"), disabledItem(@"channel.header.favorite", nil, nil),
        disabledItem(@"channel.header.move", nil, nil), [SNMenuItem separator], submenu(@"channel.header.summarize"), [SNMenuItem separator],
        disabledItem(@"channel.header.template", nil, nil), disabledItem(@"channel.header.workflow", nil, nil), disabledItem(@"channel.header.settings", nil, nil),
        [SNMenuItem separator], disabledItem(@"channel.header.split", @"move-to-split-view", nil), disabledItem(@"channel.header.window", @"open-in-window", nil),
        [SNMenuItem separator], leave
    ];
    if (vip) items = [@[ vip, [SNMenuItem separator] ] arrayByAddingObjectsFromArray:items];
    SNMenu *menu = [[SNMenu alloc] initWithItems:items width:0];
    // The menu's top edge sits 8 pt above the kebab's bottom, its right edge at the kebab's.
    NSRect anchor = self.more.frame;
    anchor = NSMakeRect(NSMaxX(anchor) - menu.frame.size.width, NSMaxY(anchor) - 8 - 4, menu.frame.size.width, 0);
    [menu showForRect:anchor inView:self placement:SNPlacementBelow];
}

@end
