// Spotifly 1:1 Album, Artist, Playlist, and User Profile detail views using SPDetailHeaderView and virtualized tables/grids.
#import "ui/detail/detail.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"

#pragma mark - SPAlbumDetailView

@implementation SPAlbumDetailView {
    SPStore *_store;
    SPDetailHeaderView *_headerView;
    SPTrackListView *_trackList;
}

- (instancetype)initWithFrame:(NSRect)frame albumID:(NSString *)albumID store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _albumID = [albumID copy];
    _store = store;
    _navigator = navigator;

    _headerView = [[SPDetailHeaderView alloc] initWithFrame:NSZeroRect];
    _headerView.placeholderSymbol = @"music.note";
    _headerView.showPlayButton = YES;
    _headerView.showShuffleButton = YES;
    _headerView.showLibraryButton = YES;
    _headerView.libraryOnTitle = @"In Library";
    _headerView.libraryOffTitle = @"Add to Library";
    __weak typeof(self) weakSelf = self;
    _headerView.onPlay = ^{
        SPAlbumDetailView *s = weakSelf;
        if (!s) return;
        SPAlbum *al = [s->_store albumWithID:s->_albumID];
        if (al.uri.length) [s.navigator playContextURI:al.uri];
    };
    _headerView.onShuffle = ^{
        SPAlbumDetailView *s = weakSelf;
        if (!s) return;
        [s.navigator setShuffleEnabled:YES];
        SPAlbum *al = [s->_store albumWithID:s->_albumID];
        if (al.uri.length) [s.navigator playContextURI:al.uri];
    };
    _headerView.onLibraryToggle = ^{
        SPAlbumDetailView *s = weakSelf;
        if (!s) return;
        [s.navigator toggleSaveAlbumID:s->_albumID];
    };
    _headerView.onMetadataLink = ^{
        SPAlbumDetailView *s = weakSelf;
        if (!s) return;
        SPAlbum *al = [s->_store albumWithID:s->_albumID];
        if (al.artistID.length) [s.navigator openArtistWithID:al.artistID];
    };
    [self addSubview:_headerView];

    _trackList = [[SPTrackListView alloc] initWithFrame:NSZeroRect store:store navigator:navigator];
    _trackList.showArtwork = NO;
    _trackList.showAlbumColumn = NO;
    _trackList.showColumnHeader = YES;
    _trackList.sortable = NO;
    _trackList.playWithSongRadio = NO;
    _trackList.topInset = 2.0;
    _trackList.bottomInset = SPThemeMetrics()->nowPlayingContentClearance;
    [self addSubview:_trackList];

    [_store addObserver:self];
    [self reloadData];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (SPTrackListView *)trackList { return _trackList; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (BOOL)isAlbumSaved {
    for (SPAlbum *a in _store.libraryAlbums) {
        if ([a.albumID isEqualToString:_albumID]) return YES;
    }
    return NO;
}

- (void)reloadData {
    SPAlbum *album = [_store albumWithID:_albumID];
    _trackList.contextURI = album.uri;
    NSMutableArray<SPTrack *> *tracks = [NSMutableArray new];
    int64_t totalMs = 0;
    for (NSString *tid in album.trackIDs) {
        SPTrack *t = [_store trackWithID:tid];
        if (t) {
            [tracks addObject:t];
            totalMs += MAX(0, t.durationMs);
        }
    }
    if (tracks.count == 0) {
        for (SPTrack *t in _store.libraryTracks) {
            if ([t.albumID isEqualToString:_albumID]) {
                [tracks addObject:t];
                totalMs += MAX(0, t.durationMs);
            }
        }
    }
    _trackList.tracks = tracks;

    NSString *year = album.releaseDate.length >= 4 ? [album.releaseDate substringToIndex:4] : nil;
    _headerView.kindText = year.length ? [NSString stringWithFormat:@"Album · %@", year] : @"Album";
    _headerView.titleText = album.name.length ? album.name : @"Album";
    _headerView.artworkURL = album.artworkURL.length ? album.artworkURL : album.artworkSmallURL;
    _headerView.metadataLinkText = album.artistName;
    NSInteger cnt = album.totalTrackCount > 0 ? album.totalTrackCount : (NSInteger)tracks.count;
    NSString *countStr = (cnt == 1) ? @"1 song" : [NSString stringWithFormat:@"%ld songs", (long)cnt];
    NSString *durStr = SPFormatTotalDurationMs(totalMs > 0 ? totalMs : album.totalDurationMs);
    _headerView.metadataText = durStr.length
        ? [NSString stringWithFormat:@"· %@ · %@", countStr, durStr]
        : [NSString stringWithFormat:@"· %@", countStr];
    _headerView.playEnabled = (tracks.count > 0 || album.uri.length > 0);
    _headerView.libraryButtonOn = [self isAlbumSaved];
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
    if ([change.albums containsObject:_albumID] || change.libraryLists || change.tracks.count > 0) {
        [self reloadData];
    } else {
        [_trackList applyStoreChange:change];
    }
}

@end

#pragma mark - SPArtistDetailView

typedef NS_ENUM(NSInteger, SPDiscographyGroup) {
    SPDiscographyAlbums = 0,
    SPDiscographySingles,
    SPDiscographyCompilations,
};

@interface SPArtistDocumentView : NSView
@property (nonatomic) BOOL showPopular;
@property (nonatomic) CGFloat popularHeadingY;
@property (nonatomic) CGFloat discographyHeadingY;
@property (nonatomic) BOOL discographyEmpty;
@end

@implementation SPArtistDocumentView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat padX = SPThemeMetrics()->pageInset;

    if (_showPopular) {
        [@"Popular" drawInRect:NSMakeRect(padX, _popularHeadingY, 200.0, 24.0)
                withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    }
    [@"Discography" drawInRect:NSMakeRect(padX, _discographyHeadingY, 200.0, 24.0)
                withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    if (_discographyEmpty) {
        [@"No releases in this section." drawInRect:NSMakeRect(padX, _discographyHeadingY + 34.0, 260.0, 18.0)
                                    withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }
}

@end

@implementation SPArtistDetailView {
    SPStore *_store;
    NSScrollView *_scroll;
    SPArtistDocumentView *_doc;
    SPDetailHeaderView *_headerView;
    SPTrackListView *_topTracksList;
    SPSegmentedControl *_discogPicker;
    SPCardGridView *_discographyGrid;
    SPDiscographyGroup _selectedGroup;
    BOOL _userPickedGroup;
}

- (instancetype)initWithFrame:(NSRect)frame artistID:(NSString *)artistID store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _artistID = [artistID copy];
    _store = store;
    _navigator = navigator;

    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = NO;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;

    _doc = [[SPArtistDocumentView alloc] initWithFrame:self.bounds];
    _scroll.documentView = _doc;
    [self addSubview:_scroll];

    _headerView = [[SPDetailHeaderView alloc] initWithFrame:NSZeroRect];
    _headerView.artworkCircular = YES;
    _headerView.placeholderSymbol = @"person.fill";
    _headerView.kindText = @"Artist";
    _headerView.showPlayButton = YES;
    _headerView.showShuffleButton = NO;
    _headerView.showLibraryButton = YES;
    _headerView.libraryOnTitle = @"Following";
    _headerView.libraryOffTitle = @"Follow";
    __weak typeof(self) weakSelf = self;
    _headerView.onPlay = ^{
        SPArtistDetailView *s = weakSelf;
        if (!s) return;
        SPArtist *ar = [s->_store artistWithID:s->_artistID];
        if (ar.uri.length) [s.navigator playContextURI:ar.uri];
    };
    _headerView.onLibraryToggle = ^{
        SPArtistDetailView *s = weakSelf;
        if (!s) return;
        [s.navigator toggleFollowArtistID:s->_artistID];
    };
    [_doc addSubview:_headerView];

    _topTracksList = [[SPTrackListView alloc] initWithFrame:NSZeroRect store:store navigator:navigator];
    _topTracksList.showArtwork = YES;
    _topTracksList.showAlbumColumn = YES;
    _topTracksList.playWithSongRadio = YES;
    _topTracksList.scrollingEnabled = NO;
    _topTracksList.bottomInset = 4.0;
    [_doc addSubview:_topTracksList];

    _discogPicker = [SPSegmentedControl segmentedControlWithLabels:@[ @"Albums", @"Singles & EPs", @"Compilations" ]];
    _discogPicker.selectedSegment = 0;
    _discogPicker.onSelectSegment = ^(NSInteger seg) {
        SPArtistDetailView *s = weakSelf;
        if (!s) return;
        s->_userPickedGroup = YES;
        s->_selectedGroup = (SPDiscographyGroup)seg;
        [s reloadData];
    };
    [_doc addSubview:_discogPicker];

    _discographyGrid = [[SPCardGridView alloc] initWithFrame:NSZeroRect];
    _discographyGrid.topPadding = 8.0;
    _discographyGrid.bottomPadding = SPThemeMetrics()->nowPlayingContentClearance;
    _discographyGrid.scrollingEnabled = NO;
    _discographyGrid.onSelectItem = ^(SPCardItem *item) {
        SPAlbum *al = (SPAlbum *)item.representedObject;
        if (al.albumID.length) [weakSelf.navigator openAlbumWithID:al.albumID];
    };
    _discographyGrid.onPlayItem = ^(SPCardItem *item) {
        if (item.contextURI.length) [weakSelf.navigator playContextURI:item.contextURI];
    };
    [_doc addSubview:_discographyGrid];

    [_store addObserver:self];
    [self reloadData];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (SPTrackListView *)topTracksList { return _topTracksList; }
- (SPCardGridView *)discographyGrid { return _discographyGrid; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (BOOL)isArtistFollowed {
    for (SPArtist *a in _store.libraryArtists) {
        if ([a.artistID isEqualToString:_artistID]) return YES;
    }
    return NO;
}

+ (SPDiscographyGroup)groupForAlbum:(SPAlbum *)al {
    NSString *t = al.albumType.lowercaseString ?: @"";
    if ([t isEqualToString:@"single"] || [t isEqualToString:@"ep"]) return SPDiscographySingles;
    if ([t isEqualToString:@"compilation"]) return SPDiscographyCompilations;
    return SPDiscographyAlbums;
}

- (void)reloadData {
    SPArtist *artist = [_store artistWithID:_artistID];
    _headerView.titleText = artist.name.length ? artist.name : @"Artist";
    _headerView.artworkURL = artist.artworkURL.length ? artist.artworkURL : artist.artworkSmallURL;
    _headerView.libraryButtonOn = [self isArtistFollowed];

    // Popular tracks
    NSMutableArray<SPTrack *> *topTracks = [NSMutableArray new];
    for (NSString *tid in artist.topTrackIDs) {
        SPTrack *t = [_store trackWithID:tid];
        if (t) [topTracks addObject:t];
    }
    if (topTracks.count == 0) {
        for (SPTrack *t in _store.libraryTracks) {
            if ([t.artistID isEqualToString:_artistID]) {
                [topTracks addObject:t];
                if (topTracks.count >= 5) break;
            }
        }
    }
    _topTracksList.tracks = topTracks;

    // Collect all discography albums
    NSMutableArray<SPAlbum *> *allAlbums = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSString *alID in artist.albumIDs) {
        SPAlbum *al = [_store albumWithID:alID];
        if (al && ![seen containsObject:al.albumID]) {
            [seen addObject:al.albumID];
            [allAlbums addObject:al];
        }
    }
    if (allAlbums.count == 0) {
        for (SPAlbum *al in _store.libraryAlbums) {
            if ([al.artistID isEqualToString:_artistID] && ![seen containsObject:al.albumID]) {
                [seen addObject:al.albumID];
                [allAlbums addObject:al];
            }
        }
    }

    if (!_userPickedGroup && allAlbums.count > 0) {
        // Default to first group that has releases (matching Spotifly ArtistDetailView)
        SPDiscographyGroup best = SPDiscographyAlbums;
        BOOL hasAlbums = NO, hasSingles = NO, hasComps = NO;
        for (SPAlbum *al in allAlbums) {
            SPDiscographyGroup g = [SPArtistDetailView groupForAlbum:al];
            if (g == SPDiscographyAlbums) hasAlbums = YES;
            else if (g == SPDiscographySingles) hasSingles = YES;
            else hasComps = YES;
        }
        if (hasAlbums) best = SPDiscographyAlbums;
        else if (hasSingles) best = SPDiscographySingles;
        else if (hasComps) best = SPDiscographyCompilations;
        _selectedGroup = best;
        _discogPicker.selectedSegment = (NSInteger)best;
    }

    NSMutableArray<SPCardItem *> *discog = [NSMutableArray new];
    for (SPAlbum *al in allAlbums) {
        if ([SPArtistDetailView groupForAlbum:al] != _selectedGroup) continue;
        SPCardItem *card = [[SPCardItem alloc] initWithKey:al.albumID
                                                     title:al.name
                                                  subtitle:(al.releaseDate.length >= 4 ? [al.releaseDate substringToIndex:4] : @"")
                                                artworkURL:al.artworkSmallURL ?: al.artworkURL
                                                  circular:NO
                                                contextURI:al.uri
                                         representedObject:al];
        card.placeholderSymbol = @"opticaldisc";
        [discog addObject:card];
    }
    _discographyGrid.items = discog;
    _doc.discographyEmpty = (discog.count == 0);
    self.needsLayout = YES;
    _doc.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    CGFloat w = MAX(320.0, self.bounds.size.width);
    CGFloat padX = SPThemeMetrics()->pageInset;

    CGFloat headerH = [SPDetailHeaderView preferredHeightForWidth:w hasDescription:NO];
    _headerView.frame = NSMakeRect(0.0, 0.0, w, headerH);

    CGFloat y = headerH + 18.0;
    CGFloat topTracksH = _topTracksList.tracks.count > 0
        ? ((CGFloat)_topTracksList.tracks.count * SPThemeMetrics()->trackRowHeight + 8.0)
        : 0.0;
    if (topTracksH > 0) {
        _doc.showPopular = YES;
        _doc.popularHeadingY = y;
        y += 30.0;
        _topTracksList.hidden = NO;
        _topTracksList.frame = NSMakeRect(0.0, y, w, topTracksH);
        y += topTracksH + 18.0;
    } else {
        _doc.showPopular = NO;
        _topTracksList.hidden = YES;
    }

    _doc.discographyHeadingY = y;
    [_discogPicker sizeToFit];
    CGFloat pw = _discogPicker.frame.size.width;
    CGFloat ph = _discogPicker.frame.size.height;
    _discogPicker.frame = NSMakeRect(MAX(padX + 120.0, w - padX - pw), y - 2.0, pw, ph);
    y += 32.0;

    // Guarantee >= 200pt discography height even at min window size (760x520).
    CGFloat discogH = _discographyGrid.items.count > 0
        ? MAX(220.0, [_discographyGrid contentHeightForWidth:w])
        : MAX(180.0, self.bounds.size.height - y);
    _discographyGrid.frame = NSMakeRect(0.0, y, w, discogH);
    CGFloat totalH = MAX(self.bounds.size.height, y + discogH);
    _doc.frame = NSMakeRect(0.0, 0.0, w, totalH);
    _doc.needsDisplay = YES;
}

- (void)storeChanged:(SPChange *)change {
    BOOL relevantTrack = NO;
    if (change.tracks.count > 0) {
        SPArtist *ar = [_store artistWithID:_artistID];
        for (NSString *tid in ar.topTrackIDs) {
            if ([change.tracks containsObject:tid]) { relevantTrack = YES; break; }
        }
    }
    if ([change.artists containsObject:_artistID] || change.albums.count > 0 || change.libraryLists || relevantTrack) {
        [self reloadData];
    } else {
        [_topTracksList applyStoreChange:change];
    }
}

@end

#pragma mark - SPPlaylistDetailView

@implementation SPPlaylistDetailView {
    SPStore *_store;
    SPDetailHeaderView *_headerView;
    SPTrackListView *_trackList;
}

- (instancetype)initWithFrame:(NSRect)frame playlistID:(NSString *)playlistID store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _playlistID = [playlistID copy];
    _store = store;
    _navigator = navigator;

    _headerView = [[SPDetailHeaderView alloc] initWithFrame:NSZeroRect];
    _headerView.placeholderSymbol = @"music.note.list";
    _headerView.showPlayButton = YES;
    _headerView.showShuffleButton = YES;
    _headerView.showMoreButton = YES;
    _headerView.libraryOnTitle = @"In Library";
    _headerView.libraryOffTitle = @"Add to Library";
    __weak typeof(self) weakSelf = self;
    _headerView.onPlay = ^{
        SPPlaylistDetailView *s = weakSelf;
        if (!s) return;
        SPPlaylist *pl = [s->_store playlistWithID:s->_playlistID];
        if (pl.uri.length) [s.navigator playContextURI:pl.uri];
    };
    _headerView.onShuffle = ^{
        SPPlaylistDetailView *s = weakSelf;
        if (!s) return;
        [s.navigator setShuffleEnabled:YES];
        SPPlaylist *pl = [s->_store playlistWithID:s->_playlistID];
        if (pl.uri.length) [s.navigator playContextURI:pl.uri];
    };
    _headerView.onLibraryToggle = ^{
        SPPlaylistDetailView *s = weakSelf;
        if (!s) return;
        [s.navigator toggleFollowPlaylistID:s->_playlistID];
    };
    _headerView.onMore = ^(NSView *anchor) {
        [weakSelf showPlaylistMenuFromView:anchor];
    };
    [self addSubview:_headerView];

    _trackList = [[SPTrackListView alloc] initWithFrame:NSZeroRect store:store navigator:navigator];
    _trackList.showArtwork = YES;
    _trackList.showAlbumColumn = YES;
    _trackList.showColumnHeader = YES;
    _trackList.sortable = YES;
    _trackList.playWithSongRadio = NO;
    _trackList.topInset = 2.0;
    _trackList.bottomInset = SPThemeMetrics()->nowPlayingContentClearance;
    _trackList.extraMenuItemsProvider = ^NSArray<NSMenuItem *> *(SPTrack *track, NSUInteger index) {
        SPPlaylistDetailView *s = weakSelf;
        if (!s) return nil;
        SPPlaylist *pl = [s->_store playlistWithID:s->_playlistID];
        NSString *uid = (index < pl.items.count && [pl.items[index].trackID isEqualToString:track.trackID])
            ? pl.items[index].uid : nil;
        NSMenuItem *rem = [[NSMenuItem alloc] initWithTitle:@"Remove from this Playlist"
                                                     action:@selector(removeTrackFromPlaylist:)
                                              keyEquivalent:@""];
        rem.target = s;
        rem.representedObject = uid.length ? @{ @"trackID": track.trackID, @"uid": uid } : @{ @"trackID": track.trackID };
        rem.image = SPSFSymbolImage(@"trash", 12.0, NSFontWeightRegular, nil);
        return @[ rem ];
    };
    [self addSubview:_trackList];

    [_store addObserver:self];
    [self reloadData];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (SPTrackListView *)trackList { return _trackList; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (BOOL)isOwnerOfPlaylist:(SPPlaylist *)pl {
    NSString *me = _store.userProfile.username;
    return (me.length > 0 && [pl.ownerID isEqualToString:me]);
}

- (BOOL)isFollowedPlaylist {
    for (SPPlaylist *p in _store.libraryPlaylists) {
        if ([p.playlistID isEqualToString:_playlistID]) return YES;
    }
    return NO;
}

- (void)showPlaylistMenuFromView:(NSView *)anchor {
    SPPlaylist *pl = [_store playlistWithID:_playlistID];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"Edit Details..." action:@selector(renamePlaylistPrompt:) keyEquivalent:@""];
    rename.target = self;
    rename.image = SPSFSymbolImage(@"pencil", 12.0, NSFontWeightRegular, nil);
    [menu addItem:rename];

    NSMenuItem *copyLink = [[NSMenuItem alloc] initWithTitle:@"Copy Link" action:@selector(copyPlaylistLink:) keyEquivalent:@""];
    copyLink.target = self;
    copyLink.image = SPSFSymbolImage(@"link", 12.0, NSFontWeightRegular, nil);
    [menu addItem:copyLink];

    [menu addItem:[NSMenuItem separatorItem]];

    NSString *delTitle = [self isOwnerOfPlaylist:pl] ? @"Delete Playlist" : @"Unfollow Playlist";
    NSMenuItem *del = [[NSMenuItem alloc] initWithTitle:delTitle action:@selector(deletePlaylistPrompt:) keyEquivalent:@""];
    del.target = self;
    del.image = SPSFSymbolImage(@"trash", 12.0, NSFontWeightRegular, nil);
    [menu addItem:del];

    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0.0, anchor.bounds.size.height + 4.0) inView:anchor];
}

- (void)copyPlaylistLink:(id)sender {
    (void)sender;
    if (!_playlistID.length) return;
    NSString *url = [NSString stringWithFormat:@"https://open.spotify.com/playlist/%@", _playlistID];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
}

- (void)renamePlaylistPrompt:(id)sender {
    (void)sender;
    SPPlaylist *pl = [_store playlistWithID:_playlistID];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Edit Playlist Details";
    alert.informativeText = @"Enter a new name for this playlist:";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.stringValue = pl.name ?: @"";
    alert.accessoryView = field;
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *trimmed = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length) [_navigator renamePlaylistID:_playlistID toName:trimmed];
    }
}

- (void)deletePlaylistPrompt:(id)sender {
    (void)sender;
    SPPlaylist *pl = [_store playlistWithID:_playlistID];
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"Delete \"%@\"?", pl.name ?: @"Playlist"];
    alert.informativeText = @"This removes the playlist from your library.";
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [_navigator deletePlaylistID:_playlistID];
    }
}

- (void)removeTrackFromPlaylist:(NSMenuItem *)sender {
    NSDictionary *info = (NSDictionary *)sender.representedObject;
    NSString *tid = info[@"trackID"];
    NSString *uid = info[@"uid"];
    if (tid.length) [_navigator removeTrackID:tid uid:uid fromPlaylistID:_playlistID];
}

- (void)reloadData {
    SPPlaylist *pl = [_store playlistWithID:_playlistID];
    _trackList.contextURI = pl.uri;
    NSMutableArray<SPTrack *> *tracks = [NSMutableArray arrayWithCapacity:pl.items.count];
    int64_t totalMs = 0;
    for (SPPlaylistItem *item in pl.items) {
        SPTrack *t = [_store trackWithID:item.trackID];
        if (t) {
            [tracks addObject:t];
            totalMs += MAX(0, t.durationMs);
        }
    }
    _trackList.tracks = tracks;

    BOOL owner = [self isOwnerOfPlaylist:pl];
    BOOL followed = [self isFollowedPlaylist];
    _headerView.kindText = (owner || !followed) ? @"Playlist" : @"Playlist · Following";
    _headerView.titleText = pl.name.length ? pl.name : @"Playlist";
    _headerView.descriptionText = pl.playlistDescription;
    _headerView.artworkURL = pl.artworkURL.length ? pl.artworkURL : pl.artworkSmallURL;
    _headerView.showLibraryButton = !owner;
    _headerView.libraryButtonOn = followed;

    NSInteger cnt = tracks.count > 0 ? (NSInteger)tracks.count : pl.totalTrackCount;
    NSString *countStr = (cnt == 1) ? @"1 song" : [NSString stringWithFormat:@"%ld songs", (long)cnt];
    NSString *durStr = SPFormatTotalDurationMs(totalMs);
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if (pl.ownerName.length) [parts addObject:[NSString stringWithFormat:@"By %@", pl.ownerName]];
    [parts addObject:countStr];
    if (durStr.length) [parts addObject:durStr];
    _headerView.metadataText = [parts componentsJoinedByString:@" · "];
    _headerView.playEnabled = (tracks.count > 0 || pl.uri.length > 0);
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    SPPlaylist *pl = [_store playlistWithID:_playlistID];
    CGFloat headerH = [SPDetailHeaderView preferredHeightForWidth:w hasDescription:(pl.playlistDescription.length > 0)];
    _headerView.frame = NSMakeRect(0.0, 0.0, w, headerH);
    _trackList.frame = NSMakeRect(0.0, headerH, w, MAX(0.0, h - headerH));
}

- (void)storeChanged:(SPChange *)change {
    BOOL relevantTrack = NO;
    if (change.tracks.count > 0) {
        SPPlaylist *pl = [_store playlistWithID:_playlistID];
        for (SPPlaylistItem *item in pl.items) {
            if ([change.tracks containsObject:item.trackID]) { relevantTrack = YES; break; }
        }
    }
    if ([change.playlists containsObject:_playlistID] || change.libraryLists || relevantTrack) {
        [self reloadData];
    } else {
        [_trackList applyStoreChange:change];
    }
}

@end

#pragma mark - SPProfileView (1:1 Spotifly UserProfileView)

@interface SPProfileDocView : NSView
@property (nonatomic, strong, nullable) SPUserProfile *profile;
@property (nonatomic, copy, nullable) void (^onCopyID)(void);
@property (nonatomic, copy, nullable) void (^onOpenWeb)(void);
@property (nonatomic, copy, nullable) void (^onOpenSettings)(void);
@property (nonatomic, copy, nullable) void (^onLogOut)(void);
@end

@implementation SPProfileDocView {
    SPButton *_copyBtn;
    SPButton *_openWebBtn;
    SPButton *_settingsBtn;
    SPButton *_logoutBtn;
    NSString *_lastAvatarURL;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    __weak typeof(self) weakSelf = self;

    _copyBtn = [SPButton iconButton:SPIconCopy size:13.0 frame:NSZeroRect];
    _copyBtn.toolTip = @"Copy";
    _copyBtn.onClick = ^{ if (weakSelf.onCopyID) weakSelf.onCopyID(); };
    [self addSubview:_copyBtn];

    _openWebBtn = [SPButton pillButtonWithTitle:@"Open in Spotify" style:SPButtonStyleSecondary frame:NSZeroRect];
    _openWebBtn.icon = SPIconArrowUpRight;
    _openWebBtn.iconSize = 11.5;
    _openWebBtn.onClick = ^{ if (weakSelf.onOpenWeb) weakSelf.onOpenWeb(); };
    [self addSubview:_openWebBtn];

    _settingsBtn = [SPButton pillButtonWithTitle:@"Settings…" style:SPButtonStyleSecondary frame:NSZeroRect];
    _settingsBtn.onClick = ^{ if (weakSelf.onOpenSettings) weakSelf.onOpenSettings(); };
    [self addSubview:_settingsBtn];

    _logoutBtn = [SPButton pillButtonWithTitle:@"Log Out…" style:SPButtonStyleDestructive frame:NSZeroRect];
    _logoutBtn.onClick = ^{ if (weakSelf.onLogOut) weakSelf.onLogOut(); };
    [self addSubview:_logoutBtn];
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
    _copyBtn.hidden = (profile.username.length == 0);
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (CGFloat)cardWidth {
    return MIN(560.0, MAX(280.0, self.bounds.size.width - 56.0));
}

- (CGFloat)cardX {
    return floor((self.bounds.size.width - [self cardWidth]) * 0.5);
}

- (void)layout {
    [super layout];
    CGFloat cx = [self cardX];
    CGFloat cw = [self cardWidth];

    CGFloat y = 176.0;
    if (_profile) {
        // Account card: Display Name (y+24..y+64), User ID (y+64..y+104)
        _copyBtn.frame = NSMakeRect(cx + cw - 34.0, y + 73.0, 22.0, 22.0);
        y += 126.0;
    }
    // Second card: Manage Account (y..y+42), App Settings (y+42..y+84)
    _openWebBtn.frame = NSMakeRect(cx + cw - 146.0, y + 7.0, 132.0, 28.0);
    _settingsBtn.frame = NSMakeRect(cx + cw - 102.0, y + 49.0, 88.0, 28.0);

    CGFloat logoutY = y + 124.0;
    _logoutBtn.frame = NSMakeRect(floor((self.bounds.size.width - 120.0) * 0.5), logoutY, 120.0, 32.0);
}

- (void)drawGroupedCardInContext:(CGContextRef)ctx rect:(CGRect)rect {
    CGPathRef p = CGPathCreateWithRoundedRect(rect, 10.0, 10.0, NULL);
    CGContextSetFillColorWithColor(ctx, SPCardSurfaceColor().CGColor);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGContextSetStrokeColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextAddPath(ctx, p);
    CGContextStrokePath(ctx);
    CGPathRelease(p);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat w = self.bounds.size.width;
    CGFloat cx = [self cardX];
    CGFloat cw = [self cardWidth];

    // Centered 96pt circular avatar + display name
    CGRect avatarRect = CGRectMake(floor((w - 96.0) * 0.5), 24.0, 96.0, 96.0);
    CGImageRef avatarImg = NULL;
    if (_lastAvatarURL.length) {
        NSURL *u = [NSURL URLWithString:_lastAvatarURL];
        if (u) {
            CGFloat scale = self.window.backingScaleFactor ?: 2.0;
            avatarImg = [self.imageHolder imageWithURL:u pixels:ceil(96.0 * scale)];
        }
    }
    SPDrawProfileAvatar(ctx, avatarImg, _profile.displayName, avatarRect);

    NSString *heading = _profile.displayName.length ? _profile.displayName : @"Account details unavailable";
    [heading drawInRect:NSMakeRect(28.0, 130.0, w - 56.0, 28.0)
         withAttributes:SPSemanticTextAttributes(typo->title1, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];

    CGFloat y = 176.0;
    if (_profile) {
        SPTextStyle secStyle = {12.0, NSFontWeightSemibold, 16.0, 0.0, NO};
        [@"Account" drawInRect:NSMakeRect(cx + 12.0, y, 200.0, 16.0)
                withAttributes:SPSemanticTextAttributes(secStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
        CGRect card1 = CGRectMake(cx, y + 22.0, cw, 84.0);
        [self drawGroupedCardInContext:ctx rect:card1];

        NSDictionary *lblAttrs = SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft);
        NSDictionary *valAttrs = SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentRight);

        [@"Display Name" drawInRect:NSMakeRect(cx + 14.0, card1.origin.y + 12.0, 160.0, 18.0) withAttributes:lblAttrs];
        [_profile.displayName drawInRect:NSMakeRect(cx + 170.0, card1.origin.y + 12.0, cw - 184.0, 18.0) withAttributes:valAttrs];

        CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
        CGContextFillRect(ctx, CGRectMake(cx + 14.0, card1.origin.y + 42.0, cw - 28.0, 1.0));

        [@"User ID" drawInRect:NSMakeRect(cx + 14.0, card1.origin.y + 54.0, 140.0, 18.0) withAttributes:lblAttrs];
        NSDictionary *monoAttrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: SPSecondaryLabelColor(),
            NSParagraphStyleAttributeName: ({
                NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
                p.alignment = NSTextAlignmentRight;
                p.lineBreakMode = NSLineBreakByTruncatingMiddle;
                p;
            }),
        };
        [_profile.username drawInRect:NSMakeRect(cx + 150.0, card1.origin.y + 55.0, cw - 190.0, 18.0) withAttributes:monoAttrs];

        y += 126.0;
    }

    // Second card: Manage Account & App Settings
    CGRect card2 = CGRectMake(cx, y, cw, 84.0);
    [self drawGroupedCardInContext:ctx rect:card2];
    NSDictionary *lblAttrs = SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft);
    [@"Manage Account" drawInRect:NSMakeRect(cx + 14.0, card2.origin.y + 12.0, 180.0, 18.0) withAttributes:lblAttrs];
    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(cx + 14.0, card2.origin.y + 42.0, cw - 28.0, 1.0));
    [@"App Settings" drawInRect:NSMakeRect(cx + 14.0, card2.origin.y + 54.0, 180.0, 18.0) withAttributes:lblAttrs];

    [@"Manage your subscription, payment details and privacy in your Spotify account."
        drawInRect:NSMakeRect(cx + 12.0, CGRectGetMaxY(card2) + 8.0, cw - 24.0, 28.0)
    withAttributes:SPSemanticTextAttributes(typo->caption, SPSecondaryLabelColor(), NSLineBreakByWordWrapping, NSTextAlignmentLeft)];
}

@end

@implementation SPProfileView {
    SPStore *_store;
    NSScrollView *_scroll;
    SPProfileDocView *_doc;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;

    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;

    _doc = [[SPProfileDocView alloc] initWithFrame:self.bounds];
    _doc.profile = _store.userProfile;
    __weak typeof(self) weakSelf = self;
    _doc.onCopyID = ^{
        SPProfileView *s = weakSelf;
        if (!s || !s->_store.userProfile.username.length) return;
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:s->_store.userProfile.username forType:NSPasteboardTypeString];
    };
    _doc.onOpenWeb = ^{
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://www.spotify.com/account/overview/"]];
    };
    _doc.onOpenSettings = ^{
        [weakSelf.navigator openPreferences];
    };
    _doc.onLogOut = ^{
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Log out of Spotify?";
        alert.informativeText = @"You can log in again at any time.";
        [alert addButtonWithTitle:@"Log Out"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [weakSelf.navigator signOut];
        }
    };
    _scroll.documentView = _doc;
    [self addSubview:_scroll];

    [_store addObserver:self];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    CGFloat w = MAX(320.0, self.bounds.size.width);
    CGFloat h = MAX(self.bounds.size.height, 480.0 + SPThemeMetrics()->nowPlayingContentClearance);
    _doc.frame = NSMakeRect(0.0, 0.0, w, h);
}

- (void)storeChanged:(SPChange *)change {
    if (change.profile) {
        _doc.profile = _store.userProfile;
    }
}

@end

#pragma mark - SPEmptyDetailView

@implementation SPEmptyDetailView

- (instancetype)initWithFrame:(NSRect)frame message:(NSString *)message symbolName:(NSString *)symbolName {
    if (!(self = [super initWithFrame:frame])) return nil;
    _message = [message copy] ?: @"Select an item";
    _symbolName = [symbolName copy];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat cx = floor(self.bounds.size.width * 0.5);
    CGFloat cy = floor(self.bounds.size.height * 0.5) - 24.0;
    if (_symbolName.length) {
        SPDrawSFSymbol(_symbolName, CGRectMake(cx - 24.0, cy - 36.0, 48.0, 48.0), 34.0, NSFontWeightRegular, SPTertiaryLabelColor());
        cy += 22.0;
    }
    [_message drawInRect:NSMakeRect(20.0, cy, MAX(40.0, self.bounds.size.width - 40.0), 22.0)
          withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];
}

@end
