// Immutable search results & typeahead suggestion models (`searchDesktop` + `searchSuggestions`).
#import "model/search.h"
#import "model/json.h"

@implementation SPSearchSuggestion

- (instancetype)initWithKind:(SPSearchSuggestionKind)kind
                        text:(NSString *)text
                    entityID:(NSString *)entityID
                    subtitle:(NSString *)subtitle
                  artworkURL:(NSString *)artworkURL {
    if (!(self = [super init])) return nil;
    _kind = kind;
    _text = [text copy];
    _entityID = [entityID copy];
    _subtitle = [subtitle copy];
    _artworkURL = [artworkURL copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPSearchSuggestion.class]) return NO;
    SPSearchSuggestion *o = (SPSearchSuggestion *)object;
    if (_kind != o->_kind) return NO;
    if (_entityID && o->_entityID) return [_entityID isEqualToString:o->_entityID];
    return [_text isEqualToString:o->_text];
}

- (NSUInteger)hash { return (_entityID ?: _text).hash ^ ((NSUInteger)_kind * 31u); }

@end

@implementation SPSearchResults

- (instancetype)initWithQuery:(NSString *)query
                      topHits:(NSArray<SPSearchSuggestion *> *)topHits
                       tracks:(NSArray<SPTrack *> *)tracks
                       albums:(NSArray<SPAlbum *> *)albums
                      artists:(NSArray<SPArtist *> *)artists
                    playlists:(NSArray<SPPlaylist *> *)playlists
                  tracksTotal:(NSInteger)tracksTotal
                  albumsTotal:(NSInteger)albumsTotal
                 artistsTotal:(NSInteger)artistsTotal
               playlistsTotal:(NSInteger)playlistsTotal
                  suggestions:(NSArray<SPSearchSuggestion *> *)suggestions
                  isLocalOnly:(BOOL)isLocalOnly {
    if (!(self = [super init])) return nil;
    _query = [query copy];
    _topHits = [topHits copy];
    _tracks = [tracks copy];
    _albums = [albums copy];
    _artists = [artists copy];
    _playlists = [playlists copy];
    _tracksTotal = tracksTotal;
    _albumsTotal = albumsTotal;
    _artistsTotal = artistsTotal;
    _playlistsTotal = playlistsTotal;
    _suggestions = [suggestions copy];
    _isLocalOnly = isLocalOnly;
    return self;
}

/// Unwraps either `entry.data` or `entry.item.data` (Pathfinder varies wrapper shape across operations).
static NSDictionary *UnwrapSearchItemData(NSDictionary *entry) {
    if (!entry) return nil;
    NSDictionary *direct = SPJSONDict(entry[@"data"]);
    if (direct) return direct;
    NSDictionary *item = SPJSONDict(entry[@"item"]);
    return SPJSONDict(item[@"data"]);
}

static NSArray<SPTrack *> *DecodeTracksSection(NSDictionary *sec, NSInteger *totalOut, NSInteger *sentOut) {
    NSArray *items = SPJSONArray(sec[@"items"]);
    if (totalOut) *totalOut = SPJSONInt(sec[@"totalCount"], (NSInteger)items.count);
    if (sentOut) *sentOut = (NSInteger)items.count;
    NSMutableArray<SPTrack *> *out = [NSMutableArray arrayWithCapacity:items.count];
    for (id raw in items) {
        SPTrack *t = [SPTrack trackFromPathfinderDict:UnwrapSearchItemData(SPJSONDict(raw))];
        if (t) [out addObject:t];
    }
    return [out copy];
}

static NSArray<SPAlbum *> *DecodeAlbumsSection(NSDictionary *sec, NSInteger *totalOut, NSInteger *sentOut) {
    NSArray *items = SPJSONArray(sec[@"items"]);
    if (totalOut) *totalOut = SPJSONInt(sec[@"totalCount"], (NSInteger)items.count);
    if (sentOut) *sentOut = (NSInteger)items.count;
    NSMutableArray<SPAlbum *> *out = [NSMutableArray arrayWithCapacity:items.count];
    for (id raw in items) {
        SPAlbum *a = [SPAlbum albumFromPathfinderDict:UnwrapSearchItemData(SPJSONDict(raw))];
        if (a) [out addObject:a];
    }
    return [out copy];
}

static NSArray<SPArtist *> *DecodeArtistsSection(NSDictionary *sec, NSInteger *totalOut, NSInteger *sentOut) {
    NSArray *items = SPJSONArray(sec[@"items"]);
    if (totalOut) *totalOut = SPJSONInt(sec[@"totalCount"], (NSInteger)items.count);
    if (sentOut) *sentOut = (NSInteger)items.count;
    NSMutableArray<SPArtist *> *out = [NSMutableArray arrayWithCapacity:items.count];
    for (id raw in items) {
        SPArtist *ar = [SPArtist artistFromPathfinderDict:UnwrapSearchItemData(SPJSONDict(raw))];
        if (ar) [out addObject:ar];
    }
    return [out copy];
}

static NSArray<SPPlaylist *> *DecodePlaylistsSection(NSDictionary *sec, NSInteger *totalOut, NSInteger *sentOut) {
    NSArray *items = SPJSONArray(sec[@"items"]);
    if (totalOut) *totalOut = SPJSONInt(sec[@"totalCount"], (NSInteger)items.count);
    if (sentOut) *sentOut = (NSInteger)items.count;
    NSMutableArray<SPPlaylist *> *out = [NSMutableArray arrayWithCapacity:items.count];
    for (id raw in items) {
        SPPlaylist *pl = [SPPlaylist playlistFromPathfinderDict:UnwrapSearchItemData(SPJSONDict(raw))];
        if (pl) [out addObject:pl];
    }
    return [out copy];
}

static NSArray<SPSearchSuggestion *> *DecodeTopItemsV2(NSArray *itemsV2) {
    NSMutableArray<SPSearchSuggestion *> *out = [NSMutableArray arrayWithCapacity:itemsV2.count];
    for (id raw in itemsV2) {
        NSDictionary *entry = SPJSONDict(raw);
        NSDictionary *item = SPJSONDict(entry[@"item"]);
        if (!item) continue;
        NSString *typename = SPJSONString(item[@"__typename"]);
        NSDictionary *data = SPJSONDict(item[@"data"]);

        if ([typename isEqualToString:@"SearchAutoCompleteEntity"] ||
            [typename isEqualToString:@"SearchAutocompleteQuery"]) {
            NSString *text = SPJSONString(item[@"text"]) ?: SPJSONString(item[@"query"]) ?: SPJSONString(data[@"text"]) ?: SPJSONString(data[@"query"]);
            if (text.length) {
                [out addObject:[[SPSearchSuggestion alloc] initWithKind:SPSearchSuggestionQuery text:text entityID:nil subtitle:nil artworkURL:nil]];
            }
        } else if ([typename isEqualToString:@"TrackResponseWrapper"]) {
            SPTrack *t = [SPTrack trackFromPathfinderDict:data];
            if (t) {
                [out addObject:[[SPSearchSuggestion alloc] initWithKind:SPSearchSuggestionTrack text:t.name entityID:t.trackID subtitle:t.artistName artworkURL:t.artworkSmallURL]];
            }
        } else if ([typename isEqualToString:@"AlbumResponseWrapper"]) {
            SPAlbum *a = [SPAlbum albumFromPathfinderDict:data];
            if (a) {
                [out addObject:[[SPSearchSuggestion alloc] initWithKind:SPSearchSuggestionAlbum text:a.name entityID:a.albumID subtitle:a.artistName artworkURL:a.artworkSmallURL]];
            }
        } else if ([typename isEqualToString:@"ArtistResponseWrapper"]) {
            SPArtist *ar = [SPArtist artistFromPathfinderDict:data];
            if (ar) {
                [out addObject:[[SPSearchSuggestion alloc] initWithKind:SPSearchSuggestionArtist text:ar.name entityID:ar.artistID subtitle:nil artworkURL:ar.artworkSmallURL]];
            }
        } else if ([typename isEqualToString:@"PlaylistResponseWrapper"]) {
            SPPlaylist *pl = [SPPlaylist playlistFromPathfinderDict:data];
            if (pl) {
                [out addObject:[[SPSearchSuggestion alloc] initWithKind:SPSearchSuggestionPlaylist text:pl.name entityID:pl.playlistID subtitle:pl.ownerName artworkURL:pl.artworkSmallURL]];
            }
        }
    }
    return [out copy];
}

+ (instancetype)resultsFromSearchDesktopJSON:(NSDictionary *)root query:(NSString *)query {
    NSDictionary *s2 = SPJSONDict(SPJSONDict(root[@"data"])[@"searchV2"]);
    NSArray *topItems = SPJSONArray(SPJSONDict(s2[@"topResultsV2"])[@"itemsV2"]);
    NSArray<SPSearchSuggestion *> *topHits = DecodeTopItemsV2(topItems);

    NSInteger tTotal = 0, aTotal = 0, arTotal = 0, plTotal = 0;
    NSArray<SPTrack *> *tracks = DecodeTracksSection(SPJSONDict(s2[@"tracksV2"]), &tTotal, NULL);
    NSArray<SPAlbum *> *albums = DecodeAlbumsSection(SPJSONDict(s2[@"albumsV2"]), &aTotal, NULL);
    NSArray<SPArtist *> *artists = DecodeArtistsSection(SPJSONDict(s2[@"artists"]), &arTotal, NULL);
    NSArray<SPPlaylist *> *playlists = DecodePlaylistsSection(SPJSONDict(s2[@"playlists"]), &plTotal, NULL);

    return [[self alloc] initWithQuery:query ?: @""
                               topHits:topHits
                                tracks:tracks
                                albums:albums
                               artists:artists
                             playlists:playlists
                           tracksTotal:tTotal
                           albumsTotal:aTotal
                          artistsTotal:arTotal
                        playlistsTotal:plTotal
                           suggestions:@[]
                           isLocalOnly:NO];
}

+ (NSArray<SPSearchSuggestion *> *)suggestionsFromSearchSuggestionsJSON:(NSDictionary *)root {
    NSDictionary *s2 = SPJSONDict(SPJSONDict(root[@"data"])[@"searchV2"]);
    NSArray *itemsV2 = SPJSONArray(SPJSONDict(s2[@"topResultsV2"])[@"itemsV2"]);
    return DecodeTopItemsV2(itemsV2);
}

+ (NSArray<SPTrack *> *)tracksPageFromSearchJSON:(NSDictionary *)root totalOut:(NSInteger *)totalOut sentOut:(NSInteger *)sentOut {
    NSDictionary *s2 = SPJSONDict(SPJSONDict(root[@"data"])[@"searchV2"]);
    return DecodeTracksSection(SPJSONDict(s2[@"tracksV2"]), totalOut, sentOut);
}

+ (NSArray<SPAlbum *> *)albumsPageFromSearchJSON:(NSDictionary *)root totalOut:(NSInteger *)totalOut sentOut:(NSInteger *)sentOut {
    NSDictionary *s2 = SPJSONDict(SPJSONDict(root[@"data"])[@"searchV2"]);
    return DecodeAlbumsSection(SPJSONDict(s2[@"albumsV2"]), totalOut, sentOut);
}

+ (NSArray<SPArtist *> *)artistsPageFromSearchJSON:(NSDictionary *)root totalOut:(NSInteger *)totalOut sentOut:(NSInteger *)sentOut {
    NSDictionary *s2 = SPJSONDict(SPJSONDict(root[@"data"])[@"searchV2"]);
    return DecodeArtistsSection(SPJSONDict(s2[@"artists"]), totalOut, sentOut);
}

+ (NSArray<SPPlaylist *> *)playlistsPageFromSearchJSON:(NSDictionary *)root totalOut:(NSInteger *)totalOut sentOut:(NSInteger *)sentOut {
    NSDictionary *s2 = SPJSONDict(SPJSONDict(root[@"data"])[@"searchV2"]);
    return DecodePlaylistsSection(SPJSONDict(s2[@"playlists"]), totalOut, sentOut);
}

+ (instancetype)mergedLocalResults:(SPSearchResults *)local
                     remoteResults:(SPSearchResults *)remote
                       suggestions:(NSArray<SPSearchSuggestion *> *)suggestions {
    NSMutableArray<SPTrack *> *tracks = [NSMutableArray arrayWithArray:local.tracks];
    NSMutableSet<NSString *> *seenTrack = [NSMutableSet new];
    for (SPTrack *t in tracks) [seenTrack addObject:t.trackID];
    for (SPTrack *t in remote.tracks) {
        if (![seenTrack containsObject:t.trackID]) { [seenTrack addObject:t.trackID]; [tracks addObject:t]; }
    }

    NSMutableArray<SPAlbum *> *albums = [NSMutableArray arrayWithArray:local.albums];
    NSMutableSet<NSString *> *seenAlbum = [NSMutableSet new];
    for (SPAlbum *a in albums) [seenAlbum addObject:a.albumID];
    for (SPAlbum *a in remote.albums) {
        if (![seenAlbum containsObject:a.albumID]) { [seenAlbum addObject:a.albumID]; [albums addObject:a]; }
    }

    NSMutableArray<SPArtist *> *artists = [NSMutableArray arrayWithArray:local.artists];
    NSMutableSet<NSString *> *seenArtist = [NSMutableSet new];
    for (SPArtist *ar in artists) [seenArtist addObject:ar.artistID];
    for (SPArtist *ar in remote.artists) {
        if (![seenArtist containsObject:ar.artistID]) { [seenArtist addObject:ar.artistID]; [artists addObject:ar]; }
    }

    NSMutableArray<SPPlaylist *> *playlists = [NSMutableArray arrayWithArray:local.playlists];
    NSMutableSet<NSString *> *seenPl = [NSMutableSet new];
    for (SPPlaylist *pl in playlists) [seenPl addObject:pl.playlistID];
    for (SPPlaylist *pl in remote.playlists) {
        if (![seenPl containsObject:pl.playlistID]) { [seenPl addObject:pl.playlistID]; [playlists addObject:pl]; }
    }

    return [[self alloc] initWithQuery:local.query
                               topHits:remote.topHits ?: @[]
                                tracks:tracks
                                albums:albums
                               artists:artists
                             playlists:playlists
                           tracksTotal:MAX((NSInteger)tracks.count, remote.tracksTotal)
                           albumsTotal:MAX((NSInteger)albums.count, remote.albumsTotal)
                          artistsTotal:MAX((NSInteger)artists.count, remote.artistsTotal)
                        playlistsTotal:MAX((NSInteger)playlists.count, remote.playlistsTotal)
                           suggestions:suggestions ?: remote.suggestions ?: @[]
                           isLocalOnly:(remote == nil)];
}

@end
