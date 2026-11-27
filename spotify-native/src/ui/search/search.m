// Spotifly 1:1 Search view: SearchHome (Recent Searches grouped form) + SearchResults
// (green segmented scope picker All | Songs | Artists | Albums | Playlists + Songs table + horizontal/grid cards).
#import "ui/search/search.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"
#import "ui/kit/grid.h"

typedef NS_ENUM(NSInteger, SPSearchScope) {
    SPSearchScopeAll = 0,
    SPSearchScopeTracks,
    SPSearchScopeArtists,
    SPSearchScopeAlbums,
    SPSearchScopePlaylists,
};

#pragma mark - SPRecentRowView (row inside Recent Searches grouped card)

@interface SPRecentRowView : NSView
@property (nonatomic, copy) NSString *queryText;
@property (nonatomic) BOOL showBottomDivider;
@property (nonatomic, copy, nullable) void (^onSelect)(NSString *q);
@property (nonatomic, copy, nullable) void (^onRemove)(NSString *q);
@end

@implementation SPRecentRowView {
    SPButton *_removeBtn;
    NSTrackingArea *_tracking;
    BOOL _hovered;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _removeBtn = [SPButton iconButton:SPIconClose size:11.0 frame:NSZeroRect];
    _removeBtn.toolTip = @"Remove";
    __weak typeof(self) weakSelf = self;
    _removeBtn.onClick = ^{
        SPRecentRowView *s = weakSelf;
        if (s && s.queryText.length && s.onRemove) s.onRemove(s.queryText);
    };
    [self addSubview:_removeBtn];
    return self;
}

- (BOOL)isFlipped { return YES; }

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
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (_queryText.length && _onSelect) _onSelect(_queryText);
}

- (void)layout {
    [super layout];
    _removeBtn.frame = NSMakeRect(self.bounds.size.width - 32.0, floor((self.bounds.size.height - 22.0) * 0.5), 22.0, 22.0);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    if (_hovered) {
        CGContextSetFillColorWithColor(ctx, SPHoverFillColor().CGColor);
        CGContextFillRect(ctx, self.bounds);
    }

    [_queryText drawInRect:NSMakeRect(14.0, floor((self.bounds.size.height - 17.0) * 0.5), MAX(40.0, self.bounds.size.width - 54.0), 18.0)
            withAttributes:SPSemanticTextAttributes(SPThemeTypography()->body, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];

    if (_showBottomDivider) {
        CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
        CGContextFillRect(ctx, CGRectMake(14.0, self.bounds.size.height - 1.0, MAX(0, self.bounds.size.width - 28.0), 1.0));
    }
}

@end

#pragma mark - SPSearchDocumentView

@interface SPSearchDocumentView : NSView
@property (nonatomic) BOOL showEmptyHome;
@property (nonatomic) BOOL hasRecentSearches;
@property (nonatomic) NSRect recentCardRect;
@property (nonatomic) BOOL showNoResults;
@property (nonatomic, copy, nullable) NSString *queryTitle;
@property (nonatomic) CGFloat songsHeaderY;
@property (nonatomic) BOOL showSongsHeader;
@end

@implementation SPSearchDocumentView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat w = self.bounds.size.width;
    CGFloat padX = SPThemeMetrics()->pageInset;

    if (_showEmptyHome) {
        if (!_hasRecentSearches) {
            CGFloat cy = MAX(100.0, floor(self.bounds.size.height * 0.36));
            SPDrawIconSemantic(SPIconSearch, CGRectMake(floor(w * 0.5) - 22.0, cy - 52.0, 44.0, 44.0),
                               36.0, NSFontWeightRegular, SPSecondaryLabelColor());
            [@"No Recent Searches" drawInRect:NSMakeRect(24.0, cy, w - 48.0, 22.0)
                               withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];
            [@"Search for songs, artists, albums and playlists."
                drawInRect:NSMakeRect(24.0, cy + 26.0, w - 48.0, 20.0)
            withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByWordWrapping, NSTextAlignmentCenter)];
            return;
        }

        // Spotifly SearchHomeView grouped form for Recent Searches
        SPTextStyle secStyle = {12.0, NSFontWeightSemibold, 16.0, 0.0, NO};
        [@"Recent Searches" drawInRect:NSMakeRect(_recentCardRect.origin.x + 12.0, _recentCardRect.origin.y - 22.0, 200.0, 16.0)
                        withAttributes:SPSemanticTextAttributes(secStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];

        CGPathRef p = CGPathCreateWithRoundedRect(_recentCardRect, 10.0, 10.0, NULL);
        CGContextSetFillColorWithColor(ctx, SPCardSurfaceColor().CGColor);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGContextSetStrokeColorWithColor(ctx, SPSeparatorColor().CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextAddPath(ctx, p);
        CGContextStrokePath(ctx);
        CGPathRelease(p);

        [@"Kept on this Mac only." drawInRect:NSMakeRect(_recentCardRect.origin.x + 12.0, NSMaxY(_recentCardRect) + 10.0, 240.0, 16.0)
                               withAttributes:SPSemanticTextAttributes(typo->caption, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
        return;
    }

    if (_showNoResults) {
        CGFloat cy = MAX(140.0, floor(self.bounds.size.height * 0.36));
        SPDrawIconSemantic(SPIconSearch, CGRectMake(floor(w * 0.5) - 22.0, cy - 52.0, 44.0, 44.0),
                           36.0, NSFontWeightRegular, SPSecondaryLabelColor());
        NSString *msg = [NSString stringWithFormat:@"No Results for “%@”", _queryTitle ?: @""];
        [msg drawInRect:NSMakeRect(24.0, cy, w - 48.0, 24.0)
         withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];
        [@"Check the spelling or try another term."
            drawInRect:NSMakeRect(24.0, cy + 28.0, w - 48.0, 20.0)
        withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByWordWrapping, NSTextAlignmentCenter)];
        return;
    }

    if (_showSongsHeader) {
        [@"Songs" drawInRect:NSMakeRect(padX, _songsHeaderY, 200.0, 24.0)
              withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    }
}

@end

#pragma mark - SPSearchView

@implementation SPSearchView {
    SPStore *_store;
    NSScrollView *_scroll;
    SPSearchDocumentView *_doc;
    SPSegmentedControl *_scopeControl;
    SPSearchScope _scope;
    SPTrackListView *_songsList;
    SPCardShelfView *_artistsShelf;
    SPCardShelfView *_albumsShelf;
    SPCardShelfView *_playlistsShelf;
    SPCardGridView *_scopedGrid;
    NSMutableArray<SPRecentRowView *> *_recentRows;
    SPButton *_clearRecentBtn;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _scope = SPSearchScopeAll;
    _recentRows = [NSMutableArray new];

    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = NO;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;

    _doc = [[SPSearchDocumentView alloc] initWithFrame:self.bounds];
    _scroll.documentView = _doc;
    [self addSubview:_scroll];

    __weak typeof(self) weakSelf = self;

    _scopeControl = [SPSegmentedControl segmentedControlWithLabels:@[ @"All", @"Songs", @"Artists", @"Albums", @"Playlists" ]];
    _scopeControl.selectedSegment = 0;
    _scopeControl.onSelectSegment = ^(NSInteger seg) {
        SPSearchView *s = weakSelf;
        if (!s) return;
        s->_scope = (SPSearchScope)seg;
        [s rebuildUI];
    };
    [_doc addSubview:_scopeControl];

    _clearRecentBtn = [SPButton pillButtonWithTitle:@"Clear History" style:SPButtonStyleSecondary frame:NSZeroRect];
    _clearRecentBtn.onClick = ^{
        SPSearchView *s = weakSelf;
        if (!s) return;
        [s->_store clearRecentSearches];
        [s rebuildUI];
    };
    [_doc addSubview:_clearRecentBtn];

    _songsList = [[SPTrackListView alloc] initWithFrame:NSZeroRect store:store navigator:navigator];
    _songsList.showArtwork = YES;
    _songsList.showAlbumColumn = NO;
    _songsList.playWithSongRadio = YES;
    _songsList.scrollingEnabled = NO;
    _songsList.bottomInset = 4.0;
    [_doc addSubview:_songsList];

    _artistsShelf = [[SPCardShelfView alloc] initWithFrame:NSZeroRect];
    _artistsShelf.sectionTitle = @"Artists";
    _artistsShelf.cardArtSize = 120.0;
    _artistsShelf.onSelectItem = ^(SPCardItem *item) {
        SPArtist *ar = (SPArtist *)item.representedObject;
        if (ar.artistID.length) [weakSelf.navigator openArtistWithID:ar.artistID];
    };
    _artistsShelf.onPlayItem = ^(SPCardItem *item) {
        if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI];
    };
    [_doc addSubview:_artistsShelf];

    _albumsShelf = [[SPCardShelfView alloc] initWithFrame:NSZeroRect];
    _albumsShelf.sectionTitle = @"Albums";
    _albumsShelf.cardArtSize = 140.0;
    _albumsShelf.onSelectItem = ^(SPCardItem *item) {
        SPAlbum *al = (SPAlbum *)item.representedObject;
        if (al.albumID.length) [weakSelf.navigator openAlbumWithID:al.albumID];
    };
    _albumsShelf.onPlayItem = ^(SPCardItem *item) {
        if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI];
    };
    [_doc addSubview:_albumsShelf];

    _playlistsShelf = [[SPCardShelfView alloc] initWithFrame:NSZeroRect];
    _playlistsShelf.sectionTitle = @"Playlists";
    _playlistsShelf.cardArtSize = 140.0;
    _playlistsShelf.onSelectItem = ^(SPCardItem *item) {
        SPPlaylist *pl = (SPPlaylist *)item.representedObject;
        if (pl.playlistID.length) [weakSelf.navigator openPlaylistWithID:pl.playlistID];
    };
    _playlistsShelf.onPlayItem = ^(SPCardItem *item) {
        if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI];
    };
    [_doc addSubview:_playlistsShelf];

    _scopedGrid = [[SPCardGridView alloc] initWithFrame:NSZeroRect];
    _scopedGrid.scrollingEnabled = NO;
    _scopedGrid.topPadding = 12.0;
    _scopedGrid.bottomPadding = 24.0;
    _scopedGrid.onSelectItem = ^(SPCardItem *item) {
        id obj = item.representedObject;
        if ([obj isKindOfClass:SPArtist.class]) [weakSelf.navigator openArtistWithID:((SPArtist *)obj).artistID];
        else if ([obj isKindOfClass:SPAlbum.class]) [weakSelf.navigator openAlbumWithID:((SPAlbum *)obj).albumID];
        else if ([obj isKindOfClass:SPPlaylist.class]) [weakSelf.navigator openPlaylistWithID:((SPPlaylist *)obj).playlistID];
    };
    _scopedGrid.onPlayItem = ^(SPCardItem *item) {
        if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI];
    };
    [_doc addSubview:_scopedGrid];

    [_store addObserver:self];
    [self rebuildUI];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (SPTrackListView *)songsList { return _songsList; }

- (void)applyResults:(SPSearchResults *)results {
    BOOL newQuery = ![_results.query isEqualToString:results.query ?: @""];
    _results = results;
    if (newQuery) {
        _scope = SPSearchScopeAll;
        _scopeControl.selectedSegment = 0;
    }
    [self rebuildUI];
}

- (NSArray<SPCardItem *> *)artistCardsWithLimit:(NSUInteger)limit {
    NSUInteger n = MIN(limit, _results.artists.count);
    NSMutableArray<SPCardItem *> *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        SPArtist *ar = _results.artists[i];
        SPCardItem *c = [[SPCardItem alloc] initWithKey:ar.artistID title:ar.name subtitle:nil
                                             artworkURL:ar.artworkSmallURL ?: ar.artworkURL circular:YES
                                             contextURI:ar.uri representedObject:ar];
        c.placeholderSymbol = @"person.circle.fill";
        [out addObject:c];
    }
    return out;
}

- (NSArray<SPCardItem *> *)albumCardsWithLimit:(NSUInteger)limit {
    NSUInteger n = MIN(limit, _results.albums.count);
    NSMutableArray<SPCardItem *> *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        SPAlbum *al = _results.albums[i];
        SPCardItem *c = [[SPCardItem alloc] initWithKey:al.albumID title:al.name subtitle:al.artistName
                                             artworkURL:al.artworkSmallURL ?: al.artworkURL circular:NO
                                             contextURI:al.uri representedObject:al];
        c.placeholderSymbol = @"opticaldisc";
        [out addObject:c];
    }
    return out;
}

- (NSArray<SPCardItem *> *)playlistCardsWithLimit:(NSUInteger)limit {
    NSUInteger n = MIN(limit, _results.playlists.count);
    NSMutableArray<SPCardItem *> *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        SPPlaylist *pl = _results.playlists[i];
        NSString *sub = pl.ownerName.length ? [NSString stringWithFormat:@"By %@", pl.ownerName] : @"Playlist";
        SPCardItem *c = [[SPCardItem alloc] initWithKey:pl.playlistID title:pl.name subtitle:sub
                                             artworkURL:pl.artworkSmallURL ?: pl.artworkURL circular:NO
                                             contextURI:pl.uri representedObject:pl];
        c.placeholderSymbol = @"music.note.list";
        [out addObject:c];
    }
    return out;
}

- (void)rebuildUI {
    for (SPRecentRowView *r in _recentRows) [r removeFromSuperview];
    [_recentRows removeAllObjects];

    NSString *q = [_results.query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL emptyHome = (!_results || q.length == 0);
    _doc.showEmptyHome = emptyHome;
    _doc.queryTitle = q;
    _doc.showNoResults = NO;
    _doc.showSongsHeader = NO;

    if (emptyHome) {
        _scopeControl.hidden = YES;
        _songsList.hidden = YES;
        _artistsShelf.hidden = YES;
        _albumsShelf.hidden = YES;
        _playlistsShelf.hidden = YES;
        _scopedGrid.hidden = YES;

        NSArray<NSString *> *recents = _store.recentSearches;
        _doc.hasRecentSearches = (recents.count > 0);
        _clearRecentBtn.hidden = (recents.count == 0);

        __weak typeof(self) weakSelf = self;
        for (NSUInteger i = 0; i < recents.count; i++) {
            SPRecentRowView *row = [[SPRecentRowView alloc] initWithFrame:NSZeroRect];
            row.queryText = recents[i];
            row.showBottomDivider = (i + 1 < recents.count);
            row.onSelect = ^(NSString *rq) {
                [weakSelf.navigator setSearchQuery:rq];
            };
            row.onRemove = ^(NSString *rq) {
                SPSearchView *s = weakSelf;
                if (!s) return;
                [s->_store removeRecentSearch:rq];
                [s rebuildUI];
            };
            [_doc addSubview:row];
            [_recentRows addObject:row];
        }
        [self layoutDocument];
        _doc.needsDisplay = YES;
        return;
    }

    _clearRecentBtn.hidden = YES;
    _scopeControl.hidden = NO;

    BOOL showAll = (_scope == SPSearchScopeAll);
    NSUInteger overviewLimit = 5;

    if (showAll) {
        _scopedGrid.hidden = YES;
        NSArray<SPTrack *> *tracks = _results.tracks.count > overviewLimit
            ? [_results.tracks subarrayWithRange:NSMakeRange(0, overviewLimit)]
            : (_results.tracks ?: @[]);
        _songsList.tracks = tracks;
        _songsList.hidden = (tracks.count == 0);

        NSArray<SPCardItem *> *artCards = [self artistCardsWithLimit:overviewLimit];
        _artistsShelf.items = artCards;
        _artistsShelf.hidden = (artCards.count == 0);

        NSArray<SPCardItem *> *albCards = [self albumCardsWithLimit:overviewLimit];
        _albumsShelf.items = albCards;
        _albumsShelf.hidden = (albCards.count == 0);

        NSArray<SPCardItem *> *plCards = [self playlistCardsWithLimit:overviewLimit];
        _playlistsShelf.items = plCards;
        _playlistsShelf.hidden = (plCards.count == 0);

        _doc.showNoResults = (tracks.count == 0 && artCards.count == 0 && albCards.count == 0 && plCards.count == 0);
    } else if (_scope == SPSearchScopeTracks) {
        _artistsShelf.hidden = YES;
        _albumsShelf.hidden = YES;
        _playlistsShelf.hidden = YES;
        _scopedGrid.hidden = YES;
        _songsList.tracks = _results.tracks ?: @[];
        _songsList.hidden = (_songsList.tracks.count == 0);
        _doc.showNoResults = (_songsList.tracks.count == 0);
    } else {
        _songsList.hidden = YES;
        _artistsShelf.hidden = YES;
        _albumsShelf.hidden = YES;
        _playlistsShelf.hidden = YES;
        NSArray<SPCardItem *> *items = @[];
        if (_scope == SPSearchScopeArtists) {
            _scopedGrid.cardWidth = 130.0;
            items = [self artistCardsWithLimit:NSUIntegerMax];
        } else if (_scope == SPSearchScopeAlbums) {
            _scopedGrid.cardWidth = 150.0;
            items = [self albumCardsWithLimit:NSUIntegerMax];
        } else {
            _scopedGrid.cardWidth = 150.0;
            items = [self playlistCardsWithLimit:NSUIntegerMax];
        }
        _scopedGrid.items = items;
        _scopedGrid.hidden = (items.count == 0);
        _doc.showNoResults = (items.count == 0);
    }

    [self layoutDocument];
    _doc.needsDisplay = YES;
}

- (void)layoutDocument {
    CGFloat w = MAX(320.0, self.bounds.size.width);
    CGFloat padX = SPThemeMetrics()->pageInset;
    CGFloat clearance = SPThemeMetrics()->nowPlayingContentClearance;

    if (_doc.showEmptyHome) {
        if (_recentRows.count > 0) {
            CGFloat cw = MIN(560.0, MAX(260.0, w - padX * 2.0));
            CGFloat cx = floor((w - cw) * 0.5);
            CGFloat cardY = 44.0;
            CGFloat rowH = 38.0;
            CGFloat cardH = (CGFloat)_recentRows.count * rowH;
            _doc.recentCardRect = NSMakeRect(cx, cardY, cw, cardH);
            for (NSUInteger i = 0; i < _recentRows.count; i++) {
                _recentRows[i].frame = NSMakeRect(cx, cardY + (CGFloat)i * rowH, cw, rowH);
            }
            _clearRecentBtn.frame = NSMakeRect(cx + cw - 104.0, cardY + cardH + 6.0, 104.0, 26.0);
            _doc.frame = NSMakeRect(0.0, 0.0, w, MAX(self.bounds.size.height, cardY + cardH + 56.0 + clearance));
        } else {
            _doc.frame = NSMakeRect(0.0, 0.0, w, self.bounds.size.height);
        }
        return;
    }

    CGFloat y = 10.0;
    [_scopeControl sizeToFit];
    _scopeControl.frame = NSMakeRect(padX, y, _scopeControl.frame.size.width, _scopeControl.frame.size.height);
    y += _scopeControl.frame.size.height + 8.0;

    if (_doc.showNoResults) {
        _doc.frame = NSMakeRect(0.0, 0.0, w, self.bounds.size.height);
        return;
    }

    if (!_songsList.hidden) {
        _doc.showSongsHeader = YES;
        _doc.songsHeaderY = y + 14.0;
        y += 44.0;
        CGFloat songsH = (CGFloat)_songsList.tracks.count * SPThemeMetrics()->trackRowHeight + 6.0;
        _songsList.frame = NSMakeRect(0.0, y, w, songsH);
        y += songsH + 8.0;
    }

    if (!_artistsShelf.hidden) {
        CGFloat sh = [SPCardShelfView preferredHeightForArtSize:120.0 circular:YES];
        _artistsShelf.frame = NSMakeRect(0.0, y, w, sh);
        y += sh;
    }
    if (!_albumsShelf.hidden) {
        CGFloat sh = [SPCardShelfView preferredHeightForArtSize:140.0 circular:NO];
        _albumsShelf.frame = NSMakeRect(0.0, y, w, sh);
        y += sh;
    }
    if (!_playlistsShelf.hidden) {
        CGFloat sh = [SPCardShelfView preferredHeightForArtSize:140.0 circular:NO];
        _playlistsShelf.frame = NSMakeRect(0.0, y, w, sh);
        y += sh;
    }
    if (!_scopedGrid.hidden) {
        CGFloat gh = MAX(220.0, [_scopedGrid contentHeightForWidth:w]);
        _scopedGrid.frame = NSMakeRect(0.0, y, w, gh);
        y += gh;
    }

    _doc.frame = NSMakeRect(0.0, 0.0, w, MAX(self.bounds.size.height, y + clearance));
}

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    [self layoutDocument];
}

- (void)storeChanged:(SPChange *)change {
    if (change.recentSearches && _doc.showEmptyHome) {
        [self rebuildUI];
        return;
    }
    [_songsList applyStoreChange:change];
}

@end
