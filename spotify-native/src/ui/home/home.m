// Spotifly 1:1 StartpageView built on virtualized SPListView:
// 1) Recently Played (150pt cards)
// 2) Your Top Tracks (segmented 4 Weeks / 6 Months / 1 Year green picker + adaptive multi-column numbered grid)
// 3) Your Top Artists (130pt circular portraits with centered bold names)
// 4) Your Playlists (150pt cards + system-blue "Show All" link)
#import "ui/home/home.h"
#import "model/playlist.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"
#import "ui/kit/controls.h"
#import "ui/kit/grid.h"
#import "ui/kit/list.h"

static NSString *const kSPTopTracksRangeDefaultsKey = @"startpageTopTracksRange";

#pragma mark - SPTopTrackCellView & SPTopTracksSectionView (per-item small cells, zero Whippet GPU spike)

@interface SPTopTracksTitleView : NSView
@property (nonatomic) BOOL showEmptyState;
@end

@implementation SPTopTracksTitleView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    const SPTypographyScale *typo = SPThemeTypography();
    [@"Your Top Tracks" drawInRect:NSMakeRect(0.0, 16.0, self.bounds.size.width, 24.0)
                    withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    if (_showEmptyState) {
        [@"No top tracks yet." drawInRect:NSMakeRect(0.0, 56.0, self.bounds.size.width, 18.0)
                           withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }
}
@end

@interface SPTopTrackCellView : NSView
@property (nonatomic, weak, nullable) SPStore *store;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, strong, nullable) SPTrack *track;
@property (nonatomic) NSUInteger rank;
@property (nonatomic) BOOL hovered;
@property (nonatomic, copy, nullable) void (^onPlay)(void);
@end

@implementation SPTopTrackCellView {
    NSTrackingArea *_tracking;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (void)setTrack:(SPTrack *)track {
    if (_track == track) return;
    if (_track && ![_track.artworkSmallURL isEqualToString:track.artworkSmallURL] &&
        ![_track.artworkURL isEqualToString:track.artworkURL]) {
        [self.imageHolder removeAllImages];
    }
    _track = track;
    self.needsDisplay = YES;
}

- (void)setRank:(NSUInteger)rank {
    if (_rank == rank) return;
    _rank = rank;
    self.needsDisplay = YES;
}

- (void)setHovered:(BOOL)hovered {
    if (_hovered == hovered) return;
    _hovered = hovered;
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

- (void)mouseEntered:(NSEvent *)event { (void)event; self.hovered = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hovered = NO; }

- (void)mouseDown:(NSEvent *)event {
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    if (event.clickCount >= 2 && _onPlay) {
        _onPlay();
    }
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    if (!_track) return nil;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *play = [[NSMenuItem alloc] initWithTitle:@"Play" action:@selector(ctxPlay:) keyEquivalent:@""];
    play.target = self;
    play.image = SPSFSymbolImage(@"play.fill", 12.0, NSFontWeightRegular, nil);
    [menu addItem:play];

    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"Play Next" action:@selector(ctxQueue:) keyEquivalent:@""];
    q.target = self;
    q.image = SPSFSymbolImage(@"text.line.first.and.arrowtriangle.forward", 12.0, NSFontWeightRegular, nil);
    [menu addItem:q];

    BOOL fav = [_store isFavoriteTrackID:_track.trackID];
    NSMenuItem *like = [[NSMenuItem alloc] initWithTitle:fav ? @"Remove from Favorites" : @"Add to Favorites"
                                                  action:@selector(ctxFav:)
                                           keyEquivalent:@""];
    like.target = self;
    like.image = SPSFSymbolImage(fav ? @"heart.slash" : @"heart", 12.0, NSFontWeightRegular, nil);
    [menu addItem:like];

    if (_track.artistID.length) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *ar = [[NSMenuItem alloc] initWithTitle:@"Go to Artist" action:@selector(ctxArtist:) keyEquivalent:@""];
        ar.target = self;
        [menu addItem:ar];
    }
    if (_track.albumID.length) {
        NSMenuItem *al = [[NSMenuItem alloc] initWithTitle:@"Go to Album" action:@selector(ctxAlbum:) keyEquivalent:@""];
        al.target = self;
        [menu addItem:al];
    }
    return menu;
}

- (void)ctxPlay:(id)sender { (void)sender; if (_onPlay) _onPlay(); }
- (void)ctxQueue:(id)sender { (void)sender; if (_track) [_navigator addTrackToQueue:_track]; }
- (void)ctxFav:(id)sender { (void)sender; if (_track) [_navigator toggleFavoriteTrackID:_track.trackID]; }
- (void)ctxArtist:(id)sender { (void)sender; if (_track.artistID.length) [_navigator openArtistWithID:_track.artistID]; }
- (void)ctxAlbum:(id)sender { (void)sender; if (_track.albumID.length) [_navigator openAlbumWithID:_track.albumID]; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!_track) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    NSRect b = self.bounds;
    NSString *playingID = _store.playbackState.currentTrackID;
    BOOL isPlaying = (playingID.length > 0 && [playingID isEqualToString:_track.trackID]);

    if (_hovered) {
        CGContextSetFillColorWithColor(ctx, SPHoverFillColor().CGColor);
        CGPathRef p = CGPathCreateWithRoundedRect(NSInsetRect(b, 0.0, 1.0), 6.0, 6.0, NULL);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
    }

    CGContextSaveGState(ctx);
    if (!_track.playable) CGContextSetAlpha(ctx, 0.50);

    SPTextStyle rankStyle = {12.0, NSFontWeightRegular, 15.0, 0.0, YES};
    NSDictionary *rankAttrs = SPSemanticTextAttributes(rankStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight);
    NSString *rankStr = [NSString stringWithFormat:@"%lu", (unsigned long)_rank];
    [rankStr drawInRect:NSMakeRect(0.0, floor((b.size.height - 15.0) * 0.5), 18.0, 16.0)
         withAttributes:rankAttrs];

    CGFloat scale = self.window.backingScaleFactor ?: 2.0;
    CGRect artRect = CGRectMake(28.0, floor((b.size.height - 36.0) * 0.5), 36.0, 36.0);
    CGImageRef img = NULL;
    NSString *artURL = _track.artworkSmallURL.length ? _track.artworkSmallURL : _track.artworkURL;
    if (artURL.length) {
        NSURL *u = [NSURL URLWithString:artURL];
        if (u) img = [self.imageHolder imageWithURL:u pixels:ceil(36.0 * scale)];
    }
    SPDrawArtworkSemantic(ctx, img, artRect, 4.0, NO, @"music.note", 14.0, 0.0);

    CGFloat tx = 74.0;
    CGFloat tw = MAX(20.0, b.size.width - tx - 4.0);
    CGFloat textY = floor((b.size.height - 34.0) * 0.5);
    NSColor *titleCol = isPlaying ? SPAccentColor() : SPLabelColor();
    SPTextStyle titleStyle = isPlaying ? typo->bodyMedium : typo->body;
    [_track.name drawInRect:NSMakeRect(tx, textY, tw, 17.0)
             withAttributes:SPSemanticTextAttributes(titleStyle, titleCol, NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    [_track.artistName drawInRect:NSMakeRect(tx, textY + 18.0, tw, 15.0)
                   withAttributes:SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];

    CGContextRestoreGState(ctx);

    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(0.0, b.size.height - 1.0, b.size.width, 1.0));
}

@end

@interface SPTopTracksSectionView : NSView
@property (nonatomic, weak, nullable) SPStore *store;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, copy) NSArray<SPTrack *> *tracks;
@property (nonatomic, copy) NSString *rangeKey;
@property (nonatomic, copy, nullable) void (^onRangeChange)(NSString *rangeKey);

+ (CGFloat)preferredHeightForTrackCount:(NSUInteger)count width:(CGFloat)width;
@end

@implementation SPTopTracksSectionView {
    SPTopTracksTitleView *_titleView;
    SPSegmentedControl *_rangeControl;
    NSMutableArray<SPTopTrackCellView *> *_cells;
}

+ (NSUInteger)columnsForWidth:(CGFloat)width {
    CGFloat avail = MAX(260.0, width - SPThemeMetrics()->pageInset * 2.0);
    // Spotifly: GridItem(.adaptive(minimum: 260), spacing: 16)
    NSUInteger cols = (NSUInteger)MAX(1.0, floor((avail + 16.0) / (260.0 + 16.0)));
    return MIN(4, MAX(1, cols));
}

+ (CGFloat)preferredHeightForTrackCount:(NSUInteger)count width:(CGFloat)width {
    NSUInteger shown = MIN((NSUInteger)10, count);
    if (shown == 0) return 48.0 + 48.0;
    NSUInteger cols = [self columnsForWidth:width];
    NSUInteger rows = (shown + cols - 1) / cols;
    return 48.0 + (CGFloat)rows * 50.0 + 4.0;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _tracks = @[];
    _rangeKey = @"MID_TERM";
    _cells = [NSMutableArray new];

    _titleView = [[SPTopTracksTitleView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_titleView];

    _rangeControl = [SPSegmentedControl segmentedControlWithLabels:@[ @"4 Weeks", @"6 Months", @"1 Year" ]];
    _rangeControl.selectedSegment = 1;
    __weak typeof(self) weakSelf = self;
    _rangeControl.onSelectSegment = ^(NSInteger seg) {
        SPTopTracksSectionView *s = weakSelf;
        if (!s) return;
        NSString *key = @"MID_TERM";
        if (seg == 0) key = @"SHORT_TERM";
        else if (seg == 2) key = @"LONG_TERM";
        s->_rangeKey = key;
        if (s.onRangeChange) s.onRangeChange(key);
    };
    [self addSubview:_rangeControl];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (void)setRangeKey:(NSString *)rangeKey {
    _rangeKey = [rangeKey copy] ?: @"MID_TERM";
    NSInteger seg = 1;
    if ([_rangeKey isEqualToString:@"SHORT_TERM"]) seg = 0;
    else if ([_rangeKey isEqualToString:@"LONG_TERM"]) seg = 2;
    if (_rangeControl.selectedSegment != seg) {
        _rangeControl.selectedSegment = seg;
    }
}

- (void)setTracks:(NSArray<SPTrack *> *)tracks {
    NSUInteger limit = MIN((NSUInteger)10, tracks.count);
    _tracks = limit > 0 ? [tracks subarrayWithRange:NSMakeRange(0, limit)] : @[];
    _titleView.showEmptyState = (_tracks.count == 0);
    _titleView.needsDisplay = YES;
    [self syncCells];
}

- (void)playTrackAtIndex:(NSUInteger)i {
    if (i >= _tracks.count) return;
    SPTrack *tr = _tracks[i];
    if (!tr.playable) return;
    NSMutableArray<NSString *> *rest = [NSMutableArray new];
    for (NSUInteger j = i + 1; j < _tracks.count; j++) {
        if (_tracks[j].uri.length) [rest addObject:_tracks[j].uri];
    }
    [_navigator playTrackWithRadio:tr fallbackURIs:rest];
}

- (void)syncCells {
    NSUInteger count = _tracks.count;
    while (_cells.count > count) {
        SPTopTrackCellView *extra = _cells.lastObject;
        SPReleaseViewImages(extra);
        [extra removeFromSuperview];
        [_cells removeLastObject];
    }
    while (_cells.count < count) {
        SPTopTrackCellView *cell = [[SPTopTrackCellView alloc] initWithFrame:NSZeroRect];
        [self addSubview:cell];
        [_cells addObject:cell];
    }
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < count; i++) {
        SPTopTrackCellView *cell = _cells[i];
        cell.store = _store;
        cell.navigator = _navigator;
        cell.rank = i + 1;
        cell.track = _tracks[i];
        cell.onPlay = ^{
            [weakSelf playTrackAtIndex:i];
        };
        cell.needsDisplay = YES;
    }
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat padX = SPThemeMetrics()->pageInset;

    _titleView.frame = NSMakeRect(padX, 0.0, 260.0, _tracks.count == 0 ? 84.0 : 44.0);

    [_rangeControl sizeToFit];
    CGFloat segW = _rangeControl.frame.size.width;
    CGFloat segH = _rangeControl.frame.size.height;
    _rangeControl.frame = NSMakeRect(MAX(padX + 140.0, w - padX - segW), 14.0, segW, segH);

    NSUInteger cols = [SPTopTracksSectionView columnsForWidth:w];
    CGFloat gapX = 16.0;
    CGFloat avail = MAX(100.0, w - padX * 2.0);
    CGFloat colW = floor((avail - gapX * (CGFloat)(cols - 1)) / (CGFloat)cols);
    CGFloat rowH = 48.0;
    CGFloat rowGap = 2.0;
    CGFloat startY = 48.0;

    for (NSUInteger i = 0; i < _cells.count; i++) {
        NSUInteger r = i / cols;
        NSUInteger c = i % cols;
        _cells[i].frame = NSMakeRect(padX + (CGFloat)c * (colW + gapX),
                                     startY + (CGFloat)r * (rowH + rowGap),
                                     colW,
                                     rowH);
    }
}

@end

#pragma mark - SPHomeRowView & SPHomeListView

typedef NS_ENUM(NSInteger, SPHomeSectionKind) {
    SPHomeSectionRecentlyPlayed = 0,
    SPHomeSectionTopTracks,
    SPHomeSectionTopArtists,
    SPHomeSectionYourPlaylists,
};

@interface SPHomeRowView : SPListRowView
@property (nonatomic) SPHomeSectionKind sectionKind;
@property (nonatomic, strong, nullable) SPCardShelfView *shelfView;
@property (nonatomic, strong, nullable) SPTopTracksSectionView *topTracksView;
@end

@implementation SPHomeRowView

- (void)setSectionKind:(SPHomeSectionKind)sectionKind {
    _sectionKind = sectionKind;
    if (sectionKind == SPHomeSectionTopTracks) {
        _shelfView.hidden = YES;
        if (!_topTracksView) {
            _topTracksView = [[SPTopTracksSectionView alloc] initWithFrame:self.bounds];
            [self addSubview:_topTracksView];
        }
        _topTracksView.hidden = NO;
    } else {
        _topTracksView.hidden = YES;
        if (!_shelfView) {
            _shelfView = [[SPCardShelfView alloc] initWithFrame:self.bounds];
            [self addSubview:_shelfView];
        }
        _shelfView.hidden = NO;
    }
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    if (_shelfView && !_shelfView.hidden) _shelfView.frame = self.bounds;
    if (_topTracksView && !_topTracksView.hidden) _topTracksView.frame = self.bounds;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    if (_shelfView) {
        SPReleaseViewImages(_shelfView);
        _shelfView.items = @[];
    }
    if (_topTracksView) {
        SPReleaseViewImages(_topTracksView);
        _topTracksView.tracks = @[];
    }
}

@end

@interface SPHomeSectionListView : SPListView
@property (nonatomic, weak, nullable) SPStore *store;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, copy) NSArray<NSNumber *> *sections;
@property (nonatomic, copy) NSArray<SPCardItem *> *recentlyPlayedCards;
@property (nonatomic, copy) NSArray<SPTrack *> *topTracks;
@property (nonatomic, copy) NSArray<SPCardItem *> *topArtistCards;
@property (nonatomic, copy) NSArray<SPCardItem *> *playlistCards;
@property (nonatomic, copy) NSString *rangeKey;
@property (nonatomic, copy, nullable) void (^onRangeChange)(NSString *rangeKey);
@end

@implementation SPHomeSectionListView

- (void)reloadSections {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:_sections.count];
    for (NSNumber *n in _sections) {
        [keys addObject:[NSString stringWithFormat:@"home-sec:%ld", (long)n.integerValue]];
    }
    [self showKeys:keys];
    // Refresh visible rows in place when section count stayed identical.
    [self refreshKeys:[NSSet setWithArray:keys]];
}

- (SPListRowView *)makeRow {
    return [[SPHomeRowView alloc] initWithFrame:NSZeroRect];
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width {
    if (index >= _sections.count) return 240.0;
    SPHomeSectionKind kind = (SPHomeSectionKind)_sections[index].integerValue;
    switch (kind) {
        case SPHomeSectionRecentlyPlayed:
            return [SPCardShelfView preferredHeightForArtSize:150.0 circular:NO];
        case SPHomeSectionTopTracks:
            return [SPTopTracksSectionView preferredHeightForTrackCount:_topTracks.count width:MAX(320.0, width)];
        case SPHomeSectionTopArtists:
            return [SPCardShelfView preferredHeightForArtSize:130.0 circular:YES];
        case SPHomeSectionYourPlaylists:
            return [SPCardShelfView preferredHeightForArtSize:150.0 circular:NO];
    }
    return 240.0;
}

- (void)showIndex:(NSUInteger)index inRow:(SPHomeRowView *)row {
    if (index >= _sections.count) return;
    SPHomeSectionKind kind = (SPHomeSectionKind)_sections[index].integerValue;
    row.sectionKind = kind;
    __weak typeof(self) weakSelf = self;

    if (kind == SPHomeSectionTopTracks) {
        row.topTracksView.store = _store;
        row.topTracksView.navigator = _navigator;
        row.topTracksView.rangeKey = _rangeKey;
        row.topTracksView.tracks = _topTracks;
        row.topTracksView.onRangeChange = ^(NSString *rk) {
            if (weakSelf.onRangeChange) weakSelf.onRangeChange(rk);
        };
        return;
    }

    SPCardShelfView *shelf = row.shelfView;
    shelf.trailingActionTitle = nil;
    shelf.onTrailingAction = nil;

    if (kind == SPHomeSectionRecentlyPlayed) {
        shelf.sectionTitle = @"Recently Played";
        shelf.cardArtSize = 150.0;
        shelf.items = _recentlyPlayedCards;
    } else if (kind == SPHomeSectionTopArtists) {
        shelf.sectionTitle = @"Your Top Artists";
        shelf.cardArtSize = 130.0;
        shelf.items = _topArtistCards;
    } else if (kind == SPHomeSectionYourPlaylists) {
        shelf.sectionTitle = @"Your Playlists";
        shelf.cardArtSize = 150.0;
        shelf.trailingActionTitle = @"Show All";
        shelf.onTrailingAction = ^{
            [weakSelf.navigator openPlaylists];
        };
        shelf.items = _playlistCards;
    }

    shelf.onSelectItem = ^(SPCardItem *card) {
        [weakSelf openCard:card];
    };
    shelf.onPlayItem = ^(SPCardItem *card) {
        if (card.contextURI.length) [weakSelf.navigator playContextURI:card.contextURI];
    };
}

- (void)openCard:(SPCardItem *)card {
    if (card.isLikedSongsTile) {
        [_navigator openFavorites];
        return;
    }
    id obj = card.representedObject;
    if ([obj isKindOfClass:SPShelfItem.class]) {
        SPShelfItem *it = (SPShelfItem *)obj;
        if (it.kind == SPShelfItemAlbum) [_navigator openAlbumWithID:it.entityID];
        else if (it.kind == SPShelfItemArtist) [_navigator openArtistWithID:it.entityID];
        else [_navigator openPlaylistWithID:it.entityID];
    } else if ([obj isKindOfClass:SPArtist.class]) {
        [_navigator openArtistWithID:((SPArtist *)obj).artistID];
    } else if ([obj isKindOfClass:SPPlaylist.class]) {
        [_navigator openPlaylistWithID:((SPPlaylist *)obj).playlistID];
    } else if ([obj isKindOfClass:SPAlbum.class]) {
        [_navigator openAlbumWithID:((SPAlbum *)obj).albumID];
    }
}

@end

#pragma mark - SPHomeView

@implementation SPHomeView {
    SPStore *_store;
    SPHomeSectionListView *_list;
    NSMutableDictionary<NSString *, NSArray<SPTrack *> *> *_topTracksByRange;
    NSMutableDictionary<NSString *, NSArray<SPArtist *> *> *_topArtistsByRange;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _topTracksByRange = [NSMutableDictionary new];
    _topArtistsByRange = [NSMutableDictionary new];

    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kSPTopTracksRangeDefaultsKey];
    if ([saved isEqualToString:@"SHORT_TERM"] || [saved isEqualToString:@"MID_TERM"] || [saved isEqualToString:@"LONG_TERM"]) {
        _selectedRangeKey = saved;
    } else {
        _selectedRangeKey = @"MID_TERM";
    }

    _list = [[SPHomeSectionListView alloc] initWithFrame:self.bounds];
    _list.store = store;
    _list.navigator = navigator;
    _list.topInset = 0.0;
    _list.bottomInset = SPThemeMetrics()->nowPlayingContentClearance;
    __weak typeof(self) weakSelf = self;
    _list.onRangeChange = ^(NSString *rangeKey) {
        SPHomeView *s = weakSelf;
        if (!s) return;
        s->_selectedRangeKey = [rangeKey copy];
        [NSUserDefaults.standardUserDefaults setObject:rangeKey forKey:kSPTopTracksRangeDefaultsKey];
        [s reloadShelves];
        [s.navigator requestTopContentForRange:rangeKey];
    };
    [self addSubview:_list];

    [_store addObserver:self];
    [self reloadShelves];
    return self;
}

- (void)dealloc {
    [_store removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (NSUInteger)shelfCount { return _store.homeShelves.count; }

- (void)setTopTracks:(NSArray<SPTrack *> *)tracks topArtists:(NSArray<SPArtist *> *)artists forRange:(NSString *)rangeKey {
    if (!rangeKey.length) return;
    _topTracksByRange[rangeKey] = [tracks copy] ?: @[];
    _topArtistsByRange[rangeKey] = [artists copy] ?: @[];
    if ([rangeKey isEqualToString:_selectedRangeKey]) {
        [self reloadShelves];
    }
}

- (NSArray<SPCardItem *> *)buildRecentlyPlayedCards {
    SPHomeShelf *recent = nil;
    for (SPHomeShelf *sh in _store.homeShelves) {
        if (sh.isRecentlyPlayed) { recent = sh; break; }
    }
    if (!recent && _store.homeShelves.count > 0) {
        recent = _store.homeShelves.firstObject;
    }

    NSMutableArray<SPCardItem *> *cards = [NSMutableArray new];
    if (recent && recent.items.count > 0) {
        for (SPShelfItem *it in recent.items) {
            NSString *uri = nil;
            BOOL circular = NO;
            NSString *sym = @"music.note";
            if (it.kind == SPShelfItemAlbum) {
                uri = [NSString stringWithFormat:@"spotify:album:%@", it.entityID];
                sym = @"opticaldisc";
            } else if (it.kind == SPShelfItemArtist) {
                uri = [NSString stringWithFormat:@"spotify:artist:%@", it.entityID];
                circular = YES;
                sym = @"person.circle.fill";
            } else {
                uri = [NSString stringWithFormat:@"spotify:playlist:%@", it.entityID];
                sym = @"music.note.list";
            }
            NSString *sub = it.subtitle;
            if (!sub.length && it.kind == SPShelfItemPlaylist) {
                SPPlaylist *pl = [_store playlistWithID:it.entityID];
                if (pl.ownerName.length) sub = [NSString stringWithFormat:@"By %@", pl.ownerName];
            } else if (!sub.length && it.kind == SPShelfItemAlbum) {
                SPAlbum *al = [_store albumWithID:it.entityID];
                if (al.artistName.length) sub = al.artistName;
            }

            SPCardItem *card = [[SPCardItem alloc] initWithKey:[NSString stringWithFormat:@"rp:%ld:%@", (long)it.kind, it.entityID]
                                                         title:it.title
                                                      subtitle:sub
                                                    artworkURL:it.artworkURL
                                                      circular:circular
                                                    contextURI:uri
                                             representedObject:it];
            card.placeholderSymbol = sym;
            if ([it.title isEqualToString:@"Liked Songs"] || [it.entityID isEqualToString:@"tracks"]) {
                card.isLikedSongsTile = YES;
            }
            [cards addObject:card];
        }
    } else if (_store.libraryAlbums.count > 0 || _store.libraryPlaylists.count > 0) {
        // Immediate local fallback before network home refresh finishes
        if (_store.libraryTracks.count > 0) {
            SPCardItem *liked = [[SPCardItem alloc] initWithKey:@"rp:liked"
                                                          title:@"Liked Songs"
                                                       subtitle:[NSString stringWithFormat:@"%lu songs", (unsigned long)_store.libraryTracks.count]
                                                     artworkURL:nil
                                                       circular:NO
                                                     contextURI:SPLikedSongsPlaylistURI
                                              representedObject:nil];
            liked.isLikedSongsTile = YES;
            [cards addObject:liked];
        }
        for (SPAlbum *al in _store.libraryAlbums) {
            SPCardItem *c = [[SPCardItem alloc] initWithKey:[NSString stringWithFormat:@"rp:alb:%@", al.albumID]
                                                      title:al.name
                                                   subtitle:al.artistName
                                                 artworkURL:al.artworkSmallURL ?: al.artworkURL
                                                   circular:NO
                                                 contextURI:al.uri
                                          representedObject:al];
            c.placeholderSymbol = @"opticaldisc";
            [cards addObject:c];
            if (cards.count >= 10) break;
        }
    }
    return cards;
}

- (NSArray<SPTrack *> *)resolveTopTracks {
    NSArray<SPTrack *> *remote = _topTracksByRange[_selectedRangeKey];
    if (remote.count > 0) return remote;
    // Instant local fallback on first frame before userTopContent returns
    NSArray<SPTrack *> *lib = _store.libraryTracks;
    if (lib.count == 0) return @[];
    return [lib subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, lib.count))];
}

- (NSArray<SPCardItem *> *)buildTopArtistCards {
    NSArray<SPArtist *> *artists = _topArtistsByRange[_selectedRangeKey];
    if (artists.count == 0) {
        NSArray<SPArtist *> *lib = _store.libraryArtists;
        if (lib.count > 0) {
            artists = [lib subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, lib.count))];
        }
    }
    NSMutableArray<SPCardItem *> *cards = [NSMutableArray arrayWithCapacity:artists.count];
    for (SPArtist *ar in artists) {
        SPCardItem *c = [[SPCardItem alloc] initWithKey:[NSString stringWithFormat:@"ta:%@", ar.artistID]
                                                  title:ar.name
                                               subtitle:nil
                                             artworkURL:ar.artworkSmallURL ?: ar.artworkURL
                                               circular:YES
                                             contextURI:ar.uri
                                      representedObject:ar];
        c.placeholderSymbol = @"person.circle.fill";
        [cards addObject:c];
    }
    return cards;
}

- (NSArray<SPCardItem *> *)buildPlaylistCards {
    NSArray<SPPlaylist *> *playlists = _store.libraryPlaylists;
    NSUInteger limit = MIN((NSUInteger)9, playlists.count);
    NSMutableArray<SPCardItem *> *cards = [NSMutableArray arrayWithCapacity:limit];
    for (NSUInteger i = 0; i < limit; i++) {
        SPPlaylist *pl = playlists[i];
        NSString *sub = pl.ownerName.length ? [NSString stringWithFormat:@"By %@", pl.ownerName] : @"Playlist";
        SPCardItem *c = [[SPCardItem alloc] initWithKey:[NSString stringWithFormat:@"yp:%@", pl.playlistID]
                                                  title:pl.name
                                               subtitle:sub
                                             artworkURL:pl.artworkSmallURL ?: pl.artworkURL
                                               circular:NO
                                             contextURI:pl.uri
                                      representedObject:pl];
        c.placeholderSymbol = @"music.note.list";
        [cards addObject:c];
    }
    return cards;
}

- (void)reloadShelves {
    NSArray<SPCardItem *> *recent = [self buildRecentlyPlayedCards];
    NSArray<SPTrack *> *topTracks = [self resolveTopTracks];
    NSArray<SPCardItem *> *topArtists = [self buildTopArtistCards];
    NSArray<SPCardItem *> *playlists = [self buildPlaylistCards];

    NSMutableArray<NSNumber *> *sections = [NSMutableArray new];
    if (recent.count > 0) [sections addObject:@(SPHomeSectionRecentlyPlayed)];
    [sections addObject:@(SPHomeSectionTopTracks)];
    if (topArtists.count > 0) [sections addObject:@(SPHomeSectionTopArtists)];
    if (playlists.count > 0) [sections addObject:@(SPHomeSectionYourPlaylists)];

    _list.rangeKey = _selectedRangeKey;
    _list.recentlyPlayedCards = recent;
    _list.topTracks = topTracks;
    _list.topArtistCards = topArtists;
    _list.playlistCards = playlists;
    _list.sections = sections;
    [_list reloadSections];
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    _list.frame = self.bounds;
}

- (void)storeChanged:(SPChange *)change {
    if (change.homeShelves || change.profile || change.libraryLists || change.playback) {
        [self reloadShelves];
    }
}

@end
