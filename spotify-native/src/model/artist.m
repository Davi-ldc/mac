// Immutable Spotify artist model and Pathfinder decoders.
#import "model/artist.h"
#import "model/json.h"

@implementation SPArtist

- (instancetype)initWithArtistID:(NSString *)artistID
                             uri:(NSString *)uri
                            name:(NSString *)name
                      artworkURL:(NSString *)artworkURL
                 artworkSmallURL:(NSString *)artworkSmallURL
                        albumIDs:(NSArray<NSString *> *)albumIDs
                     topTrackIDs:(NSArray<NSString *> *)topTrackIDs
                   detailsLoaded:(BOOL)detailsLoaded {
    if (!(self = [super init])) return nil;
    _artistID = [artistID copy];
    _uri = [uri copy];
    _name = [name copy];
    _artworkURL = [artworkURL copy];
    _artworkSmallURL = [artworkSmallURL copy];
    _albumIDs = [albumIDs copy] ?: @[];
    _topTrackIDs = [topTrackIDs copy] ?: @[];
    _detailsLoaded = detailsLoaded;
    return self;
}

- (instancetype)initWithArtistID:(NSString *)artistID
                             uri:(NSString *)uri
                            name:(NSString *)name
                      artworkURL:(NSString *)artworkURL
                 artworkSmallURL:(NSString *)artworkSmallURL
                        albumIDs:(NSArray<NSString *> *)albumIDs
                   detailsLoaded:(BOOL)detailsLoaded {
    return [self initWithArtistID:artistID
                              uri:uri
                             name:name
                       artworkURL:artworkURL
                  artworkSmallURL:artworkSmallURL
                         albumIDs:albumIDs
                      topTrackIDs:@[]
                    detailsLoaded:detailsLoaded];
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPArtist.class]) return NO;
    return [_artistID isEqualToString:((SPArtist *)object)->_artistID];
}

- (NSUInteger)hash { return _artistID.hash; }

+ (instancetype)artistFromPathfinderDict:(NSDictionary *)dict {
    if (!dict) return nil;
    NSString *uri = SPJSONString(dict[@"uri"]);
    NSString *artistID = SPJSONString(dict[@"id"]) ?: SPURIIDFromURIOfKind(uri, @"artist") ?: SPURIIDFromURI(uri);
    if (!artistID.length) return nil;
    if (!uri.length) uri = [NSString stringWithFormat:@"spotify:artist:%@", artistID];

    NSString *name = SPJSONString(SPJSONDict(dict[@"profile"])[@"name"]) ?: @"";
    NSString *artLarge = nil, *artSmall = nil;
    SPExtractPathfinderImages(SPJSONDict(SPJSONDict(dict[@"visuals"])[@"avatarImage"]), &artLarge, &artSmall);

    return [[self alloc] initWithArtistID:artistID
                                      uri:uri
                                     name:name
                               artworkURL:artLarge
                          artworkSmallURL:artSmall
                                 albumIDs:@[]
                            detailsLoaded:NO];
}

static void CollectReleaseGroup(NSDictionary *group,
                                NSString *artistID,
                                NSString *artistName,
                                NSMutableSet<NSString *> *seen,
                                NSMutableArray<SPAlbum *> *albums,
                                NSMutableArray<NSString *> *albumIDs) {
    NSArray *items = SPJSONArray(group[@"items"]);
    for (id raw in items) {
        NSDictionary *entry = SPJSONDict(raw);
        if (!entry) continue;
        // Accepts both `items[].releases.items[]` (release group) and direct `items[]` (popularReleasesAlbums).
        NSArray *nested = SPJSONArray(SPJSONDict(entry[@"releases"])[@"items"]);
        NSArray *candidates = nested ?: @[ entry ];
        for (id relRaw in candidates) {
            SPAlbum *album = [SPAlbum albumFromPathfinderRelease:SPJSONDict(relRaw) artistID:artistID artistName:artistName];
            if (!album || [seen containsObject:album.albumID]) continue;
            [seen addObject:album.albumID];
            [albums addObject:album];
            [albumIDs addObject:album.albumID];
        }
    }
}

+ (instancetype)artistFromPathfinderUnion:(NSDictionary *)unionDict
                                albumsOut:(NSArray<SPAlbum *> **)albumsOut
                                 errorOut:(NSError **)errorOut {
    return [self artistFromPathfinderUnion:unionDict albumsOut:albumsOut topTracksOut:NULL errorOut:errorOut];
}

+ (instancetype)artistFromPathfinderUnion:(NSDictionary *)unionDict
                                albumsOut:(NSArray<SPAlbum *> **)albumsOut
                             topTracksOut:(NSArray<SPTrack *> **)topTracksOut
                                 errorOut:(NSError **)errorOut {
    if (!unionDict) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"SPModel" code:404 userInfo:@{NSLocalizedDescriptionKey : @"Empty artistUnion"}];
        return nil;
    }
    NSString *typename = SPJSONString(unionDict[@"__typename"]);
    if ([typename isEqualToString:@"NotFound"] || [typename isEqualToString:@"GenericError"]) {
        NSInteger code = [typename isEqualToString:@"NotFound"] ? 404 : 500;
        NSString *msg = SPJSONString(unionDict[@"message"]) ?: typename;
        if (errorOut) *errorOut = [NSError errorWithDomain:@"SPModel" code:code userInfo:@{NSLocalizedDescriptionKey : msg}];
        return nil;
    }

    NSString *uri = SPJSONString(unionDict[@"uri"]);
    NSString *artistID = SPJSONString(unionDict[@"id"]) ?: SPURIIDFromURIOfKind(uri, @"artist") ?: SPURIIDFromURI(uri);
    if (!artistID.length) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"SPModel" code:404 userInfo:@{NSLocalizedDescriptionKey : @"Artist missing uri/id"}];
        return nil;
    }
    if (!uri.length) uri = [NSString stringWithFormat:@"spotify:artist:%@", artistID];

    NSString *name = SPJSONString(SPJSONDict(unionDict[@"profile"])[@"name"]) ?: @"";
    NSString *artLarge = nil, *artSmall = nil;
    SPExtractPathfinderImages(SPJSONDict(SPJSONDict(unionDict[@"visuals"])[@"avatarImage"]), &artLarge, &artSmall);

    NSDictionary *discog = SPJSONDict(unionDict[@"discography"]);
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    NSMutableArray<SPAlbum *> *albums = [NSMutableArray new];
    NSMutableArray<NSString *> *albumIDs = [NSMutableArray new];
    for (NSString *key in @[ @"all", @"albums", @"singles", @"compilations", @"popularReleasesAlbums" ]) {
        CollectReleaseGroup(SPJSONDict(discog[key]), artistID, name, seen, albums, albumIDs);
    }
    if (albumsOut) *albumsOut = [albums copy];

    NSMutableSet<NSString *> *seenTracks = [NSMutableSet new];
    NSMutableArray<SPTrack *> *topTracks = [NSMutableArray new];
    NSMutableArray<NSString *> *topTrackIDs = [NSMutableArray new];
    NSArray *rawTop = SPJSONArray(SPJSONDict(discog[@"topTracks"])[@"items"]);
    for (id raw in rawTop) {
        NSDictionary *entry = SPJSONDict(raw);
        if (!entry) continue;
        NSDictionary *tDict = SPJSONDict(entry[@"track"]) ?: entry;
        SPTrack *track = [SPTrack trackFromPathfinderDict:tDict];
        if (!track || [seenTracks containsObject:track.trackID]) continue;
        [seenTracks addObject:track.trackID];
        [topTracks addObject:track];
        [topTrackIDs addObject:track.trackID];
    }
    if (topTracksOut) *topTracksOut = [topTracks copy];

    return [[self alloc] initWithArtistID:artistID
                                      uri:uri
                                     name:name
                               artworkURL:artLarge
                          artworkSmallURL:artSmall
                                 albumIDs:albumIDs
                              topTrackIDs:topTrackIDs
                            detailsLoaded:YES];
}

@end
