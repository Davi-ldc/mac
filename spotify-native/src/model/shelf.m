// Immutable Home shelf, Home page, and User Profile models with Pathfinder decoders.
#import "model/shelf.h"
#import "model/json.h"

@implementation SPShelfItem

- (instancetype)initWithKind:(SPShelfItemKind)kind
                    entityID:(NSString *)entityID
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle
                  artworkURL:(NSString *)artworkURL {
    if (!(self = [super init])) return nil;
    _kind = kind;
    _entityID = [entityID copy];
    _title = [title copy];
    _subtitle = [subtitle copy];
    _artworkURL = [artworkURL copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPShelfItem.class]) return NO;
    SPShelfItem *other = (SPShelfItem *)object;
    return _kind == other->_kind && [_entityID isEqualToString:other->_entityID];
}

- (NSUInteger)hash { return _entityID.hash ^ ((NSUInteger)_kind * 31u); }

@end

@implementation SPHomeShelf

- (instancetype)initWithShelfID:(NSString *)shelfID
                          title:(NSString *)title
               isRecentlyPlayed:(BOOL)isRecentlyPlayed
                          items:(NSArray<SPShelfItem *> *)items {
    if (!(self = [super init])) return nil;
    _shelfID = [shelfID copy];
    _title = [title copy];
    _isRecentlyPlayed = isRecentlyPlayed;
    _items = [items copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end

@implementation SPHomePage

- (instancetype)initWithShelves:(NSArray<SPHomeShelf *> *)shelves
                         albums:(NSArray<SPAlbum *> *)albums
                        artists:(NSArray<SPArtist *> *)artists
                      playlists:(NSArray<SPPlaylist *> *)playlists {
    if (!(self = [super init])) return nil;
    _shelves = [shelves copy];
    _albums = [albums copy];
    _artists = [artists copy];
    _playlists = [playlists copy];
    return self;
}

static void ResolveHomeTraitEntity(NSDictionary *entity,
                                   NSMutableArray<SPShelfItem *> *shelfItems,
                                   NSMutableSet<SPShelfItem *> *seen,
                                   NSMutableArray<SPAlbum *> *albums,
                                   NSMutableArray<SPArtist *> *artists,
                                   NSMutableArray<SPPlaylist *> *playlists) {
    NSString *uri = SPJSONString(entity[@"uri"]);
    if (!uri.length) return;

    NSDictionary *idTrait = SPJSONDict(entity[@"identityTrait"]);
    NSString *name = SPJSONString(idTrait[@"name"]) ?: @"";
    NSArray *contribs = SPJSONArray(SPJSONDict(idTrait[@"contributors"])[@"items"]);
    NSDictionary *firstContrib = SPJSONDict(contribs.firstObject);
    NSString *contribName = SPJSONString(firstContrib[@"name"]);
    NSString *contribURI = SPJSONString(firstContrib[@"uri"]);

    NSDictionary *imgPayload = SPJSONDict(
        SPJSONDict(
            SPJSONDict(
                SPJSONDict(entity[@"visualIdentityTrait"])[@"squareCoverImage"])[@"image"])[@"data"]);
    NSString *artLarge = nil, *artSmall = nil;
    SPExtractPathfinderImages(imgPayload, &artLarge, &artSmall);

    // The URI kind decides, never `entityTypeTrait`: Liked Songs arrives as ENTITY_TYPE_PLAYLIST
    // with `spotify:collection:tracks` and must be dropped here.
    NSString *albumID = SPURIIDFromURIOfKind(uri, @"album");
    if (albumID.length) {
        SPAlbum *album = [[SPAlbum alloc] initWithAlbumID:albumID
                                                      uri:uri
                                                     name:name
                                                albumType:nil
                                                 artistID:SPURIIDFromURIOfKind(contribURI, @"artist")
                                               artistName:contribName ?: @"Unknown"
                                              artistNames:contribName ? @[ contribName ] : @[]
                                              releaseDate:nil
                                               artworkURL:artLarge
                                          artworkSmallURL:artSmall
                                                 trackIDs:@[]
                                          totalTrackCount:0
                                          totalDurationMs:0
                                            detailsLoaded:NO];
        SPShelfItem *item = [[SPShelfItem alloc] initWithKind:SPShelfItemAlbum
                                                     entityID:albumID
                                                        title:name
                                                     subtitle:contribName
                                                   artworkURL:artLarge];
        if (![seen containsObject:item]) {
            [seen addObject:item];
            [shelfItems addObject:item];
            [albums addObject:album];
        }
        return;
    }

    NSString *playlistID = SPURIIDFromURIOfKind(uri, @"playlist");
    if (playlistID.length) {
        SPPlaylist *pl = [[SPPlaylist alloc] initWithPlaylistID:playlistID
                                                            uri:uri
                                                           name:name
                                            playlistDescription:nil
                                                        ownerID:SPURIIDFromURIOfKind(contribURI, @"user") ?: @""
                                                      ownerName:contribName ?: @""
                                                     artworkURL:artLarge
                                                artworkSmallURL:artSmall
                                                       isPublic:YES
                                                          items:@[]
                                                totalTrackCount:0
                                                  detailsLoaded:NO];
        SPShelfItem *item = [[SPShelfItem alloc] initWithKind:SPShelfItemPlaylist
                                                     entityID:playlistID
                                                        title:name
                                                     subtitle:contribName
                                                   artworkURL:artLarge];
        if (![seen containsObject:item]) {
            [seen addObject:item];
            [shelfItems addObject:item];
            [playlists addObject:pl];
        }
        return;
    }

    NSString *artistID = SPURIIDFromURIOfKind(uri, @"artist");
    if (artistID.length) {
        SPArtist *artist = [[SPArtist alloc] initWithArtistID:artistID
                                                          uri:uri
                                                         name:name
                                                   artworkURL:artLarge
                                              artworkSmallURL:artSmall
                                                     albumIDs:@[]
                                                detailsLoaded:NO];
        SPShelfItem *item = [[SPShelfItem alloc] initWithKind:SPShelfItemArtist
                                                     entityID:artistID
                                                        title:name
                                                     subtitle:nil
                                                   artworkURL:artLarge];
        if (![seen containsObject:item]) {
            [seen addObject:item];
            [shelfItems addObject:item];
            [artists addObject:artist];
        }
    }
}

+ (instancetype)homePageFromPathfinderJSON:(NSDictionary *)root errorOut:(NSError **)errorOut {
    NSDictionary *home = SPJSONDict(SPJSONDict(root[@"data"])[@"home"]);
    NSString *typename = SPJSONString(home[@"__typename"]);
    if (![typename isEqualToString:@"HomeResponsePayload"]) {
        if (errorOut) {
            NSString *msg = typename.length ? [NSString stringWithFormat:@"Home union error: %@", typename] : @"Missing home payload";
            *errorOut = [NSError errorWithDomain:@"SPModel" code:500 userInfo:@{NSLocalizedDescriptionKey : msg}];
        }
        return nil;
    }

    NSArray *rawSections = SPJSONArray(SPJSONDict(SPJSONDict(home[@"sectionContainer"])[@"sections"])[@"items"]);
    NSMutableArray<SPHomeShelf *> *shelves = [NSMutableArray new];
    NSMutableArray<SPAlbum *> *albums = [NSMutableArray new];
    NSMutableArray<SPArtist *> *artists = [NSMutableArray new];
    NSMutableArray<SPPlaylist *> *playlists = [NSMutableArray new];

    for (id rawSec in rawSections) {
        NSDictionary *sec = SPJSONDict(rawSec);
        NSString *secURI = SPJSONString(sec[@"uri"]);
        if (!secURI.length) continue;

        NSDictionary *secData = SPJSONDict(sec[@"data"]);
        NSString *secType = SPJSONString(secData[@"__typename"]);
        NSString *title = SPJSONString(SPJSONDict(secData[@"title"])[@"transformedLabel"]);
        BOOL isRecent = [secType isEqualToString:@"HomeRecentlyPlayedSectionData"] ||
                        [secURI isEqualToString:@"spotify:section:0JQ5DAob0KZzPQKc9YbqhR"];

        NSArray *entries = SPJSONArray(SPJSONDict(sec[@"sectionItems"])[@"items"]);
        NSMutableArray<SPShelfItem *> *shelfItems = [NSMutableArray new];
        NSMutableSet<SPShelfItem *> *seen = [NSMutableSet new];

        for (id rawEntry in entries) {
            NSDictionary *content = SPJSONDict(SPJSONDict(rawEntry)[@"content"]);
            NSString *wrapperType = SPJSONString(content[@"__typename"]);
            NSDictionary *data = SPJSONDict(content[@"data"]);
            if (!wrapperType.length || !data) continue;

            if ([wrapperType isEqualToString:@"AlbumResponseWrapper"]) {
                SPAlbum *a = [SPAlbum albumFromPathfinderDict:data];
                if (!a) continue;
                SPShelfItem *item = [[SPShelfItem alloc] initWithKind:SPShelfItemAlbum entityID:a.albumID title:a.name subtitle:a.artistName artworkURL:a.artworkURL];
                if (![seen containsObject:item]) {
                    [seen addObject:item];
                    [shelfItems addObject:item];
                    [albums addObject:a];
                }
            } else if ([wrapperType isEqualToString:@"ArtistResponseWrapper"]) {
                SPArtist *ar = [SPArtist artistFromPathfinderDict:data];
                if (!ar) continue;
                SPShelfItem *item = [[SPShelfItem alloc] initWithKind:SPShelfItemArtist entityID:ar.artistID title:ar.name subtitle:nil artworkURL:ar.artworkURL];
                if (![seen containsObject:item]) {
                    [seen addObject:item];
                    [shelfItems addObject:item];
                    [artists addObject:ar];
                }
            } else if ([wrapperType isEqualToString:@"PlaylistResponseWrapper"]) {
                SPPlaylist *pl = [SPPlaylist playlistFromPathfinderDict:data];
                if (!pl) continue;
                SPShelfItem *item = [[SPShelfItem alloc] initWithKind:SPShelfItemPlaylist entityID:pl.playlistID title:pl.name subtitle:pl.ownerName artworkURL:pl.artworkURL];
                if (![seen containsObject:item]) {
                    [seen addObject:item];
                    [shelfItems addObject:item];
                    [playlists addObject:pl];
                }
            } else if ([wrapperType isEqualToString:@"ListResponseWrapper"]) {
                NSArray *listItems = SPJSONArray(SPJSONDict(data[@"items"])[@"items"]);
                for (id listRaw in listItems) {
                    NSDictionary *entity = SPJSONDict(SPJSONDict(SPJSONDict(listRaw)[@"entity"])[@"data"]);
                    if (entity) ResolveHomeTraitEntity(entity, shelfItems, seen, albums, artists, playlists);
                }
            }
        }

        if (shelfItems.count > 0) {
            [shelves addObject:[[SPHomeShelf alloc] initWithShelfID:secURI title:title isRecentlyPlayed:isRecent items:shelfItems]];
        }
    }

    return [[self alloc] initWithShelves:shelves albums:albums artists:artists playlists:playlists];
}

@end

@implementation SPUserProfile

- (instancetype)initWithUsername:(NSString *)username
                     displayName:(NSString *)displayName
                             uri:(NSString *)uri
                       avatarURL:(NSString *)avatarURL {
    if (!(self = [super init])) return nil;
    _username = [username copy];
    _displayName = [displayName copy];
    _uri = [uri copy];
    _avatarURL = [avatarURL copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

+ (instancetype)profileFromPathfinderJSON:(NSDictionary *)root {
    NSDictionary *profile = SPJSONDict(SPJSONDict(SPJSONDict(root[@"data"])[@"me"])[@"profile"]);
    NSString *username = SPJSONString(profile[@"username"]);
    if (!username.length) return nil;
    NSString *name = SPJSONString(profile[@"name"]) ?: username;
    NSString *uri = SPJSONString(profile[@"uri"]) ?: [NSString stringWithFormat:@"spotify:user:%@", username];
    NSString *avatarLarge = nil;
    SPExtractPathfinderImages(SPJSONDict(profile[@"avatar"]), &avatarLarge, NULL);
    return [[self alloc] initWithUsername:username displayName:name uri:uri avatarURL:avatarLarge];
}

@end
