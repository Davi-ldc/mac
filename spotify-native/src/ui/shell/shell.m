// Main window shell matching Spotifly 1:1:
// Native translucent NSVisualEffectView sidebar + draggable split handle + transparent full-size-content glass header
// (sidebar toggle, leading Refresh, bold page title, centered wide Search capsule, contextual +/Sort, far-right <|> Back/Forward),
// 2/3-column content region, optional 320pt Now Playing Inspector, and real NSGlassEffectView Floating Now Playing capsule.
#import "ui/shell/shell.h"
#import "model/json.h"
#import "net/hashes.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"
#import "ui/detail/detail.h"
#import "ui/home/home.h"
#import "ui/library/library.h"
#import "ui/search/search.h"

static NSString *const kSPVolumeDefaultsKey = @"sp.volumePercent";
static NSString *const kSPSidebarWidthDefaultsKey = @"sp.sidebarColumnWidth";

@interface SPShellContentHostView : NSView
@property (nonatomic, copy, nullable) void (^onLayout)(void);
@end

@implementation SPShellContentHostView
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    if (_onLayout) _onLayout();
}
@end

@interface SPShellDetailAreaView : NSView
@property (nonatomic, copy, nullable) void (^onLayout)(void);
@end

@implementation SPShellDetailAreaView
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    if (_onLayout) _onLayout();
}
@end

@interface SPThinDividerView : NSView
@end

@implementation SPThinDividerView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [SPSeparatorColor() setFill];
    NSRectFill(self.bounds);
}
@end

/// Lightweight circular macOS 27 translucent glass toolbar button (zero NSToolbar / CoreSVG overhead).
@interface SPGlassCircleButton : NSView
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic) CGFloat iconSize;
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end

@implementation SPGlassCircleButton {
    NSTrackingArea *_tracking;
    BOOL _hovered;
    BOOL _pressed;
}

- (instancetype)initWithFrame:(NSRect)frame symbolName:(NSString *)symbolName {
    if (!(self = [super initWithFrame:frame])) return nil;
    _symbolName = [symbolName copy] ?: @"";
    _iconSize = 13.5;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setSymbolName:(NSString *)symbolName {
    if ([_symbolName isEqualToString:symbolName]) return;
    _symbolName = [symbolName copy] ?: @"";
    self.needsDisplay = YES;
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

- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; _pressed = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    _pressed = YES;
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    BOOL wasPressed = _pressed;
    _pressed = NO;
    self.needsDisplay = YES;
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if (wasPressed && NSPointInRect(pt, self.bounds) && _onClick) {
        _onClick();
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    CGFloat r = MIN(b.size.width, b.size.height) * 0.5;
    BOOL dark = SPIsDarkAppearance(self.effectiveAppearance);
    CGFloat fillAlpha = dark
        ? (_pressed ? 0.20 : (_hovered ? 0.14 : 0.085))
        : (_pressed ? 0.15 : (_hovered ? 0.10 : 0.055));
    NSColor *bg = [NSColor colorWithWhite:dark ? 1.0 : 0.0 alpha:fillAlpha];
    NSColor *border = [NSColor colorWithWhite:dark ? 1.0 : 0.0 alpha:dark ? 0.14 : 0.10];

    CGPathRef p = CGPathCreateWithRoundedRect(b, r, r, NULL);
    CGContextSetFillColorWithColor(ctx, bg.CGColor);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGContextSetStrokeColorWithColor(ctx, border.CGColor);
    CGContextSetLineWidth(ctx, 0.75);
    CGContextAddPath(ctx, p);
    CGContextStrokePath(ctx);
    CGPathRelease(p);

    if (_symbolName.length) {
        SPDrawSFSymbol(_symbolName, self.bounds, _iconSize, NSFontWeightMedium, SPLabelColor());
    }
}

@end

/// Draggable 1pt sidebar split divider with 7pt hit target and resizeLeftRightCursor.
@interface SPSplitResizeHandleView : NSView
@property (nonatomic, copy, nullable) void (^onDragDelta)(CGFloat deltaX);
@property (nonatomic, copy, nullable) void (^onDragEnd)(void);
@end

@implementation SPSplitResizeHandleView {
    CGFloat _lastScreenX;
    BOOL _dragging;
}

- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor];
}

- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    _lastScreenX = NSEvent.mouseLocation.x;
    (void)event;
}

- (void)mouseDragged:(NSEvent *)event {
    (void)event;
    if (!_dragging) return;
    CGFloat nowX = NSEvent.mouseLocation.x;
    CGFloat dx = nowX - _lastScreenX;
    _lastScreenX = nowX;
    if (fabs(dx) > 0.1 && _onDragDelta) _onDragDelta(dx);
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (_dragging) {
        _dragging = NO;
        if (_onDragEnd) _onDragEnd();
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat midX = floor(self.bounds.size.width * 0.5);
    [SPSeparatorColor() setFill];
    NSRectFill(NSMakeRect(midX, 0.0, 1.0, self.bounds.size.height));
}

@end

/// Unified Spotifly 52pt content titlebar header (draggable window background + bold page title + glass controls).
@interface SPTitlebarHeaderView : NSView
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic) CGFloat titleX;
@property (nonatomic) CGFloat titleMaxWidth;
@end

@implementation SPTitlebarHeaderView

- (BOOL)isFlipped { return YES; }

- (void)setTitleText:(NSString *)titleText {
    if ([_titleText isEqualToString:titleText]) return;
    _titleText = [titleText copy] ?: @"";
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        [self.window zoom:nil];
        return;
    }
    [self.window performWindowDragWithEvent:event];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect b = self.bounds;
    // Leave header background transparent so the native NSWindow surface (rgb(34,34,34) dark / rgb(255,255,255) light)
    // flows seamlessly from titlebar into page content (1:1 Spotifly 38.png match).
    if (_titleText.length && _titleMaxWidth > 20.0) {
        SPTextStyle titleStyle = {15.0, NSFontWeightSemibold, 19.0, -0.1, NO};
        NSDictionary *attrs = SPSemanticTextAttributes(titleStyle, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        [_titleText drawInRect:NSMakeRect(_titleX, floor((b.size.height - 19.0) * 0.5), _titleMaxWidth, 20.0)
                withAttributes:attrs];
    }
}

@end

/// Transparent drag strip over the top 42pt of the sidebar so dragging beside traffic lights moves the window.
@interface SPSidebarDragStripView : NSView
@end

@implementation SPSidebarDragStripView
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        [self.window zoom:nil];
        return;
    }
    [self.window performWindowDragWithEvent:event];
}
@end

@implementation SPShell {
    SPStore *_store;
    NSUserDefaults *_defaults;
    SPWindow *_window;

    SPShellContentHostView *_rootView;
    SPSidebarView *_sidebar;
    SPSidebarDragStripView *_sidebarDragStrip;
    SPSplitResizeHandleView *_splitHandle;
    SPGlassCircleButton *_sidebarToggleBtn;
    CGFloat _sidebarWidth;
    BOOL _sidebarCollapsed;

    SPShellDetailAreaView *_detailAreaView;
    SPTitlebarHeaderView *_headerBar;
    SPShellContentHostView *_contentRegion;
    SPThinDividerView *_threeColDivider;
    SPLibraryListView *_libraryListView;
    NSView *_currentContentView;
    SPNowPlayingInspectorView *_inspectorView;
    SPPlayerBarView *_playerBar;
    SPSpeakersPopover *_speakersPopover;

    // Lightweight translucent glass titlebar controls (zero NSToolbar RAM overhead)
    SPGlassCircleButton *_leadingToolbarBtn;
    SPSearchField *_toolbarSearchField;
    SPGlassCircleButton *_newPlaylistToolbarBtn;
    NSPopUpButton *_albumSortPopup;
    SPSegmentedControl *_navHistoryControl;
    SPAlbumSortOrder _albumSortOrder;

    // Navigation & state
    SPRoute *_currentRoute;
    NSMutableArray<SPRoute *> *_backStack;
    NSMutableArray<SPRoute *> *_forwardStack;
    SPRoute *_routeBeforeSearch;
    NSString *_lastSelectedPlaylistID;
    NSString *_lastSelectedAlbumID;
    NSString *_lastSelectedArtistID;
    BOOL _inspectorOpen;
    NSInteger _volumePercent;
    BOOL _muted;
    NSRect _lastWindowFrame;
    BOOL _hasLastWindowFrame;
    NSTimer *_volumeThrottleTimer;
    NSInteger _pendingVolumePercent;

    // Startpage userTopContent cache per range ("SHORT_TERM", "MID_TERM", "LONG_TERM")
    NSMutableDictionary<NSString *, NSArray<SPTrack *> *> *_topTracksCache;
    NSMutableDictionary<NSString *, NSArray<SPArtist *> *> *_topArtistsCache;
    SPCancelToken *_topContentToken;
}

- (instancetype)initWithStore:(SPStore *)store
                  audioEngine:(id<SPAudioEngine>)audioEngine
                    netClient:(SPNetClient *)netClient
                connectClient:(SPConnectClient *)connectClient
                     defaults:(NSUserDefaults *)defaults {
    if (!(self = [super init])) return nil;
    _store = store;
    _audioEngine = audioEngine;
    _netClient = netClient;
    _connectClient = connectClient;
    _defaults = defaults ?: NSUserDefaults.standardUserDefaults;
    _songRadioEnabled = YES;

    _currentRoute = [SPRoute home];
    _backStack = [NSMutableArray new];
    _forwardStack = [NSMutableArray new];
    _topTracksCache = [NSMutableDictionary new];
    _topArtistsCache = [NSMutableDictionary new];

    if ([_defaults objectForKey:kSPVolumeDefaultsKey] != nil) {
        _volumePercent = MIN(100, MAX(0, [_defaults integerForKey:kSPVolumeDefaultsKey]));
    } else {
        _volumePercent = 80;
    }
    [_audioEngine setVolumePercent:_volumePercent];

    _searchController = [[SPSearchController alloc] initWithStore:_store client:(SPNetClient * _Nonnull)_netClient];
    _searchController.delegate = self;
    [_store addObserver:self];
    return self;
}

- (void)dealloc {
    [_topContentToken cancel];
    [_volumeThrottleTimer invalidate];
    [_store removeObserver:self];
    [self closeWindowReleasingViews];
}

#pragma mark - Public Accessors

- (SPWindow *)window { return _window; }
- (SPSearchField *)toolbarSearchField { return _toolbarSearchField; }
- (NSView *)currentContentView { return _currentContentView; }
- (SPSidebarView *)sidebarView { return _sidebar; }
- (SPPlayerBarView *)playerBarView { return _playerBar; }
- (BOOL)isWindowOpen { return _window != nil; }
- (SPRoute *)currentRoute { return _currentRoute; }
- (BOOL)canGoBack { return _backStack.count > 0; }
- (BOOL)canGoForward { return _forwardStack.count > 0; }
- (BOOL)queueDrawerOpen { return _inspectorOpen; }
- (BOOL)inspectorOpen { return _inspectorOpen; }

- (void)setNetClient:(SPNetClient *)netClient {
    _netClient = netClient;
    _searchController = [[SPSearchController alloc] initWithStore:_store client:(SPNetClient * _Nonnull)_netClient];
    _searchController.delegate = self;
}

#pragma mark - Window Lifecycle (Native Translucent Sidebar + Transparent Glass Header)

- (SPWindow *)ensureWindow {
    if (_window) return _window;

    const SPLayoutMetrics *m = SPThemeMetrics();
    CGFloat savedSidebarW = [_defaults doubleForKey:kSPSidebarWidthDefaultsKey];
    if (savedSidebarW < m->sidebarMinWidth || savedSidebarW > m->sidebarMaxWidth) {
        savedSidebarW = m->sidebarWidth;
    }
    _sidebarWidth = savedSidebarW;

    NSRect initialRect = _hasLastWindowFrame ? _lastWindowFrame : NSMakeRect(0.0, 0.0, 1220.0, 760.0);
    NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                             NSWindowStyleMaskFullSizeContentView;
    _window = [[SPWindow alloc] initWithContentRect:initialRect
                                          styleMask:mask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Startpage";
    _window.delegate = self;

    __weak typeof(self) weakSelf = self;
    _window.onSpaceTogglePlayPause = ^{ [weakSelf togglePlayPause]; };
    _window.onFocusSearch = ^{ [weakSelf focusSearchFieldSelectingAll:YES]; };
    _window.onNavigateBack = ^{ [weakSelf goBack]; };
    _window.onNavigateForward = ^{ [weakSelf goForward]; };

    _rootView = [[SPShellContentHostView alloc] initWithFrame:NSMakeRect(0.0, 0.0, initialRect.size.width, initialRect.size.height)];
    _rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _rootView.onLayout = ^{ [weakSelf layoutRoot]; };
    _window.contentView = _rootView;

    // Translucent native macOS sidebar (full height behind transparent titlebar)
    _sidebar = [[SPSidebarView alloc] initWithFrame:NSMakeRect(0.0, 0.0, _sidebarWidth, initialRect.size.height)
                                              store:_store
                                          navigator:self];
    [_rootView addSubview:_sidebar];

    _sidebarDragStrip = [[SPSidebarDragStripView alloc] initWithFrame:NSZeroRect];
    [_rootView addSubview:_sidebarDragStrip];

    // Right detail area: 52pt transparent Spotifly titlebar header + 2/3-column content + optional 320pt Inspector
    _detailAreaView = [[SPShellDetailAreaView alloc] initWithFrame:NSZeroRect];
    _detailAreaView.onLayout = ^{ [weakSelf layoutDetailArea]; };
    [_rootView addSubview:_detailAreaView];

    _headerBar = [[SPTitlebarHeaderView alloc] initWithFrame:NSZeroRect];
    _headerBar.titleText = @"Startpage";
    [_detailAreaView addSubview:_headerBar];

    _leadingToolbarBtn = [[SPGlassCircleButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 28.0, 28.0) symbolName:@"arrow.clockwise"];
    _leadingToolbarBtn.toolTip = @"Refresh";
    _leadingToolbarBtn.onClick = ^{ [weakSelf leadingToolbarAction:nil]; };
    [_headerBar addSubview:_leadingToolbarBtn];

    _toolbarSearchField = [[SPSearchField alloc] initWithFrame:NSMakeRect(0.0, 0.0, 420.0, 30.0)];
    _toolbarSearchField.onTextChange = ^(NSString *text) {
        [weakSelf handleSearchInputChanged:text];
    };
    _toolbarSearchField.onSubmit = ^(NSString *text) {
        SPShell *s = weakSelf;
        if (!s) return;
        if (s->_currentRoute.kind == SPRouteFavorites) return;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length) {
            [s->_store recordRecentSearch:trimmed];
            [s handleSearchInputChanged:trimmed];
        }
    };
    _toolbarSearchField.onEscape = ^{
        [weakSelf handleSearchEscaped];
    };
    [_headerBar addSubview:_toolbarSearchField];

    _navHistoryControl = [SPSegmentedControl momentaryControlWithIcons:@[ @(SPIconBack), @(SPIconForward) ] iconSize:12.5];
    _navHistoryControl.onSelectSegment = ^(NSInteger idx) {
        if (idx == 0) [weakSelf goBack];
        else if (idx == 1) [weakSelf goForward];
    };
    [_headerBar addSubview:_navHistoryControl];

    _contentRegion = [[SPShellContentHostView alloc] initWithFrame:NSZeroRect];
    _contentRegion.onLayout = ^{ [weakSelf layoutContentRegion]; };
    [_detailAreaView addSubview:_contentRegion];

    _playerBar = [[SPPlayerBarView alloc] initWithFrame:NSZeroRect store:_store navigator:self];
    _playerBar.volumePercent = _volumePercent;
    _playerBar.muted = _muted;
    _playerBar.inspectorOpen = _inspectorOpen;
    [_contentRegion addSubview:_playerBar];

    if (_inspectorOpen) {
        _inspectorView = [[SPNowPlayingInspectorView alloc] initWithFrame:NSZeroRect store:_store navigator:self];
        [_detailAreaView addSubview:_inspectorView];
    }

    // Draggable sidebar split handle + circular glass sidebar toggle button overlaid above sidebar/header
    _splitHandle = [[SPSplitResizeHandleView alloc] initWithFrame:NSZeroRect];
    _splitHandle.onDragDelta = ^(CGFloat dx) {
        SPShell *s = weakSelf;
        if (!s) return;
        const SPLayoutMetrics *lm = SPThemeMetrics();
        s->_sidebarWidth = MIN(lm->sidebarMaxWidth, MAX(lm->sidebarMinWidth, s->_sidebarWidth + dx));
        [s layoutRoot];
    };
    _splitHandle.onDragEnd = ^{
        SPShell *s = weakSelf;
        if (s) [s->_defaults setDouble:s->_sidebarWidth forKey:kSPSidebarWidthDefaultsKey];
    };
    [_rootView addSubview:_splitHandle];

    _sidebarToggleBtn = [[SPGlassCircleButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 28.0, 28.0) symbolName:@"sidebar.left"];
    _sidebarToggleBtn.toolTip = @"Toggle Sidebar";
    _sidebarToggleBtn.onClick = ^{ [weakSelf toggleSidebar]; };
    [_rootView addSubview:_sidebarToggleBtn];

    if (_hasLastWindowFrame) {
        [_window setFrame:_lastWindowFrame display:NO];
    }
    if (_currentRoute.kind == SPRouteSearch && _searchController.currentQuery.length > 0) {
        _toolbarSearchField.stringValue = _searchController.currentQuery;
    }
    [self mountRoute:_currentRoute];
    [self syncToolbarForRoute:_currentRoute];
    [self syncNavigationButtons];
    [self layoutRoot];
    [_window layoutIfNeeded];
    return _window;
}

- (void)showWindow {
    BOOL shouldCenter = (!_window && !_hasLastWindowFrame);
    SPWindow *win = [self ensureWindow];
    if (shouldCenter) [win center];
    [win makeKeyAndOrderFront:nil];
}

- (void)toggleSidebar {
    _sidebarCollapsed = !_sidebarCollapsed;
    [self layoutRoot];
}

- (void)tearDownViewsForWindow:(SPWindow *)win {
    if (win) {
        _lastWindowFrame = win.frame;
        _hasLastWindowFrame = YES;
        const SPLayoutMetrics *m = SPThemeMetrics();
        if (_sidebarWidth >= m->sidebarMinWidth && _sidebarWidth <= m->sidebarMaxWidth) {
            [_defaults setDouble:_sidebarWidth forKey:kSPSidebarWidthDefaultsKey];
        }
    }
    [_topContentToken cancel];
    _topContentToken = nil;
    [_volumeThrottleTimer invalidate];
    _volumeThrottleTimer = nil;
    [_speakersPopover close];
    _speakersPopover = nil;
    [_playerBar stopProgressTimer];
    [_searchController cancel];

    if (_rootView) {
        SPReleaseViewImages(_rootView);
        _rootView.onLayout = nil;
    }
    if (_detailAreaView) {
        SPReleaseViewImages(_detailAreaView);
        _detailAreaView.onLayout = nil;
    }
    if (_contentRegion) {
        SPReleaseViewImages(_contentRegion);
        _contentRegion.onLayout = nil;
    }
    if (_currentContentView) {
        SPReleaseViewImages(_currentContentView);
        [_currentContentView removeFromSuperview];
    }
    if (_libraryListView) {
        SPReleaseViewImages(_libraryListView);
        [_libraryListView removeFromSuperview];
    }
    if (_inspectorView) {
        SPReleaseViewImages(_inspectorView);
        [_inspectorView removeFromSuperview];
    }
    if (_playerBar) {
        SPReleaseViewImages(_playerBar);
        [_playerBar removeFromSuperview];
    }
    if (_sidebar) {
        SPReleaseViewImages(_sidebar);
        [_sidebar removeFromSuperview];
    }

    win.contentView = nil;

    _currentContentView = nil;
    _libraryListView = nil;
    _threeColDivider = nil;
    _inspectorView = nil;
    _playerBar = nil;
    _contentRegion = nil;
    _headerBar = nil;
    _detailAreaView = nil;
    _sidebar = nil;
    _sidebarDragStrip = nil;
    _splitHandle = nil;
    _sidebarToggleBtn = nil;
    _rootView = nil;
    _leadingToolbarBtn = nil;
    _toolbarSearchField = nil;
    _newPlaylistToolbarBtn = nil;
    _albumSortPopup = nil;
    _navHistoryControl = nil;

    [_store.database releaseMemory];
}

- (void)closeWindowReleasingViews {
    if (!_window) return;
    SPWindow *win = _window;
    _window = nil;
    win.delegate = nil;

    [self tearDownViewsForWindow:win];
    [win orderOut:nil];
    [win close];

    if (_onWindowClosed) _onWindowClosed();
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == _window) {
        SPWindow *win = _window;
        _window = nil;
        win.delegate = nil;
        [self tearDownViewsForWindow:win];
        if (_onWindowClosed) _onWindowClosed();
    }
}

#pragma mark - Header Controls & Route Synchronization

- (void)leadingToolbarAction:(id)sender {
    (void)sender;
    if (_currentRoute.kind == SPRouteQueue) {
        if ([_currentContentView isKindOfClass:SPQueuePageView.class]) {
            [(SPQueuePageView *)_currentContentView scrollToCurrentTrack];
        }
    } else {
        [self refreshCurrentSection];
    }
}

- (void)toolbarNewPlaylist:(id)sender {
    (void)sender;
    [self promptCreatePlaylist];
}

- (void)albumSortChanged:(NSPopUpButton *)sender {
    _albumSortOrder = (SPAlbumSortOrder)sender.indexOfSelectedItem;
    if (_libraryListView.kind == SPLibraryListAlbums) {
        _libraryListView.albumSortOrder = _albumSortOrder;
    }
}

- (void)syncToolbarForRoute:(SPRoute *)route {
    if (!_window) return;

    NSString *title = @"Startpage";
    switch (route.kind) {
        case SPRouteHome: title = @"Startpage"; break;
        case SPRouteSearch: title = @"Search"; break;
        case SPRouteQueue: title = @"Queue"; break;
        case SPRouteSpeakers: title = @"Playing On"; break;
        case SPRouteFavorites: title = @"Favorites"; break;
        case SPRoutePlaylists: title = @"Playlists"; break;
        case SPRouteAlbums: title = @"Albums"; break;
        case SPRouteArtists: title = @"Artists"; break;
        case SPRouteProfile: title = @"Profile"; break;
        case SPRoutePlaylistDetail: {
            SPPlaylist *pl = route.entityID.length ? [_store playlistWithID:route.entityID] : nil;
            title = pl.name.length ? pl.name : @"Playlists";
            break;
        }
        case SPRouteAlbumDetail: {
            SPAlbum *al = route.entityID.length ? [_store albumWithID:route.entityID] : nil;
            title = al.name.length ? al.name : @"Albums";
            break;
        }
        case SPRouteArtistDetail: {
            SPArtist *ar = route.entityID.length ? [_store artistWithID:route.entityID] : nil;
            title = ar.name.length ? ar.name : @"Artists";
            break;
        }
    }
    _window.title = title;
    _headerBar.titleText = title;

    BOOL showRefresh = (route.kind == SPRouteHome || route.kind == SPRouteFavorites ||
                        route.kind == SPRoutePlaylists || route.kind == SPRoutePlaylistDetail ||
                        route.kind == SPRouteAlbums || route.kind == SPRouteAlbumDetail ||
                        route.kind == SPRouteArtists || route.kind == SPRouteArtistDetail);
    BOOL showScrollCurrent = (route.kind == SPRouteQueue);
    if (showScrollCurrent) {
        _leadingToolbarBtn.symbolName = @"arrow.down.to.line";
        _leadingToolbarBtn.toolTip = @"Scroll to Current Track";
        _leadingToolbarBtn.hidden = NO;
    } else if (showRefresh) {
        _leadingToolbarBtn.symbolName = @"arrow.clockwise";
        _leadingToolbarBtn.toolTip = @"Refresh";
        _leadingToolbarBtn.hidden = NO;
    } else {
        _leadingToolbarBtn.hidden = YES;
    }

    // Contextual trailing control (+ New Playlist on Playlists, Sort menu on Albums), lazily mounted only when needed.
    BOOL wantsPlaylistBtn = (route.kind == SPRoutePlaylists || route.kind == SPRoutePlaylistDetail);
    BOOL wantsAlbumSort = (route.kind == SPRouteAlbums || route.kind == SPRouteAlbumDetail);
    if (wantsPlaylistBtn) {
        if (!_newPlaylistToolbarBtn) {
            __weak typeof(self) weakSelf = self;
            _newPlaylistToolbarBtn = [[SPGlassCircleButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 28.0, 28.0) symbolName:@"plus"];
            _newPlaylistToolbarBtn.toolTip = @"New Playlist";
            _newPlaylistToolbarBtn.onClick = ^{ [weakSelf toolbarNewPlaylist:nil]; };
            [_headerBar addSubview:_newPlaylistToolbarBtn];
        }
        _newPlaylistToolbarBtn.hidden = NO;
        _albumSortPopup.hidden = YES;
    } else if (wantsAlbumSort) {
        if (!_albumSortPopup) {
            _albumSortPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 128.0, 26.0) pullsDown:NO];
            [_albumSortPopup addItemsWithTitles:@[ @"Recently Added", @"Title", @"Artist" ]];
            _albumSortPopup.target = self;
            _albumSortPopup.action = @selector(albumSortChanged:);
            _albumSortPopup.controlSize = NSControlSizeRegular;
            [_headerBar addSubview:_albumSortPopup];
        }
        [_albumSortPopup selectItemAtIndex:(NSInteger)_albumSortOrder];
        _albumSortPopup.hidden = NO;
        _newPlaylistToolbarBtn.hidden = YES;
    } else {
        _newPlaylistToolbarBtn.hidden = YES;
        _albumSortPopup.hidden = YES;
    }

    // Search field placeholder switches to "Search in Favorites" on Favorites (matching Spotifly LoggedInView)
    _toolbarSearchField.placeholderString = (route.kind == SPRouteFavorites)
        ? @"Search in Favorites"
        : @"Songs, Artists, Albums, Playlists";

    [self layoutHeaderBar];
}

#pragma mark - Layout (Sidebar + 52pt Glass Header + 2/3-Column Content + Inspector + Floating Liquid Glass Capsule)

- (void)layoutRoot {
    if (!_rootView) return;
    CGFloat w = _rootView.bounds.size.width;
    CGFloat h = _rootView.bounds.size.height;
    CGFloat sbW = _sidebarCollapsed ? 0.0 : _sidebarWidth;

    _sidebar.hidden = _sidebarCollapsed;
    _sidebarDragStrip.hidden = _sidebarCollapsed;
    _splitHandle.hidden = _sidebarCollapsed;

    if (!_sidebarCollapsed) {
        _sidebar.frame = NSMakeRect(0.0, 0.0, sbW, h);
        _sidebarDragStrip.frame = NSMakeRect(0.0, 0.0, sbW, 42.0);
        _splitHandle.frame = NSMakeRect(sbW - 3.0, 0.0, 7.0, h);
        // Circular sidebar toggle sits right next to macOS traffic lights inside the sidebar header (matching 38.png).
        CGFloat toggleX = MAX(80.0, sbW - 40.0);
        _sidebarToggleBtn.frame = NSMakeRect(toggleX, 12.0, 28.0, 28.0);
    } else {
        _sidebarToggleBtn.frame = NSMakeRect(80.0, 12.0, 28.0, 28.0);
    }

    _detailAreaView.frame = NSMakeRect(sbW, 0.0, MAX(0.0, w - sbW), h);
    [self layoutDetailArea];
}

- (void)layoutHeaderBar {
    if (!_headerBar) return;
    CGFloat w = _headerBar.bounds.size.width;
    CGFloat h = _headerBar.bounds.size.height;

    // Leading: clear traffic lights + toggle button when sidebar is collapsed.
    CGFloat leftX = _sidebarCollapsed ? 118.0 : 16.0;
    if (!_leadingToolbarBtn.hidden) {
        _leadingToolbarBtn.frame = NSMakeRect(leftX, floor((h - 28.0) * 0.5), 28.0, 28.0);
        leftX += 28.0 + 10.0;
    }

    // Trailing: far-right <|> Back/Forward capsule + optional contextual +/Sort to its left.
    [_navHistoryControl sizeToFit];
    CGFloat navW = _navHistoryControl.frame.size.width;
    CGFloat navH = _navHistoryControl.frame.size.height;
    CGFloat rightEdge = w - 16.0 - navW;
    _navHistoryControl.frame = NSMakeRect(rightEdge, floor((h - navH) * 0.5), navW, navH);

    if (_newPlaylistToolbarBtn && !_newPlaylistToolbarBtn.hidden) {
        rightEdge -= (28.0 + 8.0);
        _newPlaylistToolbarBtn.frame = NSMakeRect(rightEdge, floor((h - 28.0) * 0.5), 28.0, 28.0);
    } else if (_albumSortPopup && !_albumSortPopup.hidden) {
        rightEdge -= (128.0 + 8.0);
        _albumSortPopup.frame = NSMakeRect(rightEdge, floor((h - 26.0) * 0.5), 128.0, 26.0);
    }

    // Measure page title width so centered search capsule never overlaps title or right controls.
    SPTextStyle titleStyle = {15.0, NSFontWeightSemibold, 19.0, -0.1, NO};
    NSDictionary *titleAttrs = SPSemanticTextAttributes(titleStyle, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft);
    CGFloat naturalTitleW = _headerBar.titleText.length ? ceil([_headerBar.titleText sizeWithAttributes:titleAttrs].width) + 4.0 : 0.0;

    // Center wide translucent Search capsule matching 38.png.
    CGFloat minSearchLeft = leftX + MIN(naturalTitleW, 180.0) + 16.0;
    CGFloat maxSearchRight = rightEdge - 16.0;
    CGFloat availCenter = MAX(140.0, maxSearchRight - minSearchLeft);
    CGFloat idealW = MIN(420.0, MAX(180.0, floor(w * 0.36)));
    CGFloat searchW = MIN(idealW, availCenter);
    CGFloat searchX = floor((w - searchW) * 0.5);
    if (searchX < minSearchLeft) searchX = minSearchLeft;
    if (searchX + searchW > maxSearchRight) searchX = MAX(minSearchLeft, maxSearchRight - searchW);
    _toolbarSearchField.frame = NSMakeRect(searchX, floor((h - 30.0) * 0.5), searchW, 30.0);

    _headerBar.titleX = leftX;
    _headerBar.titleMaxWidth = MAX(0.0, searchX - leftX - 12.0);
    _headerBar.needsDisplay = YES;
}

- (void)layoutDetailArea {
    if (!_detailAreaView) return;
    CGFloat w = _detailAreaView.bounds.size.width;
    CGFloat h = _detailAreaView.bounds.size.height;
    CGFloat topY = SPThemeMetrics()->toolbarHeight;
    CGFloat availH = MAX(0.0, h - topY);
    CGFloat inspW = (_inspectorOpen && _inspectorView) ? MIN(SPThemeMetrics()->inspectorWidth, MAX(240.0, floor(w * 0.34))) : 0.0;

    _headerBar.frame = NSMakeRect(0.0, 0.0, w, topY);
    [self layoutHeaderBar];

    _contentRegion.frame = NSMakeRect(0.0, topY, MAX(0.0, w - inspW), availH);
    if (_inspectorView) {
        _inspectorView.frame = NSMakeRect(w - inspW, topY, inspW, availH);
    }
    [self layoutContentRegion];
}

- (BOOL)isThreeColumnRoute:(SPRoute *)route {
    return route.kind == SPRoutePlaylists || route.kind == SPRoutePlaylistDetail ||
           route.kind == SPRouteAlbums || route.kind == SPRouteAlbumDetail ||
           route.kind == SPRouteArtists || route.kind == SPRouteArtistDetail;
}

- (void)layoutContentRegion {
    if (!_contentRegion) return;
    CGFloat w = _contentRegion.bounds.size.width;
    CGFloat h = _contentRegion.bounds.size.height;

    if (_libraryListView && [self isThreeColumnRoute:_currentRoute]) {
        // Spotifly 3-column split: list column clamp(190, 28%, 260) on left + 1pt divider + detail on right.
        CGFloat listW = MIN(260.0, MAX(185.0, floor(w * 0.28)));
        if (w < 440.0) listW = floor(w * 0.38);
        _libraryListView.frame = NSMakeRect(0.0, 0.0, listW, h);
        if (!_threeColDivider) {
            _threeColDivider = [[SPThinDividerView alloc] initWithFrame:NSZeroRect];
            [_contentRegion addSubview:_threeColDivider positioned:NSWindowBelow relativeTo:_playerBar];
        }
        _threeColDivider.hidden = NO;
        _threeColDivider.frame = NSMakeRect(listW, 0.0, 1.0, h);
        _currentContentView.frame = NSMakeRect(listW + 1.0, 0.0, MAX(0.0, w - listW - 1.0), h);
    } else {
        _threeColDivider.hidden = YES;
        _currentContentView.frame = _contentRegion.bounds;
    }

    // Floating Liquid Glass Now Playing capsule centered at bottom of contentRegion (columns 2 or 2+3).
    if (_playerBar) {
        const SPLayoutMetrics *m = SPThemeMetrics();
        CGFloat barH = m->nowPlayingBarHeight;
        CGFloat barW = MIN(m->nowPlayingBarMaxWidth, MAX(320.0, w - 40.0));
        CGFloat barX = floor((w - barW) * 0.5);
        CGFloat barY = MAX(0.0, h - barH - m->nowPlayingBarBottomPadding);
        _playerBar.frame = NSMakeRect(barX, barY, barW, barH);
    }
}

#pragma mark - Navigation & Route Mounting

- (void)navigateToRoute:(SPRoute *)route pushHistory:(BOOL)push {
    if (!route) return;
    SPRouteKind prevKind = _currentRoute.kind;

    // Auto-select first entity when entering a 3-column library section with no selection (matching Spotifly selectFirstIfNeeded).
    if (route.kind == SPRoutePlaylists) {
        NSString *pick = _lastSelectedPlaylistID.length ? _lastSelectedPlaylistID : _store.libraryPlaylists.firstObject.playlistID;
        if (pick.length) route = [SPRoute playlistWithID:pick];
    } else if (route.kind == SPRouteAlbums) {
        NSString *pick = _lastSelectedAlbumID.length ? _lastSelectedAlbumID : _store.libraryAlbums.firstObject.albumID;
        if (pick.length) route = [SPRoute albumWithID:pick];
    } else if (route.kind == SPRouteArtists) {
        NSString *pick = _lastSelectedArtistID.length ? _lastSelectedArtistID : _store.libraryArtists.firstObject.artistID;
        if (pick.length) route = [SPRoute artistWithID:pick];
    }

    if (route.kind == SPRoutePlaylistDetail && route.entityID.length) _lastSelectedPlaylistID = route.entityID;
    else if (route.kind == SPRouteAlbumDetail && route.entityID.length) _lastSelectedAlbumID = route.entityID;
    else if (route.kind == SPRouteArtistDetail && route.entityID.length) _lastSelectedArtistID = route.entityID;

    if (push && _currentRoute && ![_currentRoute isEqual:route]) {
        [_backStack addObject:_currentRoute];
        if (_backStack.count > 40) [_backStack removeObjectAtIndex:0];
        [_forwardStack removeAllObjects];
    }
    _currentRoute = route;

    if (_window) {
        if (route.kind != SPRouteSearch && route.kind != SPRouteFavorites && [_window isEditingText]) {
            [_window makeFirstResponder:nil];
        }
        // Clear filter text when entering/leaving Favorites (matching Spotifly LoggedInView lines 85-91).
        if (route.kind == SPRouteFavorites && prevKind != SPRouteFavorites) {
            _toolbarSearchField.stringValue = @"";
        } else if (prevKind == SPRouteFavorites && route.kind != SPRouteFavorites) {
            _toolbarSearchField.stringValue = (route.kind == SPRouteSearch) ? (_searchController.currentQuery ?: @"") : @"";
        }

        [self mountRoute:route];
        [self syncToolbarForRoute:route];
        [self syncNavigationButtons];
    }
}

- (void)ensureLibraryColumnForKind:(SPLibraryListKind)kind selectedID:(nullable NSString *)selectedID {
    if (!_libraryListView || _libraryListView.kind != kind) {
        if (_libraryListView) {
            SPReleaseViewImages(_libraryListView);
            [_libraryListView removeFromSuperview];
            _libraryListView = nil;
        }
        _libraryListView = [[SPLibraryListView alloc] initWithFrame:NSZeroRect kind:kind store:_store navigator:self];
        if (kind == SPLibraryListAlbums) _libraryListView.albumSortOrder = _albumSortOrder;
        [_contentRegion addSubview:_libraryListView positioned:NSWindowBelow relativeTo:_playerBar];
    }
    _libraryListView.selectedEntityID = selectedID;
}

- (void)removeLibraryColumnIfPresent {
    if (_libraryListView) {
        SPReleaseViewImages(_libraryListView);
        [_libraryListView removeFromSuperview];
        _libraryListView = nil;
    }
}

- (void)mountRoute:(SPRoute *)route {
    if (!_contentRegion) return;
    if (_currentContentView) {
        SPReleaseViewImages(_currentContentView);
        [_currentContentView removeFromSuperview];
        _currentContentView = nil;
    }

    NSRect bounds = _contentRegion.bounds;
    NSView *view = nil;

    if ([self isThreeColumnRoute:route]) {
        if (route.kind == SPRoutePlaylists || route.kind == SPRoutePlaylistDetail) {
            [self ensureLibraryColumnForKind:SPLibraryListPlaylists selectedID:route.entityID];
        } else if (route.kind == SPRouteAlbums || route.kind == SPRouteAlbumDetail) {
            [self ensureLibraryColumnForKind:SPLibraryListAlbums selectedID:route.entityID];
        } else {
            [self ensureLibraryColumnForKind:SPLibraryListArtists selectedID:route.entityID];
        }
    } else {
        [self removeLibraryColumnIfPresent];
    }

    switch (route.kind) {
        case SPRouteHome: {
            SPHomeView *hv = [[SPHomeView alloc] initWithFrame:bounds store:_store navigator:self];
            NSString *rk = hv.selectedRangeKey;
            if (_topTracksCache[rk] || _topArtistsCache[rk]) {
                [hv setTopTracks:_topTracksCache[rk] ?: @[] topArtists:_topArtistsCache[rk] ?: @[] forRange:rk];
            } else {
                [self requestTopContentForRange:rk];
            }
            view = hv;
            break;
        }
        case SPRouteSearch: {
            SPSearchView *sv = [[SPSearchView alloc] initWithFrame:bounds store:_store navigator:self];
            if (_searchController.currentResults) {
                [sv applyResults:_searchController.currentResults];
            }
            view = sv;
            break;
        }
        case SPRouteQueue:
            view = [[SPQueuePageView alloc] initWithFrame:bounds store:_store navigator:self];
            break;
        case SPRouteSpeakers: {
            SPSpeakersPageView *spv = [[SPSpeakersPageView alloc] initWithFrame:bounds store:_store navigator:self];
            spv.volumePercent = _volumePercent;
            view = spv;
            break;
        }
        case SPRouteProfile:
            view = [[SPProfileView alloc] initWithFrame:bounds store:_store navigator:self];
            break;
        case SPRouteFavorites:
            view = [[SPFavoritesView alloc] initWithFrame:bounds store:_store navigator:self];
            break;
        case SPRoutePlaylists:
            view = [[SPEmptyDetailView alloc] initWithFrame:bounds message:@"Select a playlist" symbolName:@"music.note.list"];
            break;
        case SPRouteAlbums:
            view = [[SPEmptyDetailView alloc] initWithFrame:bounds message:@"Select an album" symbolName:@"opticaldisc"];
            break;
        case SPRouteArtists:
            view = [[SPEmptyDetailView alloc] initWithFrame:bounds message:@"Select an artist" symbolName:@"mic.fill"];
            break;
        case SPRouteAlbumDetail:
            view = [[SPAlbumDetailView alloc] initWithFrame:bounds albumID:route.entityID ?: @"" store:_store navigator:self];
            [self fetchAlbumDetailsIfNeeded:route.entityID];
            break;
        case SPRouteArtistDetail:
            view = [[SPArtistDetailView alloc] initWithFrame:bounds artistID:route.entityID ?: @"" store:_store navigator:self];
            [self fetchArtistDetailsIfNeeded:route.entityID];
            break;
        case SPRoutePlaylistDetail:
            view = [[SPPlaylistDetailView alloc] initWithFrame:bounds playlistID:route.entityID ?: @"" store:_store navigator:self];
            [self fetchPlaylistDetailsIfNeeded:route.entityID];
            break;
    }

    _currentContentView = view;
    if (view) {
        // Insert BELOW the floating Liquid Glass playerBar so cards/rows scroll cleanly underneath the glass!
        [_contentRegion addSubview:view positioned:NSWindowBelow relativeTo:_playerBar];
    }
    _sidebar.activeRoute = route;
    [self layoutContentRegion];
}

- (void)syncNavigationButtons {
    [_navHistoryControl setEnabled:self.canGoBack forSegment:0];
    [_navHistoryControl setEnabled:self.canGoForward forSegment:1];
    _playerBar.inspectorOpen = _inspectorOpen;
}

#pragma mark - Startpage Top Content (userTopContent Pathfinder Query)

- (void)requestTopContentForRange:(NSString *)rangeKey {
    if (!rangeKey.length || !_netClient) return;
    if (_topTracksCache[rangeKey] != nil && _topArtistsCache[rangeKey] != nil) {
        if ([_currentContentView isKindOfClass:SPHomeView.class]) {
            [(SPHomeView *)_currentContentView setTopTracks:_topTracksCache[rangeKey]
                                                 topArtists:_topArtistsCache[rangeKey]
                                                   forRange:rangeKey];
        }
        return;
    }

    [_topContentToken cancel];
    NSDictionary *vars = @{
        @"includeTopArtists": @YES,
        @"topArtistsInput": @{@"offset": @0, @"limit": @10, @"sortBy": @"AFFINITY", @"timeRange": rangeKey},
        @"includeTopTracks": @YES,
        @"topTracksInput": @{@"offset": @0, @"limit": @10, @"sortBy": @"AFFINITY", @"timeRange": rangeKey},
    };
    __weak typeof(self) weakSelf = self;
    _topContentToken = [_netClient queryPathfinder:SPPathfinderOpUserTopContent variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err || !json) return;
        NSDictionary *data = SPJSONDict(json[@"data"]);
        NSDictionary *me = SPJSONDict(data[@"me"]);
        NSDictionary *profile = SPJSONDict(me[@"profile"]);
        NSDictionary *topTracksDict = SPJSONDict(profile[@"topTracks"]);
        NSDictionary *topArtistsDict = SPJSONDict(profile[@"topArtists"]);

        NSMutableArray<SPTrack *> *tracks = [NSMutableArray new];
        for (id raw in SPJSONArray(topTracksDict[@"items"])) {
            NSDictionary *entry = SPJSONDict(raw);
            NSDictionary *td = SPJSONDict(entry[@"data"]) ?: entry;
            SPTrack *t = [SPTrack trackFromPathfinderDict:td];
            if (t) [tracks addObject:t];
        }
        NSMutableArray<SPArtist *> *artists = [NSMutableArray new];
        for (id raw in SPJSONArray(topArtistsDict[@"items"])) {
            NSDictionary *entry = SPJSONDict(raw);
            NSDictionary *ad = SPJSONDict(entry[@"data"]) ?: entry;
            SPArtist *a = [SPArtist artistFromPathfinderDict:ad];
            if (a) [artists addObject:a];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            SPShell *s = weakSelf;
            if (!s) return;
            if (tracks.count) [s->_store upsertTracks:tracks];
            if (artists.count) [s->_store upsertArtists:artists];
            s->_topTracksCache[rangeKey] = tracks;
            s->_topArtistsCache[rangeKey] = artists;
            if ([s->_currentContentView isKindOfClass:SPHomeView.class]) {
                [(SPHomeView *)s->_currentContentView setTopTracks:tracks topArtists:artists forRange:rangeKey];
            }
        });
    }];
}

#pragma mark - On-Demand Detail Hydration & Section Refresh

- (void)refreshCurrentSection {
    if (!_netClient) return;
    __weak typeof(self) weakSelf = self;
    switch (_currentRoute.kind) {
        case SPRouteHome: {
            [_topTracksCache removeAllObjects];
            [_topArtistsCache removeAllObjects];
            [_netClient fetchHomeWithCompletion:^(SPHomePage *home, NSError *err) {
                if (err || !home) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    SPShell *s = weakSelf;
                    if (s) [s->_store applyHomePage:home];
                });
            }];
            if ([_currentContentView isKindOfClass:SPHomeView.class]) {
                [self requestTopContentForRange:((SPHomeView *)_currentContentView).selectedRangeKey];
            }
            break;
        }
        case SPRouteFavorites: {
            [_netClient fetchLikedSongsOffset:0 limit:50 completion:^(NSArray<SPTrack *> *tracks, NSArray<SPPlaylistItem *> *items, NSInteger total, NSInteger rawCount, NSError *err) {
                (void)items; (void)total; (void)rawCount;
                if (err || !tracks.count) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    SPShell *s = weakSelf;
                    if (!s) return;
                    [s->_store upsertTracks:tracks];
                    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:tracks.count];
                    for (SPTrack *t in tracks) [ids addObject:t.trackID];
                    [s->_store setLibraryTrackIDs:ids addedAtByID:nil];
                });
            }];
            break;
        }
        case SPRouteAlbumDetail:
            if (_currentRoute.entityID.length) [self fetchAlbumDetailsIfNeeded:_currentRoute.entityID];
            break;
        case SPRouteArtistDetail:
            if (_currentRoute.entityID.length) [self fetchArtistDetailsIfNeeded:_currentRoute.entityID];
            break;
        case SPRoutePlaylistDetail:
            if (_currentRoute.entityID.length) {
                [self fetchPlaylistPageForID:_currentRoute.entityID offset:0 basePlaylist:nil accumTracks:[NSMutableArray new] accumItems:[NSMutableArray new]];
            }
            break;
        default:
            break;
    }
}

- (void)fetchAlbumDetailsIfNeeded:(NSString *)albumID {
    if (!albumID.length || !_netClient) return;
    SPAlbum *existing = [_store albumWithID:albumID];
    if (existing.detailsLoaded && existing.trackIDs.count > 0) return;
    __weak typeof(self) weakSelf = self;
    [_netClient fetchAlbumWithID:albumID completion:^(SPAlbum *album, NSArray<SPTrack *> *tracks, NSError *err) {
        if (err || !album) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPShell *s = weakSelf;
            if (!s) return;
            if (tracks.count) [s->_store upsertTracks:tracks];
            [s->_store upsertAlbums:@[ album ]];
            if (s->_currentRoute.kind == SPRouteAlbumDetail && [s->_currentRoute.entityID isEqualToString:albumID]) {
                [s syncToolbarForRoute:s->_currentRoute];
            }
        });
    }];
}

- (void)fetchArtistDetailsIfNeeded:(NSString *)artistID {
    if (!artistID.length || !_netClient) return;
    SPArtist *existing = [_store artistWithID:artistID];
    if (existing.detailsLoaded && (existing.albumIDs.count > 0 || existing.topTrackIDs.count > 0)) return;
    __weak typeof(self) weakSelf = self;
    [_netClient fetchArtistOverviewWithID:artistID fullCompletion:^(SPArtist *artist, NSArray<SPAlbum *> *albums, NSArray<SPTrack *> *topTracks, NSError *err) {
        if (err || !artist) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPShell *s = weakSelf;
            if (!s) return;
            if (topTracks.count) [s->_store upsertTracks:topTracks];
            if (albums.count) [s->_store upsertAlbums:albums];
            [s->_store upsertArtists:@[ artist ]];
            if (s->_currentRoute.kind == SPRouteArtistDetail && [s->_currentRoute.entityID isEqualToString:artistID]) {
                [s syncToolbarForRoute:s->_currentRoute];
            }
        });
    }];
}

- (void)fetchPlaylistPageForID:(NSString *)playlistID
                        offset:(NSInteger)offset
                  basePlaylist:(nullable SPPlaylist *)basePlaylist
                   accumTracks:(NSMutableArray<SPTrack *> *)accumTracks
                    accumItems:(NSMutableArray<SPPlaylistItem *> *)accumItems {
    static const NSInteger kPageSize = 100;
    static const NSInteger kMaxItems = 10000;
    __weak typeof(self) weakSelf = self;
    [_netClient fetchPlaylistWithID:playlistID offset:offset limit:kPageSize completion:^(SPPlaylist *pl, NSArray<SPTrack *> *tracks, NSError *err) {
        if (err || !pl) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPShell *s = weakSelf;
            if (!s) return;
            SPPlaylist *meta = basePlaylist ?: pl;
            if (tracks.count) {
                [s->_store upsertTracks:tracks];
                [accumTracks addObjectsFromArray:tracks];
            }
            if (pl.items.count) [accumItems addObjectsFromArray:pl.items];

            NSInteger rawCount = (NSInteger)pl.items.count;
            NSInteger total = MAX(meta.totalTrackCount, pl.totalTrackCount);
            NSInteger nextOffset = offset + rawCount;
            BOOL hasMore = (rawCount > 0) && (nextOffset < kMaxItems) &&
                           (total > 0 ? (nextOffset < total) : (rawCount >= kPageSize));
            SPPlaylist *snapshot = [[SPPlaylist alloc] initWithPlaylistID:meta.playlistID
                                                                      uri:meta.uri
                                                                     name:meta.name
                                                      playlistDescription:meta.playlistDescription
                                                                  ownerID:meta.ownerID
                                                                ownerName:meta.ownerName
                                                               artworkURL:meta.artworkURL
                                                          artworkSmallURL:meta.artworkSmallURL
                                                                 isPublic:meta.isPublic
                                                                    items:[accumItems copy]
                                                          totalTrackCount:MAX(total, (NSInteger)accumItems.count)
                                                            detailsLoaded:!hasMore];
            [s->_store upsertPlaylists:@[ snapshot ]];
            if (hasMore) {
                [s fetchPlaylistPageForID:playlistID offset:nextOffset basePlaylist:meta accumTracks:accumTracks accumItems:accumItems];
            }
        });
    }];
}

- (void)fetchPlaylistDetailsIfNeeded:(NSString *)playlistID {
    if (!playlistID.length || !_netClient) return;
    SPPlaylist *existing = [_store playlistWithID:playlistID];
    if (existing.detailsLoaded && existing.items.count > 0) return;
    [self fetchPlaylistPageForID:playlistID offset:0 basePlaylist:nil accumTracks:[NSMutableArray new] accumItems:[NSMutableArray new]];
}

#pragma mark - Global Search Wiring

- (void)handleSearchInputChanged:(NSString *)text {
    // On Favorites, toolbar search field filters Favorites live (matching Spotifly LoggedInView).
    if (_currentRoute.kind == SPRouteFavorites) {
        if ([_currentContentView isKindOfClass:SPFavoritesView.class]) {
            ((SPFavoritesView *)_currentContentView).filterText = text ?: @"";
        }
        return;
    }

    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length > 0 && _currentRoute.kind != SPRouteSearch) {
        _routeBeforeSearch = _currentRoute;
        [self navigateToRoute:[SPRoute search] pushHistory:YES];
    }
    [_searchController updateQuery:text];
}

- (void)handleSearchEscaped {
    if (_currentRoute.kind == SPRouteFavorites) {
        if ([_currentContentView isKindOfClass:SPFavoritesView.class]) {
            ((SPFavoritesView *)_currentContentView).filterText = @"";
        }
        return;
    }
    [_searchController cancel];
    [_searchController updateQuery:@""];
    if (_currentRoute.kind == SPRouteSearch) {
        SPRoute *target = _routeBeforeSearch ?: [SPRoute home];
        _routeBeforeSearch = nil;
        if (_backStack.count > 0 && [_backStack.lastObject isEqual:target]) {
            [_backStack removeLastObject];
        }
        [self navigateToRoute:target pushHistory:NO];
    }
}

- (void)searchController:(SPSearchController *)controller didUpdateResults:(SPSearchResults *)results {
    (void)controller;
    if (_currentRoute.kind == SPRouteSearch && [_currentContentView isKindOfClass:SPSearchView.class]) {
        [(SPSearchView *)_currentContentView applyResults:results];
    }
}

#pragma mark - SPNavigator Routes

- (void)openHome { [self navigateToRoute:[SPRoute home] pushHistory:YES]; }

- (void)openSearchWithQuery:(NSString *)query focus:(BOOL)focus {
    if (_currentRoute.kind != SPRouteSearch) {
        _routeBeforeSearch = _currentRoute;
        [self navigateToRoute:[SPRoute search] pushHistory:YES];
    }
    if (query) {
        _toolbarSearchField.stringValue = query;
        [_searchController updateQuery:query];
    }
    if (focus) {
        [_toolbarSearchField focusSelectingAll:YES];
    }
}

- (void)openQueue { [self navigateToRoute:[SPRoute queue] pushHistory:YES]; }
- (void)openSpeakers { [self navigateToRoute:[SPRoute speakers] pushHistory:YES]; }
- (void)openProfile { [self navigateToRoute:[SPRoute profile] pushHistory:YES]; }
- (void)openFavorites { [self navigateToRoute:[SPRoute favorites] pushHistory:YES]; }
- (void)openAlbums { [self navigateToRoute:[SPRoute albums] pushHistory:YES]; }
- (void)openArtists { [self navigateToRoute:[SPRoute artists] pushHistory:YES]; }
- (void)openPlaylists { [self navigateToRoute:[SPRoute playlists] pushHistory:YES]; }
- (void)openAlbumWithID:(NSString *)albumID { [self navigateToRoute:[SPRoute albumWithID:albumID] pushHistory:YES]; }
- (void)openArtistWithID:(NSString *)artistID { [self navigateToRoute:[SPRoute artistWithID:artistID] pushHistory:YES]; }
- (void)openPlaylistWithID:(NSString *)playlistID { [self navigateToRoute:[SPRoute playlistWithID:playlistID] pushHistory:YES]; }

- (void)goBack {
    if (_backStack.count == 0) return;
    SPRoute *prev = _backStack.lastObject;
    [_backStack removeLastObject];
    if (_currentRoute) [_forwardStack addObject:_currentRoute];
    [self navigateToRoute:prev pushHistory:NO];
}

- (void)goForward {
    if (_forwardStack.count == 0) return;
    SPRoute *next = _forwardStack.lastObject;
    [_forwardStack removeLastObject];
    if (_currentRoute) [_backStack addObject:_currentRoute];
    [self navigateToRoute:next pushHistory:NO];
}

- (void)focusSearchFieldSelectingAll:(BOOL)selectAll {
    if (!_window) [self showWindow];
    [_toolbarSearchField focusSelectingAll:selectAll];
}

- (void)setSearchQuery:(NSString *)query {
    if (!_window) [self showWindow];
    _toolbarSearchField.stringValue = query ?: @"";
    [self handleSearchInputChanged:query ?: @""];
}

#pragma mark - Playback & Library Actions

- (void)playTrack:(SPTrack *)track
     inContextURI:(NSString *)contextURI
       trackIndex:(NSInteger)trackIndex
     fallbackURIs:(NSArray<NSString *> *)fallbackURIs {
    if (!track.uri.length) return;
    if (contextURI.length) {
        [_audioEngine playTrackURI:track.uri inContextURI:contextURI trackIndex:trackIndex completion:nil];
    } else if (_songRadioEnabled) {
        [_audioEngine playTrackURIWithRadio:track.uri fallbackURIs:fallbackURIs completion:nil];
    } else {
        [_audioEngine playTrackURIs:@[ track.uri ] completion:nil];
    }
}

- (void)playTrackWithRadio:(SPTrack *)track fallbackURIs:(NSArray<NSString *> *)fallbackURIs {
    if (!track.uri.length) return;
    if (_songRadioEnabled) {
        [_audioEngine playTrackURIWithRadio:track.uri fallbackURIs:fallbackURIs completion:nil];
    } else {
        NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithObject:track.uri];
        if (fallbackURIs.count) [uris addObjectsFromArray:fallbackURIs];
        [_audioEngine playTrackURIs:uris completion:nil];
    }
}

- (void)playContextURI:(NSString *)contextURI {
    if (!contextURI.length) return;
    [_audioEngine playTrackURI:@"" inContextURI:contextURI trackIndex:0 completion:nil];
}

- (void)togglePlayPause { [_audioEngine togglePlayPause]; }
- (void)skipNext { [_audioEngine skipNext]; }
- (void)skipPrevious { [_audioEngine skipPrevious]; }
- (void)seekToMs:(int64_t)positionMs { [_audioEngine seekToMs:positionMs]; }

- (void)toggleShuffle {
    [_audioEngine setShuffle:!_store.playbackState.shuffling];
}

- (void)setShuffleEnabled:(BOOL)enabled {
    [_audioEngine setShuffle:enabled];
}

- (void)cycleRepeatMode {
    [_audioEngine setRepeatMode:SPRepeatModeNext(_store.playbackState.repeatMode)];
}

- (void)previewVolumePercent:(NSInteger)percent {
    NSInteger clamped = MIN(100, MAX(0, percent));
    _volumePercent = clamped;
    _muted = (clamped == 0);
    _playerBar.volumePercent = clamped;
    _playerBar.muted = _muted;
    if ([_currentContentView isKindOfClass:SPSpeakersPageView.class]) {
        ((SPSpeakersPageView *)_currentContentView).volumePercent = clamped;
    }
    if (_audioEngine.kind == SPAudioEngineKindFairPlay) {
        [_audioEngine setVolumePercent:clamped];
        return;
    }
    _pendingVolumePercent = clamped;
    if (!_volumeThrottleTimer) {
        __weak typeof(self) weakSelf = self;
        _volumeThrottleTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            SPShell *s = weakSelf;
            if (!s) return;
            s->_volumeThrottleTimer = nil;
            [s->_audioEngine setVolumePercent:s->_pendingVolumePercent];
        }];
    }
}

- (void)setVolumePercent:(NSInteger)percent {
    [_volumeThrottleTimer invalidate];
    _volumeThrottleTimer = nil;
    NSInteger clamped = MIN(100, MAX(0, percent));
    _volumePercent = clamped;
    _muted = (clamped == 0);
    [_defaults setInteger:clamped forKey:kSPVolumeDefaultsKey];
    [_audioEngine setVolumePercent:clamped];
    _playerBar.volumePercent = clamped;
    _playerBar.muted = _muted;
    if ([_currentContentView isKindOfClass:SPSpeakersPageView.class]) {
        ((SPSpeakersPageView *)_currentContentView).volumePercent = clamped;
    }
}

- (void)adjustVolumeBy:(NSInteger)delta {
    [self setVolumePercent:_volumePercent + delta];
}

- (void)toggleMute {
    _muted = !_muted;
    NSInteger effective = _muted ? 0 : MAX(5, _volumePercent);
    [_audioEngine setVolumePercent:effective];
    _playerBar.muted = _muted;
}

- (void)toggleFavoriteTrackID:(NSString *)trackID {
    if (!trackID.length) return;
    BOOL nowFavorited = [_store toggleFavoriteTrackID:trackID];
    NSString *uri = [NSString stringWithFormat:@"spotify:track:%@", trackID];
    if (_netClient) {
        __weak typeof(self) weakSelf = self;
        void (^onResult)(NSError *) = ^(NSError *err) {
            if (!err || ([err.domain isEqualToString:SPNetErrorDomain] && err.code == SPNetErrorCancelled)) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPShell *s = weakSelf;
                if (s) [s->_store setFavorite:!nowFavorited forTrackID:trackID];
            });
        };
        if (nowFavorited) [_netClient addToLibraryURIs:@[ uri ] completion:onResult];
        else [_netClient removeFromLibraryURIs:@[ uri ] completion:onResult];
    }
}

- (void)addTrackToQueue:(SPTrack *)track {
    if (track.uri.length) [_audioEngine enqueueTrackURI:track.uri];
}

- (void)skipToQueueIndex:(NSInteger)queueIndex {
    [_audioEngine skipToQueueIndex:queueIndex];
}

#pragma mark - Library Save/Follow & Playlist CRUD

- (void)toggleSaveAlbumID:(NSString *)albumID {
    if (!albumID.length) return;
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    BOOL exists = NO;
    for (SPAlbum *a in _store.libraryAlbums) {
        if ([a.albumID isEqualToString:albumID]) { exists = YES; continue; }
        [ids addObject:a.albumID];
    }
    if (!exists) [ids insertObject:albumID atIndex:0];
    [_store setLibraryAlbumIDs:ids addedAtByID:nil];

    NSString *uri = [NSString stringWithFormat:@"spotify:album:%@", albumID];
    if (_netClient) {
        void (^noop)(NSError *) = ^(NSError *e) { (void)e; };
        if (exists) [_netClient removeFromLibraryURIs:@[ uri ] completion:noop];
        else [_netClient addToLibraryURIs:@[ uri ] completion:noop];
    }
}

- (void)toggleFollowArtistID:(NSString *)artistID {
    if (!artistID.length) return;
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    BOOL exists = NO;
    for (SPArtist *a in _store.libraryArtists) {
        if ([a.artistID isEqualToString:artistID]) { exists = YES; continue; }
        [ids addObject:a.artistID];
    }
    if (!exists) [ids insertObject:artistID atIndex:0];
    [_store setLibraryArtistIDs:ids];

    NSString *uri = [NSString stringWithFormat:@"spotify:artist:%@", artistID];
    if (_netClient) {
        void (^noop)(NSError *) = ^(NSError *e) { (void)e; };
        if (exists) [_netClient removeFromLibraryURIs:@[ uri ] completion:noop];
        else [_netClient addToLibraryURIs:@[ uri ] completion:noop];
    }
}

- (void)toggleFollowPlaylistID:(NSString *)playlistID {
    if (!playlistID.length) return;
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    BOOL exists = NO;
    for (SPPlaylist *p in _store.libraryPlaylists) {
        if ([p.playlistID isEqualToString:playlistID]) { exists = YES; continue; }
        [ids addObject:p.playlistID];
    }
    if (!exists) [ids insertObject:playlistID atIndex:0];
    [_store setLibraryPlaylistIDs:ids];

    NSString *uri = [NSString stringWithFormat:@"spotify:playlist:%@", playlistID];
    if (_netClient) {
        void (^noop)(NSError *) = ^(NSError *e) { (void)e; };
        if (exists) [_netClient removeFromLibraryURIs:@[ uri ] completion:noop];
        else [_netClient addToLibraryURIs:@[ uri ] completion:noop];
    }
}

- (void)promptCreatePlaylist {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"New Playlist";
    alert.informativeText = @"Enter a name for the new playlist";
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.placeholderString = @"Playlist name";
    alert.accessoryView = field;
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length) [self createPlaylistWithName:name description:nil];
    }
}

- (void)createPlaylistWithName:(NSString *)name description:(NSString *)description ownerID:(NSString *)ownerID ownerName:(NSString *)ownerName {
    __weak typeof(self) weakSelf = self;
    [_netClient createPlaylistWithName:name description:description completion:^(NSString *playlistID, NSError *err) {
        if (err || !playlistID.length) return;
        [weakSelf.netClient addPlaylistID:playlistID toRootlistForUsername:ownerID completion:^(NSError *addErr) {
            if (addErr) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPShell *s = weakSelf;
                if (!s) return;
                SPPlaylist *pl = [[SPPlaylist alloc] initWithPlaylistID:playlistID
                                                                    uri:[NSString stringWithFormat:@"spotify:playlist:%@", playlistID]
                                                                   name:name
                                                    playlistDescription:description
                                                                ownerID:ownerID
                                                              ownerName:ownerName
                                                             artworkURL:nil
                                                        artworkSmallURL:nil
                                                               isPublic:NO
                                                                  items:@[]
                                                        totalTrackCount:0
                                                          detailsLoaded:YES];
                [s->_store upsertPlaylists:@[ pl ]];
                NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithObject:playlistID];
                for (SPPlaylist *ex in s->_store.libraryPlaylists) {
                    if (![ex.playlistID isEqualToString:playlistID]) [ids addObject:ex.playlistID];
                }
                [s->_store setLibraryPlaylistIDs:ids];
                [s openPlaylistWithID:playlistID];
            });
        }];
    }];
}

- (void)createPlaylistWithName:(NSString *)name description:(NSString *)description {
    if (!name.length) return;
    if (!_netClient) {
        NSString *pid = [NSString stringWithFormat:@"local-%u", arc4random()];
        SPPlaylist *pl = [[SPPlaylist alloc] initWithPlaylistID:pid
                                                            uri:[NSString stringWithFormat:@"spotify:playlist:%@", pid]
                                                           name:name
                                            playlistDescription:description
                                                        ownerID:_store.userProfile.username ?: @"me"
                                                      ownerName:_store.userProfile.displayName ?: @"You"
                                                     artworkURL:nil
                                                artworkSmallURL:nil
                                                       isPublic:NO
                                                          items:@[]
                                                totalTrackCount:0
                                                  detailsLoaded:YES];
        [_store upsertPlaylists:@[ pl ]];
        NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithObject:pid];
        for (SPPlaylist *ex in _store.libraryPlaylists) [ids addObject:ex.playlistID];
        [_store setLibraryPlaylistIDs:ids];
        [self openPlaylistWithID:pid];
        return;
    }

    NSString *username = _store.userProfile.username;
    if (username.length > 0) {
        [self createPlaylistWithName:name description:description ownerID:username ownerName:_store.userProfile.displayName ?: username];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [_netClient fetchProfileWithCompletion:^(SPUserProfile *profile, NSError *err) {
        if (err || !profile.username.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPShell *s = weakSelf;
            if (!s) return;
            [s->_store setUserProfile:profile];
            [s createPlaylistWithName:name description:description ownerID:profile.username ownerName:profile.displayName ?: profile.username];
        });
    }];
}

- (void)renamePlaylistID:(NSString *)playlistID toName:(NSString *)newName {
    if (!playlistID.length || !newName.length) return;
    SPPlaylist *old = [_store playlistWithID:playlistID];
    if (old) {
        SPPlaylist *updated = [[SPPlaylist alloc] initWithPlaylistID:old.playlistID
                                                                 uri:old.uri
                                                                name:newName
                                                 playlistDescription:old.playlistDescription
                                                             ownerID:old.ownerID
                                                           ownerName:old.ownerName
                                                          artworkURL:old.artworkURL
                                                     artworkSmallURL:old.artworkSmallURL
                                                            isPublic:old.isPublic
                                                               items:old.items
                                                     totalTrackCount:old.totalTrackCount
                                                       detailsLoaded:old.detailsLoaded];
        [_store upsertPlaylists:@[ updated ]];
    }
    if (_netClient) {
        __weak typeof(self) weakSelf = self;
        [_netClient updatePlaylistID:playlistID name:newName description:nil completion:^(NSError *err) {
            if (!err || !old) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPShell *s = weakSelf;
                if (s) [s->_store upsertPlaylists:@[ old ]];
            });
        }];
    }
}

- (void)deletePlaylistID:(NSString *)playlistID {
    if (!playlistID.length) return;
    NSMutableArray<NSString *> *previousIDs = [NSMutableArray new];
    NSMutableArray<NSString *> *kept = [NSMutableArray new];
    for (SPPlaylist *pl in _store.libraryPlaylists) {
        [previousIDs addObject:pl.playlistID];
        if (![pl.playlistID isEqualToString:playlistID]) [kept addObject:pl.playlistID];
    }
    [_store setLibraryPlaylistIDs:kept];
    if (_netClient && _store.userProfile.username.length) {
        __weak typeof(self) weakSelf = self;
        [_netClient removePlaylistID:playlistID fromRootlistForUsername:_store.userProfile.username completion:^(NSError *err) {
            if (!err) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPShell *s = weakSelf;
                if (s) [s->_store setLibraryPlaylistIDs:previousIDs];
            });
        }];
    }
    if ([_lastSelectedPlaylistID isEqualToString:playlistID]) _lastSelectedPlaylistID = nil;
    if (_currentRoute.kind == SPRoutePlaylistDetail && [_currentRoute.entityID isEqualToString:playlistID]) {
        [self openPlaylists];
    }
}

- (void)removeTrackID:(NSString *)trackID fromPlaylistID:(NSString *)playlistID {
    [self removeTrackID:trackID uid:nil fromPlaylistID:playlistID];
}

- (void)removeTrackID:(NSString *)trackID uid:(NSString *)uid fromPlaylistID:(NSString *)playlistID {
    SPPlaylist *old = [_store playlistWithID:playlistID];
    if (!old || !trackID.length) return;
    NSInteger removedIndex = -1;
    SPPlaylistItem *removedItem = nil;
    if (uid.length) {
        for (NSUInteger i = 0; i < old.items.count; i++) {
            SPPlaylistItem *it = old.items[i];
            if ([it.uid isEqualToString:uid] && [it.trackID isEqualToString:trackID]) {
                removedIndex = (NSInteger)i;
                removedItem = it;
                break;
            }
        }
    }
    if (!removedItem) {
        for (NSUInteger i = 0; i < old.items.count; i++) {
            SPPlaylistItem *it = old.items[i];
            if ([it.trackID isEqualToString:trackID]) {
                removedIndex = (NSInteger)i;
                removedItem = it;
                break;
            }
        }
    }
    if (!removedItem || removedIndex < 0) return;

    NSMutableArray<SPPlaylistItem *> *kept = [old.items mutableCopy];
    [kept removeObjectAtIndex:(NSUInteger)removedIndex];
    SPPlaylist *updated = [[SPPlaylist alloc] initWithPlaylistID:old.playlistID
                                                             uri:old.uri
                                                            name:old.name
                                             playlistDescription:old.playlistDescription
                                                         ownerID:old.ownerID
                                                       ownerName:old.ownerName
                                                      artworkURL:old.artworkURL
                                                 artworkSmallURL:old.artworkSmallURL
                                                        isPublic:old.isPublic
                                                           items:kept
                                                 totalTrackCount:(NSInteger)kept.count
                                                   detailsLoaded:old.detailsLoaded];
    [_store upsertPlaylists:@[ updated ]];

    if (_netClient) {
        NSString *trackURI = [NSString stringWithFormat:@"spotify:track:%@", removedItem.trackID];
        __weak typeof(self) weakSelf = self;
        [_netClient removeTrackURI:trackURI atIndex:removedIndex uid:removedItem.uid fromPlaylistID:playlistID completion:^(NSError *err) {
            if (!err) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPShell *s = weakSelf;
                if (s) [s->_store upsertPlaylists:@[ old ]];
            });
        }];
    }
}

#pragma mark - Inspector, Connect, Preferences

- (void)toggleInspector {
    _inspectorOpen = !_inspectorOpen;
    if (_window) {
        if (_inspectorOpen && !_inspectorView) {
            _inspectorView = [[SPNowPlayingInspectorView alloc] initWithFrame:NSZeroRect store:_store navigator:self];
            [_detailAreaView addSubview:_inspectorView];
        } else if (!_inspectorOpen && _inspectorView) {
            SPReleaseViewImages(_inspectorView);
            [_inspectorView removeFromSuperview];
            _inspectorView = nil;
        }
        [self syncNavigationButtons];
        [self layoutDetailArea];
    }
}

- (void)toggleQueueDrawer {
    [self toggleInspector];
}

- (void)toggleSpeakersPopoverFromView:(NSView *)anchorView {
    (void)anchorView;
    [self openSpeakers];
}

- (void)transferPlaybackToDeviceID:(NSString *)deviceID {
    if (!deviceID.length) return;
    [_connectClient transferPlaybackToDeviceID:deviceID completion:nil];
}

- (void)reconnectSpotify {
    [_connectClient disconnect];
    [_connectClient connect];
}

- (void)openPreferences {
    if (_onOpenPreferences) _onOpenPreferences();
}

- (void)signOut {
    if (_onSignOut) _onSignOut();
}

- (void)storeChanged:(SPChange *)change {
    if (change.libraryLists && _window) {
        // If we opened a 3-column section while empty and data just arrived, auto-select first item.
        if (_currentRoute.kind == SPRoutePlaylists && _store.libraryPlaylists.count > 0) {
            [self navigateToRoute:[SPRoute playlistWithID:_store.libraryPlaylists.firstObject.playlistID] pushHistory:NO];
        } else if (_currentRoute.kind == SPRouteAlbums && _store.libraryAlbums.count > 0) {
            [self navigateToRoute:[SPRoute albumWithID:_store.libraryAlbums.firstObject.albumID] pushHistory:NO];
        } else if (_currentRoute.kind == SPRouteArtists && _store.libraryArtists.count > 0) {
            [self navigateToRoute:[SPRoute artistWithID:_store.libraryArtists.firstObject.artistID] pushHistory:NO];
        }
    }
}

@end
