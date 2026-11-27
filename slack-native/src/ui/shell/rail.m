// Owns the rail's tiles, tabs and control strip, and their hover effects.
#import "render/images.h"
#import "render/strings.h"
#import "ui/kit/container.h"
#import "ui/kit/label.h"
#import "ui/kit/overlay.h"
#import "ui/shell/rail.h"
#import "ui/shell/tabs.h"

static const CGFloat kTile = 36, kTileRadius = 8, kTileX = (SNRailWidth - kTile) / 2;
/// The workspace tile sits 8 pt below the top bar (the rail's top padding).
static const CGFloat kWorkspaceTop = 8;
/// A tab is 52 pt wide: 8 pt padding, the 36 pt tile, 4 pt, label lines of 12 pt, 8 pt. The
/// first tab's top and the pitch between tabs are measured on the official app.
static const CGFloat kTabWidth = 52, kTabPadding = 8, kLabelGap = 4, kLabelLine = 12, kFirstTabTop = 61.5, kTabPitch = 68;
/// The control strip: 36 pt circles 16 pt apart, 24 pt above the window's bottom.
static const CGFloat kStripGap = 16, kStripBottom = 24;
/// components.json tab_rail and control_strip: background and scale move together in 125 ms
/// with the press easing.
static const CFTimeInterval kRailTransition = 0.125;
static const CGFloat kTabHoverScale = 1.15, kCircleHoverScale = 1.1, kDimmedAlpha = 0.66;
/// The peek (measured live): its top 52 pt above the tab's tile, over the sidebar column right of
/// the card's 1 pt border, 65% of the window tall, with the menus' ring and shadow.
static const CGFloat kPeekAboveTile = 52, kPeekHeightShare = 0.65, kPeekRadius = 8;
/// The peek closes once the pointer has left both its tab and itself for this long, enough to
/// cross the gap between them (not measured: the hover card's grace).
static const NSTimeInterval kPeekCloseGrace = SNLiveHoverCardCloseDelay;

#pragma mark Tabs

@interface SNRailTab ()
- (instancetype)initWithTab:(SNTab)tab icon:(NSString *)icon title:(NSString *)title;
/// The tab's height with its label wrapped to the tab's width.
@property (nonatomic, readonly) CGFloat heightForLabel;
@property (nonatomic, copy) void (^hoverChanged)(SNRailTab *tab);
/// Where the pointer really is: `hovered` stays on while the tab's peek is open.
@property (nonatomic, readonly) BOOL pointerInside;
@property (nonatomic, copy) void (^pointerLeft)(void);
@end

@implementation SNRailTab {
    CALayer *_tile;
    SNIconLayer *_icon;
    SNLabel *_label;
    NSString *_iconName;
}

- (instancetype)initWithTab:(SNTab)tab icon:(NSString *)icon title:(NSString *)title {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _tab = tab;
    _iconName = icon;
    _tile = [SNLayer layer];
    _tile.cornerRadius = kTileRadius;
    [self.layer insertSublayer:_tile below:self.overlayLayer];
    _icon = [SNIconLayer iconNamed:icon size:20 color:SNThemeContentInvPry];
    [self.layer addSublayer:_icon];
    _label = [SNLabel labelWithText:title font:SNFont(11, SNFontWeightBold) color:SNThemeContentInvPry];
    _label.lineHeight = kLabelLine;
    _label.alignment = NSTextAlignmentCenter;
    _label.maximumLines = 0;
    _label.balanced = YES;
    [self addSubview:_label];
    self.hoverColor = self.pressedColor = SNThemeSurfInvPry;
    self.overlayRadius = kTileRadius;
    self.transitionDuration = kRailTransition;
    self.transitionTiming = SNEasePress();
    return self;
}

- (CGFloat)heightForLabel { return kTabPadding + kTile + kLabelGap + [_label heightForWidth:kTabWidth] + kTabPadding; }

- (void)setHovered:(BOOL)hovered {
    BOOL was = self.hovered;
    [super setHovered:hovered || self.peeking];
    if (self.hovered != was && self.hoverChanged) self.hoverChanged(self);
}

- (void)setPeeking:(BOOL)peeking {
    _peeking = peeking;
    if (peeking) self.hovered = YES;
}

- (void)mouseEntered:(NSEvent *)event {
    _pointerInside = YES;
    [super mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event {
    _pointerInside = NO;
    [super mouseExited:event];
    if (self.pointerLeft) self.pointerLeft();
}

- (void)setCurrent:(BOOL)current {
    _current = current;
    // The current tab keeps the hover fill, so hovering it changes only the glyph's scale.
    self.hoverColor = self.pressedColor = current ? 0 : SNThemeSurfInvPry;
    _tile.backgroundColor = current ? SNCGColor(SNThemeSurfInvPry) : NULL;
    _icon.iconName = current ? [_iconName stringByAppendingString:@"-filled"] : _iconName;
}

- (void)layout {
    CGFloat inset = (kTabWidth - kTile) / 2;
    // The overlay covers the tile only; SNHoverView places it from these insets.
    self.overlayInsets = NSEdgeInsetsMake(kTabPadding, inset, self.bounds.size.height - kTabPadding - kTile, inset);
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tile.frame = CGRectMake(inset, kTabPadding, kTile, kTile);
    _icon.bounds = CGRectMake(0, 0, kTile, kTile);
    _icon.position = CGPointMake(inset + kTile / 2, kTabPadding + kTile / 2);
    [CATransaction commit];
    _label.frame = NSMakeRect(0, kTabPadding + kTile + kLabelGap, kTabWidth, [_label heightForWidth:kTabWidth]);
}

- (void)stateDidChange {
    [super stateDidChange];
    CGFloat scale = self.hovered || self.pressed ? kTabHoverScale : 1;
    _icon.affineTransform = CGAffineTransformMakeScale(scale, scale);
}

@end

#pragma mark Workspace tile

/// The workspace's icon with the two tiles Slack stacks behind it (components.json
/// workspace_tile: theme-base-pry phantoms at 30% and 45%, shifted 6 and 3 pt down and scaled
/// to 77.8% and 88.9% from their bottom edge).
@interface SNWorkspaceTile : SNHoverView
@property (nonatomic, readonly) SNAvatarView *icon;
@end

@implementation SNWorkspaceTile

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    // The icon covers the whole tile, so hovering it shows only the tooltip.
    self.hoverColor = self.pressedColor = 0;
    self.tooltipPlacement = SNPlacementRight;
    struct { CGFloat opacity, shift, scale, radius; } phantoms[] = {{0.3, 6, 0.778, kTileRadius}, {0.45, 3, 0.889, 6}};
    for (int i = 0; i < 2; i++) {
        CALayer *phantom = [CALayer layer];
        phantom.backgroundColor = SNCGColor(SNThemeBasePry);
        phantom.opacity = (float)phantoms[i].opacity;
        phantom.cornerRadius = phantoms[i].radius;
        phantom.anchorPoint = CGPointMake(0.5, 1);
        phantom.bounds = CGRectMake(0, 0, kTile, kTile);
        phantom.position = CGPointMake(kTile / 2, kTile + phantoms[i].shift);
        phantom.affineTransform = CGAffineTransformMakeScale(phantoms[i].scale, phantoms[i].scale);
        [self.layer addSublayer:phantom];
    }
    // components.json workspace_tile: an outer 13% light ring and a soft shadow behind the icon,
    // an inner 8% black line over it.
    CALayer *backdrop = [CALayer layer];
    backdrop.frame = CGRectMake(0, 0, kTile, kTile);
    backdrop.cornerRadius = kTileRadius;
    SNShadowStack outer = {2, {{0, 0, 0, 1, SNLegacyHairline, NO}, {0, 1, 3, 0, 0x00000014, NO}}};
    SNApplyShadow(backdrop, outer);
    [self.layer addSublayer:backdrop];
    _icon = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, kTile, kTile)];
    _icon.placeholderColor = SNLegacyForegroundMaxSolid;
    [self addSubview:_icon];
    CALayer *stroke = [CALayer layer];
    stroke.frame = backdrop.frame;
    stroke.cornerRadius = kTileRadius;
    stroke.borderWidth = 1;
    stroke.borderColor = SNCGColor(0x00000014);
    [self.layer addSublayer:stroke];
    return self;
}

@end

#pragma mark Peek

/// The peek's surface, which tells the rail when the pointer leaves it.
@interface SNPeekPanel : SNPanelView
@property (nonatomic, readonly) BOOL pointerInside;
@property (nonatomic, copy) void (^pointerLeft)(void);
@end

@implementation SNPeekPanel {
    NSTrackingArea *_tracking;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { _pointerInside = YES; }

- (void)mouseExited:(NSEvent *)event {
    _pointerInside = NO;
    if (self.pointerLeft) self.pointerLeft();
}

@end

#pragma mark Rail

@interface SNRail () <SNChangeObserver>
@end

@implementation SNRail {
    SNContainerView *_content;
    SNWorkspaceTile *_workspace;
    __weak id<SNSource> _source;
    /// The tab whose hover delay is running, and the open peek with its tab. The peek is not a
    /// popover: clicks around it (its own tab's included) go where they are aimed, and another
    /// popover (the search) stays open under it.
    SNRailTab *_pending;
    SNPeekPanel *_peek;
    SNRailTab *_peekTab;
    /// Watches for the pointer coming back into the window while the peek waits for it.
    id _returnMonitor;
}

static SNButton *CircleButton(NSString *icon) {
    SNButton *button = [[SNButton alloc] initWithFrame:NSMakeRect(0, 0, kTile, kTile)];
    button.icon.iconName = icon;
    button.icon.iconSize = 20;
    button.cornerRadius = kTile / 2;
    button.fillColor = button.hoverFillColor = SNThemeSurfInvPry;
    button.contentColor = SNThemeContentInvSec;
    button.hoverContentColor = SNThemeContentInvPry;
    button.hoverColor = SNThemeSurfInvPryHover;
    // Pressed (or its menu open): the fill turns theme-base-pry under a theme-content-ter glyph.
    button.pressedColor = SNThemeBasePry;
    button.pressedContentColor = SNThemeContentTer;
    button.hoverButtonScale = kCircleHoverScale;
    button.transitionDuration = kRailTransition;
    button.transitionTiming = SNEasePress();
    return button;
}

- (void)sourceChanged:(SNChange *)change {
    if (change.lists) [self showWorkspace];
}

- (void)showWorkspace {
    SNWorkspace *workspace = _source.workspace;
    NSURL *url = [workspace iconURLForPixels:kTile * 2];
    if (url != _workspace.icon.imageURL && ![url isEqual:_workspace.icon.imageURL]) _workspace.icon.imageURL = url;
    _workspace.tooltip = workspace.name;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, SNRailWidth, 400)])) return nil;
    _content = [[SNContainerView alloc] initWithFrame:self.bounds];
    _content.wantsLayer = YES;
    [self addSubview:_content];

    _workspace = [[SNWorkspaceTile alloc] initWithFrame:NSMakeRect(kTileX, kWorkspaceTop, kTile, kTile)];
    _source = source;
    [self showWorkspace];
    // The workspace can arrive after the rail is built (a launch from an older cache), so the tile
    // follows changes instead of keeping what it saw first.
    [source addChangeObserver:self];
    __weak SNRail *weakRail = self;
    _workspace.action = ^(SNWorkspaceTile *tile) {
        SNRail *rail = weakRail;
        if (rail.workspaceChosen) rail.workspaceChosen(tile);
    };
    [_content addSubview:_workspace];

    struct { SNTab tab; NSString *icon, *key; } tabs[] = {
        {SNTabHome, @"home", @"shell.rail.home"},
        {SNTabDirectMessages, @"direct-messages", @"shell.rail.dms"},
        {SNTabActivity, @"notifications", @"shell.rail.activity"},
        {SNTabFiles, @"canvas-browser", @"shell.rail.files"},
        {SNTabAgents, @"ai-agents", @"shell.rail.agents"},
    };
    NSMutableArray *views = [NSMutableArray new];
    for (size_t i = 0; i < sizeof tabs / sizeof *tabs; i++) {
        SNRailTab *tab = [[SNRailTab alloc] initWithTab:tabs[i].tab icon:tabs[i].icon title:SNLocalized(tabs[i].key)];
        __weak SNRail *weakSelf = self;
        tab.action = ^(SNRailTab *chosen) {
            SNRail *rail = weakSelf;
            if (rail.tabChosen) rail.tabChosen(chosen.tab);
        };
        tab.hoverChanged = ^(SNRailTab *changed) { [weakSelf tabHoverChanged:changed]; };
        tab.pointerLeft = ^{ [weakSelf pointerLeftPeek]; };
        [_content addSubview:tab];
        [views addObject:tab];
    }
    _tabs = views;

    _createButton = CircleButton(@"plus");
    _createButton.tooltip = SNLocalized(@"shell.rail.create");
    _createButton.tooltipPlacement = SNPlacementRight;
    _themeButton = CircleButton(@"moon");
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, kTile, kTile)];
    _avatar.imageURL = [source.me avatarURLForPixels:kTile * 2];
    _avatar.presence = SNAvatarPresenceOfUser(source.me, source);
    _avatar.doNotDisturb = [source doNotDisturbOfUser:source.me.userID ?: @""];
    // The picture covers the whole button, as the workspace tile's icon does.
    _youButton = [[SNHoverView alloc] initWithFrame:NSMakeRect(0, 0, kTile, kTile)];
    _youButton.hoverColor = _youButton.pressedColor = 0;
    [_youButton addSubview:_avatar];
    _youButton.action = ^(SNHoverView *button) {
        SNRail *rail = weakRail;
        if (rail.youChosen) rail.youChosen(button);
    };
    for (NSView *view in @[ _createButton, _themeButton, _youButton ]) [_content addSubview:view];
    self.currentTab = SNTabHome;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)setCurrentTab:(SNTab)currentTab {
    _currentTab = currentTab;
    for (SNRailTab *tab in self.tabs) tab.current = tab.tab == currentTab;
}

- (void)setDimmed:(BOOL)dimmed {
    _dimmed = dimmed;
    _content.alphaValue = dimmed ? kDimmedAlpha : 1;
}

#pragma mark Peek

- (void)tabHoverChanged:(SNRailTab *)tab {
    if (!tab.hovered) {
        if (_pending == tab) _pending = nil;
        return;
    }
    if (tab == _peekTab || tab.current || !self.peekContent) return;
    [self closePeek];
    _pending = tab;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLiveRailPeekDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_pending != tab) return;
        self->_pending = nil;
        [self showPeekForTab:tab.tab];
    });
}

- (void)showPeekForTab:(SNTab)tab {
    SNRailTab *view = nil;
    for (SNRailTab *candidate in self.tabs)
        if (candidate.tab == tab) view = candidate;
    NSView *content = self.peekContent ? self.peekContent(tab) : nil;
    if (!view || !content || !self.window) return;
    [self closePeek];
    SNPeekPanel *panel = [[SNPeekPanel alloc] initWithFill:SNColorCtrPry radius:kPeekRadius shadow:SNMenuShadow];
    CGFloat height = floor(self.window.contentView.bounds.size.height * kPeekHeightShare * 2) / 2;
    panel.frame = NSMakeRect(0, 0, SNPeekWidth, height);
    content.frame = panel.contentView.bounds;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [panel.contentView addSubview:content];
    // Right of a target that ends on the card's border, level with the peek's top.
    SNOverlayHost *host = [SNOverlayHost hostForWindow:self.window];
    NSRect target = [host convertRect:NSMakeRect(0, NSMinY(view.frame) + kTabPadding - kPeekAboveTile, SNRailWidth + 1, 1) fromView:self];
    panel.frame = SNPlaceOverlay(NSMakeSize(SNPeekWidth, height), target, SNPlacementRight, 0, NO, host.bounds);
    panel.alphaValue = 0;
    [host addSubview:panel];
    _peek = panel;
    _peekTab = view;
    view.peeking = YES;
    __weak SNRail *weakSelf = self;
    panel.pointerLeft = ^{ [weakSelf pointerLeftPeek]; };
    SNAnimate(SNLiveRailPeekFadeIn, SNEaseLiveRailPeek(), ^{ panel.animator.alphaValue = 1; });
}

- (NSView *)peekPanel { return _peek; }

- (void)pointerLeftPeek {
    SNPeekPanel *peek = _peek;
    if (!peek) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPeekCloseGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_peek != peek || peek.pointerInside || self->_peekTab.pointerInside) return;
        // effects.txt [A7]: the peek stays while the pointer is outside the window and goes once
        // it moves over something else in it.
        if ([self pointerOutsideWindow]) [self closePeekWhenPointerReturns];
        else [self closePeek];
    });
}

- (BOOL)pointerOutsideWindow {
    NSView *content = self.window.contentView;
    return !NSPointInRect([content convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil], content.bounds);
}

- (void)closePeekWhenPointerReturns {
    if (_returnMonitor) return;
    __weak SNRail *weakSelf = self;
    _returnMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
        SNRail *rail = weakSelf;
        if (rail && event.window == rail.window && !rail.pointerOutsideWindow) {
            [rail stopWaitingForPointer];
            [rail pointerLeftPeek];
        }
        return event;
    }];
}

- (void)stopWaitingForPointer {
    if (_returnMonitor) [NSEvent removeMonitor:_returnMonitor];
    _returnMonitor = nil;
}

- (void)closePeek {
    _pending = nil;
    [self stopWaitingForPointer];
    if (!_peek) return;
    [_peek removeFromSuperview];
    _peek = nil;
    SNRailTab *tab = _peekTab;
    _peekTab = nil;
    tab.peeking = NO;
    tab.hovered = tab.pointerInside;
}

- (void)layout {
    [super layout];
    _content.frame = self.bounds;
    CGFloat top = kFirstTabTop, x = (SNRailWidth - kTabWidth) / 2;
    for (SNRailTab *tab in self.tabs) {
        tab.frame = NSMakeRect(x, top, kTabWidth, [tab heightForLabel]);
        top += kTabPitch;
    }
    CGFloat y = self.bounds.size.height - kStripBottom - kTile;
    for (NSView *view in @[ _youButton, _themeButton, _createButton ]) {
        view.frame = NSMakeRect(kTileX, y, kTile, kTile);
        y -= kTile + kStripGap;
    }
}

@end
