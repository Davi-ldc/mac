// Library views: Spotifly 1:1 FavoritesView (DetailHeader + sortable TrackTable with single-row heart redraws)
// and 3-column SPLibraryListView (filterable Playlists, Albums, Artists column).
#import "ui/library/library.h"
#import "model/playlist.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"
#import "ui/kit/list.h"

#pragma mark - SPFavoritesView

@implementation SPFavoritesView {
    SPStore *_store;
    SPDetailHeaderView *_headerView;
    SPTrackListView *_trackList;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _filterText = @"";

    _headerView = [[SPDetailHeaderView alloc] initWithFrame:NSZeroRect];
    _headerView.isFavoritesHeader = YES;
    _headerView.kindText = @"Playlist";
    _headerView.titleText = @"Favorites";
    _headerView.showPlayButton = YES;
    _headerView.showShuffleButton = YES;
    __weak typeof(self) weakSelf = self;
    _headerView.onPlay = ^{
        SPFavoritesView *s = weakSelf;
        if (!s || s->_trackList.tracks.count == 0) return;
        [s.navigator playContextURI:SPLikedSongsPlaylistURI];
    };
    _headerView.onShuffle = ^{
        SPFavoritesView *s = weakSelf;
        if (!s || s->_trackList.tracks.count == 0) return;
        [s.navigator setShuffleEnabled:YES];
        [s.navigator playContextURI:SPLikedSongsPlaylistURI];
    };
    [self addSubview:_headerView];

    _trackList = [[SPTrackListView alloc] initWithFrame:NSZeroRect store:store navigator:navigator];
    _trackList.contextURI = SPLikedSongsPlaylistURI;
    _trackList.showArtwork = YES;
    _trackList.showAlbumColumn = YES;
    _trackList.showColumnHeader = YES;
    _trackList.sortable = YES;
    _trackList.playWithSongRadio = NO;
    _trackList.topInset = 2.0;
    _trackList.bottomInset = SPThemeMetrics()->nowPlayingContentClearance;
    [self addSubview:_trackList];

    [_store addObserver:self];
    [self reloadTracks];
    return self;
}

- (void)dealloc {
    [_store removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (SPTrackListView *)trackList { return _trackList; }

- (void)setFilterText:(NSString *)filterText {
    NSString *next = filterText ?: @"";
    if ([_filterText isEqualToString:next]) return;
    _filterText = [next copy];
    [self reloadTracks];
}

- (void)updateHeaderMetadata:(NSArray<SPTrack *> *)allTracks {
    int64_t totalMs = 0;
    for (SPTrack *t in allTracks) totalMs += MAX(0, t.durationMs);
    NSString *countStr = (allTracks.count == 1)
        ? @"1 song"
        : [NSString stringWithFormat:@"%lu songs", (unsigned long)allTracks.count];
    NSString *durStr = SPFormatTotalDurationMs(totalMs);
    _headerView.metadataText = durStr.length ? [NSString stringWithFormat:@"%@ · %@", countStr, durStr] : countStr;
    _headerView.playEnabled = (allTracks.count > 0);
}

- (void)reloadTracks {
    NSArray<SPTrack *> *all = _store.libraryTracks;
    [self updateHeaderMetadata:all];

    NSString *q = [_filterText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) {
        _trackList.tracks = all;
    } else {
        NSMutableArray<SPTrack *> *filtered = [NSMutableArray new];
        for (SPTrack *t in all) {
            if ([t.name localizedStandardContainsString:q] ||
                [t.artistName localizedStandardContainsString:q] ||
                (t.albumName.length && [t.albumName localizedStandardContainsString:q])) {
                [filtered addObject:t];
            }
        }
        _trackList.tracks = filtered;
    }
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat headerH = [SPDetailHeaderView preferredHeightForWidth:w hasDescription:NO];
    _headerView.frame = NSMakeRect(0.0, 0.0, w, headerH);
    _trackList.frame = NSMakeRect(0.0, headerH, w, MAX(0.0, h - headerH));
}

- (void)storeChanged:(SPChange *)change {
    if (change.libraryLists) {
        [self reloadTracks];
        return;
    }
    if (change.favorites.count > 0) {
        BOOL needsInsert = NO;
        for (NSString *tid in change.favorites) {
            if ([_store isFavoriteTrackID:tid] && [_trackList indexOfKey:tid] == NSNotFound) {
                needsInsert = YES;
                break;
            }
        }
        if (needsInsert) {
            [self reloadTracks];
            return;
        }
        // Single-row heart redraw in place without rebuilding the table.
        [_trackList applyStoreChange:change];
        [self updateHeaderMetadata:_store.libraryTracks];
        return;
    }
    [_trackList applyStoreChange:change];
}

@end

#pragma mark - SPLibraryListView (3-column master list matching Spotifly LibraryListView.swift)

@interface SPLibraryRowEntry : NSObject
@property (nonatomic, copy) NSString *entityID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *artworkURL;
@property (nonatomic, copy) NSString *uri;
@property (nonatomic) BOOL circular;
@property (nonatomic, copy) NSString *placeholderSymbol;
@end

@implementation SPLibraryRowEntry
@end

@interface SPLibraryItemRowView : SPListRowView
@property (nonatomic, strong, nullable) SPLibraryRowEntry *entry;
@property (nonatomic) BOOL isActiveEntity;
@property (nonatomic, copy, nullable) void (^onPlay)(SPLibraryRowEntry *entry);
@end

@implementation SPLibraryItemRowView {
    SPButton *_playBtn;
    NSString *_lastArtURL;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _playBtn = [SPButton iconButton:SPIconPlay size:11.5 frame:NSZeroRect];
    _playBtn.active = YES; // #1DB954 green tint matching Spotifly LibraryRow hover play
    _playBtn.hidden = YES;
    __weak typeof(self) weakSelf = self;
    _playBtn.onClick = ^{
        SPLibraryItemRowView *s = weakSelf;
        if (s && s.entry && s.onPlay) s.onPlay(s.entry);
    };
    [self addSubview:_playBtn];
    return self;
}

- (void)setEntry:(SPLibraryRowEntry *)entry {
    if (![_lastArtURL isEqualToString:entry.artworkURL ?: @""]) {
        [self.imageHolder removeAllImages];
        _lastArtURL = [entry.artworkURL copy];
    }
    _entry = entry;
    self.needsDisplay = YES;
}

- (void)setIsActiveEntity:(BOOL)isActiveEntity {
    if (_isActiveEntity == isActiveEntity) return;
    _isActiveEntity = isActiveEntity;
    self.needsDisplay = YES;
}

- (void)setHovered:(BOOL)hovered {
    [super setHovered:hovered];
    _playBtn.hidden = !hovered;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _entry = nil;
    _isActiveEntity = NO;
    _playBtn.hidden = YES;
}

- (void)layout {
    [super layout];
    _playBtn.frame = NSMakeRect(self.bounds.size.width - 32.0, floor((self.bounds.size.height - 22.0) * 0.5), 22.0, 22.0);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!_entry) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    NSRect b = self.bounds;

    if (_isActiveEntity || self.isHovered) {
        NSColor *bg = _isActiveEntity ? SPSelectedRowFillColor() : SPHoverFillColor();
        CGContextSetFillColorWithColor(ctx, bg.CGColor);
        CGPathRef p = CGPathCreateWithRoundedRect(NSInsetRect(b, 8.0, 1.0), 7.0, 7.0, NULL);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
    }

    // 36x36pt artwork matching Spotifly LibraryRow
    CGRect artRect = CGRectMake(16.0, floor((b.size.height - 36.0) * 0.5), 36.0, 36.0);
    CGImageRef img = NULL;
    if (_lastArtURL.length) {
        NSURL *u = [NSURL URLWithString:_lastArtURL];
        if (u) {
            CGFloat scale = self.window.backingScaleFactor ?: 2.0;
            img = [self.imageHolder imageWithURL:u pixels:ceil(36.0 * scale)];
        }
    }
    SPDrawArtworkSemantic(ctx, img, artRect, 4.0, _entry.circular, _entry.placeholderSymbol, 15.0, 0.0);

    CGFloat tx = 62.0;
    CGFloat rightPad = self.isHovered ? 38.0 : 14.0;
    CGFloat tw = MAX(20.0, b.size.width - tx - rightPad);

    if (_entry.subtitle.length) {
        CGFloat ty = floor((b.size.height - 34.0) * 0.5);
        [_entry.name drawInRect:NSMakeRect(tx, ty, tw, 17.0)
                 withAttributes:SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
        [_entry.subtitle drawInRect:NSMakeRect(tx, ty + 18.0, tw, 15.0)
                     withAttributes:SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    } else {
        [_entry.name drawInRect:NSMakeRect(tx, floor((b.size.height - 17.0) * 0.5), tw, 18.0)
                 withAttributes:SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }
}

@end

@interface SPLibraryInnerListView : SPListView
@property (nonatomic, copy) NSArray<SPLibraryRowEntry *> *entries;
@property (nonatomic, copy, nullable) NSString *selectedEntityID;
@property (nonatomic, copy, nullable) void (^onSelectEntry)(SPLibraryRowEntry *entry);
@property (nonatomic, copy, nullable) void (^onPlayEntry)(SPLibraryRowEntry *entry);
@end

@implementation SPLibraryInnerListView

- (void)setEntries:(NSArray<SPLibraryRowEntry *> *)entries {
    _entries = [entries copy] ?: @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:_entries.count];
    for (SPLibraryRowEntry *e in _entries) [keys addObject:e.entityID];
    [self showKeys:keys];
}

- (SPListRowView *)makeRow {
    SPLibraryItemRowView *row = [[SPLibraryItemRowView alloc] initWithFrame:NSZeroRect];
    __weak typeof(self) weakSelf = self;
    row.onPlay = ^(SPLibraryRowEntry *entry) {
        if (weakSelf.onPlayEntry) weakSelf.onPlayEntry(entry);
    };
    return row;
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width {
    (void)index;
    (void)width;
    return 46.0;
}

- (void)showIndex:(NSUInteger)index inRow:(SPLibraryItemRowView *)row {
    if (index >= _entries.count) return;
    SPLibraryRowEntry *e = _entries[index];
    row.entry = e;
    row.isActiveEntity = (_selectedEntityID.length > 0 && [_selectedEntityID isEqualToString:e.entityID]);
}

- (void)didSelectIndex:(NSUInteger)index {
    if (index >= _entries.count) return;
    if (_onSelectEntry) _onSelectEntry(_entries[index]);
}

- (void)didActivateIndex:(NSUInteger)index {
    if (index >= _entries.count) return;
    if (_onPlayEntry) _onPlayEntry(_entries[index]);
}

@end

@interface SPColumnFilterField : NSView <NSTextFieldDelegate>
@property (nonatomic, copy) NSString *placeholderString;
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, copy, nullable) void (^onChange)(NSString *text);
@end

@implementation SPColumnFilterField {
    NSTextField *_field;
    SPButton *_clearBtn;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _field.bordered = NO;
    _field.bezeled = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = SPNSFont(SPThemeTypography()->callout);
    _field.textColor = SPLabelColor();
    _field.usesSingleLineMode = YES;
    _field.cell.scrollable = YES;
    _field.cell.wraps = NO;
    _field.delegate = self;
    [self addSubview:_field];

    _clearBtn = [SPButton iconButton:SPIconClose size:10.0 frame:NSZeroRect];
    _clearBtn.hidden = YES;
    __weak typeof(self) weakSelf = self;
    _clearBtn.onClick = ^{
        SPColumnFilterField *s = weakSelf;
        if (!s) return;
        s->_field.stringValue = @"";
        s->_clearBtn.hidden = YES;
        if (s.onChange) s.onChange(@"");
        s.needsLayout = YES;
    };
    [self addSubview:_clearBtn];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setPlaceholderString:(NSString *)placeholderString {
    _placeholderString = [placeholderString copy] ?: @"";
    NSDictionary *attrs = SPSemanticTextAttributes(SPThemeTypography()->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
    _field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:_placeholderString attributes:attrs];
}

- (NSString *)stringValue { return _field.stringValue ?: @""; }
- (void)setStringValue:(NSString *)stringValue {
    _field.stringValue = stringValue ?: @"";
    _clearBtn.hidden = (_field.stringValue.length == 0);
    self.needsLayout = YES;
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [self.window makeFirstResponder:_field];
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat rightPad = _clearBtn.hidden ? 8.0 : 24.0;
    _field.frame = NSMakeRect(24.0, floor((h - 16.0) * 0.5), MAX(20.0, w - 24.0 - rightPad), 16.0);
    _clearBtn.frame = NSMakeRect(w - 22.0, floor((h - 18.0) * 0.5), 18.0, 18.0);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    CGPathRef p = CGPathCreateWithRoundedRect(NSInsetRect(self.bounds, 0.5, 0.5), 6.0, 6.0, NULL);
    CGContextSetFillColorWithColor(ctx, SPQuaternaryFillColor().CGColor);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGContextSetStrokeColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextAddPath(ctx, p);
    CGContextStrokePath(ctx);
    CGPathRelease(p);

    SPDrawIconSemantic(SPIconSearch, CGRectMake(6.0, floor((self.bounds.size.height - 12.0) * 0.5), 12.0, 12.0),
                       11.0, NSFontWeightRegular, SPSecondaryLabelColor());
}

- (void)controlTextDidChange:(NSNotification *)obj {
    (void)obj;
    NSString *val = _field.stringValue ?: @"";
    _clearBtn.hidden = (val.length == 0);
    self.needsLayout = YES;
    if (_onChange) _onChange(val);
}

@end

@implementation SPLibraryListView {
    SPStore *_store;
    SPColumnFilterField *_filterField;
    SPLibraryInnerListView *_list;
    NSString *_filterQuery;
}

- (instancetype)initWithFrame:(NSRect)frame kind:(SPLibraryListKind)kind store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _kind = kind;
    _store = store;
    _navigator = navigator;
    _filterQuery = @"";

    _filterField = [[SPColumnFilterField alloc] initWithFrame:NSZeroRect];
    if (kind == SPLibraryListPlaylists) _filterField.placeholderString = @"Filter Playlists";
    else if (kind == SPLibraryListAlbums) _filterField.placeholderString = @"Filter Albums";
    else _filterField.placeholderString = @"Filter Artists";

    __weak typeof(self) weakSelf = self;
    _filterField.onChange = ^(NSString *text) {
        SPLibraryListView *s = weakSelf;
        if (!s) return;
        s->_filterQuery = [text copy] ?: @"";
        [s reloadItems];
    };
    [self addSubview:_filterField];

    _list = [[SPLibraryInnerListView alloc] initWithFrame:NSZeroRect];
    _list.topInset = 2.0;
    _list.bottomInset = SPThemeMetrics()->nowPlayingContentClearance;
    _list.onSelectEntry = ^(SPLibraryRowEntry *entry) {
        SPLibraryListView *s = weakSelf;
        if (!s || !entry.entityID.length) return;
        if (s->_kind == SPLibraryListPlaylists) [s.navigator openPlaylistWithID:entry.entityID];
        else if (s->_kind == SPLibraryListAlbums) [s.navigator openAlbumWithID:entry.entityID];
        else [s.navigator openArtistWithID:entry.entityID];
    };
    _list.onPlayEntry = ^(SPLibraryRowEntry *entry) {
        if (entry.uri.length) [weakSelf.navigator playContextURI:entry.uri];
    };
    [self addSubview:_list];

    [_store addObserver:self];
    [self reloadItems];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }

- (void)setSelectedEntityID:(NSString *)selectedEntityID {
    if ([_selectedEntityID isEqualToString:selectedEntityID ?: @""]) return;
    NSString *old = _selectedEntityID;
    _selectedEntityID = [selectedEntityID copy];
    _list.selectedEntityID = _selectedEntityID;
    NSMutableSet<NSString *> *dirty = [NSMutableSet new];
    if (old.length) [dirty addObject:old];
    if (_selectedEntityID.length) [dirty addObject:_selectedEntityID];
    if (dirty.count) [_list refreshKeys:dirty];
    // If selected entity is ephemeral (not yet in library list), reload so it appears at top.
    if (_selectedEntityID.length && [_list indexOfKey:_selectedEntityID] == NSNotFound) {
        [self reloadItems];
    }
}

- (void)setAlbumSortOrder:(SPAlbumSortOrder)albumSortOrder {
    if (_albumSortOrder == albumSortOrder) return;
    _albumSortOrder = albumSortOrder;
    if (_kind == SPLibraryListAlbums) [self reloadItems];
}

- (NSString *)firstEntityID {
    return _list.entries.firstObject.entityID;
}

- (void)reloadItems {
    NSString *q = [_filterQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<SPLibraryRowEntry *> *rows = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];

    if (_kind == SPLibraryListPlaylists) {
        if (_selectedEntityID.length) {
            SPPlaylist *sel = [_store playlistWithID:_selectedEntityID];
            BOOL inLib = NO;
            for (SPPlaylist *p in _store.libraryPlaylists) { if ([p.playlistID isEqualToString:_selectedEntityID]) { inLib = YES; break; } }
            if (sel && !inLib && q.length == 0) {
                SPLibraryRowEntry *e = [SPLibraryRowEntry new];
                e.entityID = sel.playlistID;
                e.name = sel.name;
                e.subtitle = sel.ownerName.length ? [NSString stringWithFormat:@"By %@", sel.ownerName] : @"Playlist";
                e.artworkURL = sel.artworkSmallURL ?: sel.artworkURL;
                e.uri = sel.uri;
                e.placeholderSymbol = @"music.note.list";
                [rows addObject:e];
                [seen addObject:sel.playlistID];
            }
        }
        for (SPPlaylist *pl in _store.libraryPlaylists) {
            if ([seen containsObject:pl.playlistID]) continue;
            NSString *sub = pl.ownerName.length ? [NSString stringWithFormat:@"By %@", pl.ownerName] : @"Playlist";
            if (q.length && ![pl.name localizedStandardContainsString:q] && ![sub localizedStandardContainsString:q]) continue;
            SPLibraryRowEntry *e = [SPLibraryRowEntry new];
            e.entityID = pl.playlistID;
            e.name = pl.name;
            e.subtitle = sub;
            e.artworkURL = pl.artworkSmallURL ?: pl.artworkURL;
            e.uri = pl.uri;
            e.placeholderSymbol = @"music.note.list";
            [rows addObject:e];
        }
    } else if (_kind == SPLibraryListAlbums) {
        NSArray<SPAlbum *> *albums = _store.libraryAlbums;
        if (_albumSortOrder == SPAlbumSortTitle) {
            albums = [albums sortedArrayUsingComparator:^NSComparisonResult(SPAlbum *a, SPAlbum *b) {
                return [a.name localizedCaseInsensitiveCompare:b.name];
            }];
        } else if (_albumSortOrder == SPAlbumSortArtist) {
            albums = [albums sortedArrayUsingComparator:^NSComparisonResult(SPAlbum *a, SPAlbum *b) {
                NSComparisonResult r = [a.artistName localizedCaseInsensitiveCompare:b.artistName];
                return r != NSOrderedSame ? r : [a.name localizedCaseInsensitiveCompare:b.name];
            }];
        }
        if (_selectedEntityID.length) {
            SPAlbum *sel = [_store albumWithID:_selectedEntityID];
            BOOL inLib = NO;
            for (SPAlbum *a in albums) { if ([a.albumID isEqualToString:_selectedEntityID]) { inLib = YES; break; } }
            if (sel && !inLib && q.length == 0) {
                SPLibraryRowEntry *e = [SPLibraryRowEntry new];
                e.entityID = sel.albumID;
                e.name = sel.name;
                e.subtitle = sel.artistName;
                e.artworkURL = sel.artworkSmallURL ?: sel.artworkURL;
                e.uri = sel.uri;
                e.placeholderSymbol = @"square.stack";
                [rows addObject:e];
                [seen addObject:sel.albumID];
            }
        }
        for (SPAlbum *al in albums) {
            if ([seen containsObject:al.albumID]) continue;
            if (q.length && ![al.name localizedStandardContainsString:q] && ![al.artistName localizedStandardContainsString:q]) continue;
            SPLibraryRowEntry *e = [SPLibraryRowEntry new];
            e.entityID = al.albumID;
            e.name = al.name;
            e.subtitle = al.artistName;
            e.artworkURL = al.artworkSmallURL ?: al.artworkURL;
            e.uri = al.uri;
            e.placeholderSymbol = @"square.stack";
            [rows addObject:e];
        }
    } else {
        if (_selectedEntityID.length) {
            SPArtist *sel = [_store artistWithID:_selectedEntityID];
            BOOL inLib = NO;
            for (SPArtist *a in _store.libraryArtists) { if ([a.artistID isEqualToString:_selectedEntityID]) { inLib = YES; break; } }
            if (sel && !inLib && q.length == 0) {
                SPLibraryRowEntry *e = [SPLibraryRowEntry new];
                e.entityID = sel.artistID;
                e.name = sel.name;
                e.artworkURL = sel.artworkSmallURL ?: sel.artworkURL;
                e.uri = sel.uri;
                e.circular = YES;
                e.placeholderSymbol = @"person.fill";
                [rows addObject:e];
                [seen addObject:sel.artistID];
            }
        }
        for (SPArtist *ar in _store.libraryArtists) {
            if ([seen containsObject:ar.artistID]) continue;
            if (q.length && ![ar.name localizedStandardContainsString:q]) continue;
            SPLibraryRowEntry *e = [SPLibraryRowEntry new];
            e.entityID = ar.artistID;
            e.name = ar.name;
            e.artworkURL = ar.artworkSmallURL ?: ar.artworkURL;
            e.uri = ar.uri;
            e.circular = YES;
            e.placeholderSymbol = @"person.fill";
            [rows addObject:e];
        }
    }

    _list.selectedEntityID = _selectedEntityID;
    _list.entries = rows;
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    _filterField.frame = NSMakeRect(10.0, 8.0, MAX(40.0, w - 20.0), 26.0);
    _list.frame = NSMakeRect(0.0, 40.0, w, MAX(0.0, h - 40.0));
}

- (void)storeChanged:(SPChange *)change {
    if (change.libraryLists ||
        (_kind == SPLibraryListPlaylists && change.playlists.count > 0) ||
        (_kind == SPLibraryListAlbums && change.albums.count > 0) ||
        (_kind == SPLibraryListArtists && change.artists.count > 0)) {
        [self reloadItems];
    }
}

@end

#pragma mark - Legacy Grid Views (kept updated for compatibility)

@implementation SPAlbumsGridView {
    SPStore *_store;
    SPCardGridView *_gridView;
}
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _gridView = [[SPCardGridView alloc] initWithFrame:self.bounds];
    __weak typeof(self) weakSelf = self;
    _gridView.onSelectItem = ^(SPCardItem *item) { SPAlbum *al = item.representedObject; if (al.albumID.length) [weakSelf.navigator openAlbumWithID:al.albumID]; };
    _gridView.onPlayItem = ^(SPCardItem *item) { if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI]; };
    [self addSubview:_gridView];
    [_store addObserver:self];
    [self reloadAlbums];
    return self;
}
- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (SPCardGridView *)gridView { return _gridView; }
- (void)reloadAlbums {
    NSMutableArray<SPCardItem *> *cards = [NSMutableArray arrayWithCapacity:_store.libraryAlbums.count];
    for (SPAlbum *al in _store.libraryAlbums) {
        SPCardItem *c = [[SPCardItem alloc] initWithKey:al.albumID title:al.name subtitle:al.artistName artworkURL:al.artworkSmallURL ?: al.artworkURL circular:NO contextURI:al.uri representedObject:al];
        c.placeholderSymbol = @"opticaldisc";
        [cards addObject:c];
    }
    _gridView.items = cards;
}
- (void)layout { [super layout]; _gridView.frame = self.bounds; }
- (void)storeChanged:(SPChange *)change { if (change.libraryLists || change.albums.count > 0) [self reloadAlbums]; }
@end

@implementation SPArtistsGridView {
    SPStore *_store;
    SPCardGridView *_gridView;
}
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _gridView = [[SPCardGridView alloc] initWithFrame:self.bounds];
    __weak typeof(self) weakSelf = self;
    _gridView.onSelectItem = ^(SPCardItem *item) { SPArtist *ar = item.representedObject; if (ar.artistID.length) [weakSelf.navigator openArtistWithID:ar.artistID]; };
    _gridView.onPlayItem = ^(SPCardItem *item) { if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI]; };
    [self addSubview:_gridView];
    [_store addObserver:self];
    [self reloadArtists];
    return self;
}
- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (SPCardGridView *)gridView { return _gridView; }
- (void)reloadArtists {
    NSMutableArray<SPCardItem *> *cards = [NSMutableArray arrayWithCapacity:_store.libraryArtists.count];
    for (SPArtist *ar in _store.libraryArtists) {
        SPCardItem *c = [[SPCardItem alloc] initWithKey:ar.artistID title:ar.name subtitle:nil artworkURL:ar.artworkSmallURL ?: ar.artworkURL circular:YES contextURI:ar.uri representedObject:ar];
        c.placeholderSymbol = @"person.circle.fill";
        [cards addObject:c];
    }
    _gridView.items = cards;
}
- (void)layout { [super layout]; _gridView.frame = self.bounds; }
- (void)storeChanged:(SPChange *)change { if (change.libraryLists || change.artists.count > 0) [self reloadArtists]; }
@end

@implementation SPPlaylistsGridView {
    SPStore *_store;
    SPCardGridView *_gridView;
}
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _gridView = [[SPCardGridView alloc] initWithFrame:self.bounds];
    __weak typeof(self) weakSelf = self;
    _gridView.onSelectItem = ^(SPCardItem *item) { SPPlaylist *pl = item.representedObject; if (pl.playlistID.length) [weakSelf.navigator openPlaylistWithID:pl.playlistID]; };
    _gridView.onPlayItem = ^(SPCardItem *item) { if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI]; };
    [self addSubview:_gridView];
    [_store addObserver:self];
    [self reloadPlaylists];
    return self;
}
- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (SPCardGridView *)gridView { return _gridView; }
- (void)reloadPlaylists {
    NSMutableArray<SPCardItem *> *cards = [NSMutableArray arrayWithCapacity:_store.libraryPlaylists.count];
    for (SPPlaylist *pl in _store.libraryPlaylists) {
        NSString *sub = pl.ownerName.length ? [NSString stringWithFormat:@"By %@", pl.ownerName] : @"Playlist";
        SPCardItem *c = [[SPCardItem alloc] initWithKey:pl.playlistID title:pl.name subtitle:sub artworkURL:pl.artworkSmallURL ?: pl.artworkURL circular:NO contextURI:pl.uri representedObject:pl];
        c.placeholderSymbol = @"music.note.list";
        [cards addObject:c];
    }
    _gridView.items = cards;
}
- (void)layout { [super layout]; _gridView.frame = self.bounds; }
- (void)storeChanged:(SPChange *)change { if (change.libraryLists || change.playlists.count > 0) [self reloadPlaylists]; }
@end
