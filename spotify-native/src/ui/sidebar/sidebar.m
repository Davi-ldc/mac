// Native macOS translucent sidebar matching Spotifly 1:1:
// Startpage, Search, Queue (with upcoming badge), Playing On | Library: Favorites, Playlists, Albums, Artists | Profile + Settings footer.
#import "ui/sidebar/sidebar.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"
#import "ui/kit/controls.h"
#import "ui/kit/list.h"

typedef NS_ENUM(NSInteger, SPSidebarEntryKind) {
    SPSidebarEntryHeader = 0,
    SPSidebarEntryNav,
};

@interface SPSidebarEntry : NSObject
@property (nonatomic) SPSidebarEntryKind kind;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *badge;
@property (nonatomic) SPIconName icon;
@property (nonatomic, strong, nullable) SPRoute *route;
@end

@implementation SPSidebarEntry
@end

@interface SPSidebarRowView : SPListRowView
@property (nonatomic, strong, nullable) SPSidebarEntry *entry;
@property (nonatomic) BOOL isActiveRoute;
@property (nonatomic) BOOL windowActive;
@end

@implementation SPSidebarRowView

- (void)setEntry:(SPSidebarEntry *)entry {
    _entry = entry;
    self.needsDisplay = YES;
}

- (void)setIsActiveRoute:(BOOL)isActiveRoute {
    if (_isActiveRoute == isActiveRoute) return;
    _isActiveRoute = isActiveRoute;
    self.needsDisplay = YES;
}

- (void)setWindowActive:(BOOL)windowActive {
    if (_windowActive == windowActive) return;
    _windowActive = windowActive;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!_entry) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    NSRect b = self.bounds;

    if (_entry.kind == SPSidebarEntryHeader) {
        SPTextStyle hdrStyle = {11.0, NSFontWeightSemibold, 14.0, 0.0, NO};
        NSDictionary *attrs = SPSemanticTextAttributes(hdrStyle, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        [_entry.title drawInRect:NSMakeRect(18.0, floor(b.size.height - 18.0), MAX(0, b.size.width - 28.0), 15.0)
                  withAttributes:attrs];
        return;
    }

    // Selected row: solid Spotify green #1DB954 pill (or muted gray when window inactive) matching Spotifly 38.png.
    if (_isActiveRoute) {
        NSColor *pillColor = _windowActive ? SPAccentColor() : [SPLabelColor() colorWithAlphaComponent:0.14];
        CGContextSetFillColorWithColor(ctx, pillColor.CGColor);
        CGPathRef p = CGPathCreateWithRoundedRect(NSInsetRect(b, 10.0, 1.5), 8.0, 8.0, NULL);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
    } else if (self.isHovered) {
        CGContextSetFillColorWithColor(ctx, SPHoverFillColor().CGColor);
        CGPathRef p = CGPathCreateWithRoundedRect(NSInsetRect(b, 10.0, 1.5), 8.0, 8.0, NULL);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
    }

    // Spotifly SidebarIcon: white on selected green pill, #1DB954 green when window active, secondary gray when inactive.
    NSColor *iconColor = (_isActiveRoute && _windowActive)
        ? NSColor.whiteColor
        : (_windowActive ? SPAccentColor() : SPSecondaryLabelColor());
    NSColor *textColor = (_isActiveRoute && _windowActive) ? NSColor.whiteColor : SPLabelColor();

    CGFloat iconX = 20.0;
    CGRect iconRect = CGRectMake(iconX, floor((b.size.height - 16.0) * 0.5), 18.0, 16.0);
    SPDrawIconSemantic(_entry.icon, iconRect, 14.0, NSFontWeightMedium, iconColor);

    CGFloat rightPad = 18.0;
    if (_entry.badge.length) {
        NSColor *badgeCol = (_isActiveRoute && _windowActive)
            ? [NSColor colorWithWhite:1.0 alpha:0.88]
            : SPSecondaryLabelColor();
        SPTextStyle badgeStyle = {12.0, NSFontWeightMedium, 15.0, 0.0, YES};
        NSDictionary *badgeAttrs = SPSemanticTextAttributes(badgeStyle, badgeCol, NSLineBreakByClipping, NSTextAlignmentRight);
        [_entry.badge drawInRect:NSMakeRect(b.size.width - 54.0, floor((b.size.height - 15.0) * 0.5), 36.0, 16.0)
                  withAttributes:badgeAttrs];
        rightPad = 56.0;
    }

    CGFloat textX = iconX + 26.0;
    SPTextStyle titleStyle = _isActiveRoute ? typo->bodyMedium : typo->body;
    NSDictionary *titleAttrs = SPSemanticTextAttributes(titleStyle, textColor, NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
    [_entry.title drawInRect:NSMakeRect(textX, floor((b.size.height - 17.0) * 0.5), MAX(20.0, b.size.width - textX - rightPad), 18.0)
              withAttributes:titleAttrs];
}

@end

@interface SPSidebarListView : SPListView
@property (nonatomic, copy) NSArray<SPSidebarEntry *> *entries;
@property (nonatomic, strong, nullable) SPRoute *activeRoute;
@property (nonatomic) BOOL windowActive;
@property (nonatomic, copy, nullable) void (^onSelectEntry)(SPSidebarEntry *entry);
@end

@implementation SPSidebarListView

- (void)setEntries:(NSArray<SPSidebarEntry *> *)entries {
    _entries = [entries copy] ?: @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:_entries.count];
    for (SPSidebarEntry *e in _entries) [keys addObject:e.key];
    [self showKeys:keys];
}

- (SPListRowView *)makeRow {
    return [[SPSidebarRowView alloc] initWithFrame:NSZeroRect];
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width {
    (void)width;
    if (index >= _entries.count) return 32.0;
    SPSidebarEntry *e = _entries[index];
    return (e.kind == SPSidebarEntryHeader) ? 30.0 : 32.0;
}

- (BOOL)routeMatchesEntry:(SPSidebarEntry *)e {
    if (!e.route || !_activeRoute) return NO;
    if ([_activeRoute isEqual:e.route]) return YES;
    // Keep section highlighted while viewing its 3-column detail entity.
    if (e.route.kind == SPRoutePlaylists && _activeRoute.kind == SPRoutePlaylistDetail) return YES;
    if (e.route.kind == SPRouteAlbums && _activeRoute.kind == SPRouteAlbumDetail) return YES;
    if (e.route.kind == SPRouteArtists && _activeRoute.kind == SPRouteArtistDetail) return YES;
    return NO;
}

- (void)showIndex:(NSUInteger)index inRow:(SPSidebarRowView *)row {
    if (index >= _entries.count) return;
    SPSidebarEntry *e = _entries[index];
    row.entry = e;
    row.isActiveRoute = [self routeMatchesEntry:e];
    row.windowActive = _windowActive;
}

- (void)didSelectIndex:(NSUInteger)index {
    if (index >= _entries.count) return;
    SPSidebarEntry *e = _entries[index];
    if (e.kind == SPSidebarEntryHeader) return;
    if (_onSelectEntry) _onSelectEntry(e);
}

- (void)didActivateIndex:(NSUInteger)index {
    [self didSelectIndex:index];
}

@end

#pragma mark - SPSidebarFooterView

@interface SPSidebarFooterView : NSView
@property (nonatomic, strong, nullable) SPUserProfile *profile;
@property (nonatomic) BOOL profileSelected;
@property (nonatomic, copy, nullable) void (^onOpenProfile)(void);
@property (nonatomic, copy, nullable) void (^onOpenSettings)(void);
@end

@implementation SPSidebarFooterView {
    SPButton *_settingsBtn;
    NSTrackingArea *_tracking;
    BOOL _profileHovered;
    NSString *_lastAvatarURL;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _settingsBtn = [SPButton iconButton:SPIconSettings size:14.5 frame:NSZeroRect];
    _settingsBtn.toolTip = @"Settings";
    __weak typeof(self) weakSelf = self;
    _settingsBtn.onClick = ^{
        if (weakSelf.onOpenSettings) weakSelf.onOpenSettings();
    };
    [self addSubview:_settingsBtn];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (void)setProfile:(SPUserProfile *)profile {
    if (![_lastAvatarURL isEqualToString:profile.avatarURL ?: @""]) {
        [self.imageHolder removeAllImages];
        _lastAvatarURL = [profile.avatarURL copy];
    }
    _profile = profile;
    self.needsDisplay = YES;
}

- (void)setProfileSelected:(BOOL)profileSelected {
    if (_profileSelected == profileSelected) return;
    _profileSelected = profileSelected;
    self.needsDisplay = YES;
}

- (NSRect)profileButtonRect {
    return NSMakeRect(10.0, 4.0, MAX(40.0, self.bounds.size.width - 46.0), 34.0);
}

- (void)layout {
    [super layout];
    _settingsBtn.frame = NSMakeRect(self.bounds.size.width - 34.0, 9.0, 24.0, 24.0);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL over = NSPointInRect(pt, [self profileButtonRect]);
    if (over != _profileHovered) { _profileHovered = over; self.needsDisplay = YES; }
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (_profileHovered) { _profileHovered = NO; self.needsDisplay = YES; }
}

- (void)mouseDown:(NSEvent *)event {
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(pt, [self profileButtonRect]) && _onOpenProfile) {
        _onOpenProfile();
        return;
    }
    [super mouseDown:event];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    NSRect profRect = [self profileButtonRect];
    if (_profileSelected || _profileHovered) {
        NSColor *bg = _profileSelected ? SPQuaternaryFillColor() : SPHoverFillColor();
        CGContextSetFillColorWithColor(ctx, bg.CGColor);
        CGPathRef p = CGPathCreateWithRoundedRect(profRect, 7.0, 7.0, NULL);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
    }

    CGRect avatarRect = CGRectMake(profRect.origin.x + 8.0, floor(profRect.origin.y + (profRect.size.height - 22.0) * 0.5), 22.0, 22.0);
    CGImageRef avatarImg = NULL;
    if (_profile.avatarURL.length) {
        NSURL *u = [NSURL URLWithString:_profile.avatarURL];
        if (u) {
            CGFloat scale = self.window.backingScaleFactor ?: 2.0;
            avatarImg = [self.imageHolder imageWithURL:u pixels:ceil(22.0 * scale)];
        }
    }
    SPDrawProfileAvatar(ctx, avatarImg, _profile.displayName, avatarRect);

    NSString *name = _profile.displayName.length ? _profile.displayName : @"Profile";
    CGFloat textX = CGRectGetMaxX(avatarRect) + 8.0;
    CGFloat textW = MAX(20.0, NSMaxX(profRect) - textX - 8.0);
    NSDictionary *attrs = SPSemanticTextAttributes(SPThemeTypography()->body, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
    [name drawInRect:NSMakeRect(textX, floor(profRect.origin.y + (profRect.size.height - 17.0) * 0.5), textW, 18.0)
      withAttributes:attrs];
}

@end

#pragma mark - SPSidebarView

@implementation SPSidebarView {
    SPStore *_store;
    NSVisualEffectView *_backdrop;
    SPSidebarListView *_list;
    SPSidebarFooterView *_footer;
    NSInteger _lastQueueCount;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _lastQueueCount = -1;

    // Genuine macOS translucent sidebar material adapting automatically to Light & Dark Mode.
    _backdrop = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    _backdrop.material = NSVisualEffectMaterialSidebar;
    _backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _backdrop.state = NSVisualEffectStateFollowsWindowActiveState;
    [self addSubview:_backdrop];

    // Disable automatic scroll insets and use deterministic 44pt topInset (exact match to Spotifly 38.png).
    _list = [[SPSidebarListView alloc] initWithFrame:self.bounds];
    _list.scrollView.automaticallyAdjustsContentInsets = NO;
    _list.topInset = 44.0;
    _list.bottomInset = 8.0;
    _list.windowActive = YES;
    __weak typeof(self) weakSelf = self;
    _list.onSelectEntry = ^(SPSidebarEntry *entry) {
        [weakSelf handleEntrySelection:entry];
    };
    [self addSubview:_list];

    _footer = [[SPSidebarFooterView alloc] initWithFrame:NSZeroRect];
    _footer.profile = _store.userProfile;
    _footer.onOpenProfile = ^{
        [weakSelf.navigator openProfile];
    };
    _footer.onOpenSettings = ^{
        [weakSelf.navigator openPreferences];
    };
    [self addSubview:_footer];

    [_store addObserver:self];
    [self reloadItems];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_store removeObserver:self];
}

- (BOOL)isFlipped { return YES; }

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (self.window) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:self.window];
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:self.window];
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeMainNotification object:self.window];
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignMainNotification object:self.window];
    }
    [super viewWillMoveToWindow:newWindow];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowActiveChanged:) name:NSWindowDidBecomeKeyNotification object:self.window];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowActiveChanged:) name:NSWindowDidResignKeyNotification object:self.window];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowActiveChanged:) name:NSWindowDidBecomeMainNotification object:self.window];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowActiveChanged:) name:NSWindowDidResignMainNotification object:self.window];
        [self syncWindowActiveState];
    }
}

- (void)windowActiveChanged:(NSNotification *)note {
    (void)note;
    [self syncWindowActiveState];
}

- (void)syncWindowActiveState {
    // Keep active = YES in headless tests / initial render before window becomes key.
    BOOL active = (!self.window || self.window.isKeyWindow || self.window.isMainWindow || !NSApp.isActive);
    if (NSApp.isActive && self.window && !self.window.isKeyWindow && !self.window.isMainWindow) {
        active = NO;
    }
    if (_list.windowActive != active) {
        _list.windowActive = active;
        [_list refreshKeys:[NSSet setWithArray:_list.keys]];
    }
}

- (void)setActiveRoute:(SPRoute *)activeRoute {
    if ([_activeRoute isEqual:activeRoute]) return;
    _activeRoute = activeRoute;
    _list.activeRoute = activeRoute;
    _footer.profileSelected = (activeRoute.kind == SPRouteProfile);
    [_list refreshKeys:[NSSet setWithArray:_list.keys]];
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat footerH = 46.0;
    _backdrop.frame = self.bounds;
    _list.frame = NSMakeRect(0.0, 0.0, w, MAX(0.0, h - footerH));
    _footer.frame = NSMakeRect(0.0, MAX(0.0, h - footerH), w, footerH);
}

static SPSidebarEntry *NavEntry(NSString *key, NSString *title, SPIconName icon, SPRoute *route, NSString *_Nullable badge) {
    SPSidebarEntry *e = [SPSidebarEntry new];
    e.kind = SPSidebarEntryNav;
    e.key = key;
    e.title = title;
    e.icon = icon;
    e.route = route;
    e.badge = badge;
    return e;
}

static SPSidebarEntry *HeaderEntry(NSString *key, NSString *title) {
    SPSidebarEntry *e = [SPSidebarEntry new];
    e.kind = SPSidebarEntryHeader;
    e.key = key;
    e.title = title;
    return e;
}

- (NSInteger)upcomingQueueCount {
    SPPlaybackState *pb = _store.playbackState;
    NSInteger count = 0;
    for (SPQueueTrack *qt in pb.nextTracks) {
        if (!qt.isHidden && !qt.isDelimiter) count++;
    }
    return count;
}

- (void)reloadItems {
    NSInteger qCount = [self upcomingQueueCount];
    _lastQueueCount = qCount;
    NSString *queueBadge = qCount > 0 ? [NSString stringWithFormat:@"%ld", (long)qCount] : nil;

    // Exact 1:1 Spotifly SidebarView order, labels, and SF Symbols
    NSArray<SPSidebarEntry *> *entries = @[
        NavEntry(@"nav:startpage", @"Startpage", SPIconHome, [SPRoute home], nil),
        NavEntry(@"nav:search", @"Search", SPIconSearch, [SPRoute search], nil),
        NavEntry(@"nav:queue", @"Queue", SPIconQueue, [SPRoute queue], queueBadge),
        NavEntry(@"nav:speakers", @"Playing On", SPIconDevices, [SPRoute speakers], nil),

        HeaderEntry(@"hdr:library", @"Library"),
        NavEntry(@"nav:favorites", @"Favorites", SPIconHeartFilled, [SPRoute favorites], nil),
        NavEntry(@"nav:playlists", @"Playlists", SPIconPlaylist, [SPRoute playlists], nil),
        NavEntry(@"nav:albums", @"Albums", SPIconAlbum, [SPRoute albums], nil),
        NavEntry(@"nav:artists", @"Artists", SPIconArtist, [SPRoute artists], nil),
    ];

    _list.activeRoute = _activeRoute;
    _list.entries = entries;
    _footer.profile = _store.userProfile;
    _footer.profileSelected = (_activeRoute.kind == SPRouteProfile);
}

- (void)handleEntrySelection:(SPSidebarEntry *)entry {
    SPRoute *r = entry.route;
    if (!r) return;
    switch (r.kind) {
        case SPRouteHome: [_navigator openHome]; break;
        case SPRouteSearch: [_navigator openSearchWithQuery:nil focus:YES]; break;
        case SPRouteQueue: [_navigator openQueue]; break;
        case SPRouteSpeakers: [_navigator openSpeakers]; break;
        case SPRouteFavorites: [_navigator openFavorites]; break;
        case SPRoutePlaylists: [_navigator openPlaylists]; break;
        case SPRouteAlbums: [_navigator openAlbums]; break;
        case SPRouteArtists: [_navigator openArtists]; break;
        default: break;
    }
}

- (void)storeChanged:(SPChange *)change {
    if (change.profile) {
        _footer.profile = _store.userProfile;
    }
    if (change.playback) {
        NSInteger qCount = [self upcomingQueueCount];
        if (qCount != _lastQueueCount) {
            [self reloadItems];
        }
    }
}

@end
