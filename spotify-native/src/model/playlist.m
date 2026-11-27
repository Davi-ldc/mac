// Immutable Spotify playlist & playlist item models and Pathfinder decoders.
#import "model/playlist.h"
#import "model/json.h"

NSString *const SPLikedSongsPlaylistURI = @"spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ";
NSString *const SPLikedSongsCollectionURI = @"spotify:collection:tracks";

@implementation SPPlaylistItem

- (instancetype)initWithTrackID:(NSString *)trackID uid:(NSString *)uid addedAt:(double)addedAt {
    if (!(self = [super init])) return nil;
    _trackID = [trackID copy];
    _uid = [uid copy];
    _addedAt = addedAt;
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPPlaylistItem.class]) return NO;
    SPPlaylistItem *other = (SPPlaylistItem *)object;
    return [_trackID isEqualToString:other->_trackID] && [_uid isEqualToString:other->_uid];
}

- (NSUInteger)hash { return _trackID.hash ^ (_uid.hash * 31u); }

@end

@implementation SPPlaylist

- (instancetype)initWithPlaylistID:(NSString *)playlistID
                               uri:(NSString *)uri
                              name:(NSString *)name
               playlistDescription:(NSString *)playlistDescription
                           ownerID:(NSString *)ownerID
                         ownerName:(NSString *)ownerName
                        artworkURL:(NSString *)artworkURL
                   artworkSmallURL:(NSString *)artworkSmallURL
                          isPublic:(BOOL)isPublic
                             items:(NSArray<SPPlaylistItem *> *)items
                   totalTrackCount:(NSInteger)totalTrackCount
                     detailsLoaded:(BOOL)detailsLoaded {
    if (!(self = [super init])) return nil;
    _playlistID = [playlistID copy];
    _uri = [uri copy];
    _name = [name copy];
    _playlistDescription = [playlistDescription copy];
    _ownerID = [ownerID copy];
    _ownerName = [ownerName copy];
    _artworkURL = [artworkURL copy];
    _artworkSmallURL = [artworkSmallURL copy];
    _isPublic = isPublic;
    _items = [items copy];
    _totalTrackCount = totalTrackCount;
    _detailsLoaded = detailsLoaded;
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPPlaylist.class]) return NO;
    return [_playlistID isEqualToString:((SPPlaylist *)object)->_playlistID];
}

- (NSUInteger)hash { return _playlistID.hash; }

static void ExtractOwner(NSDictionary *ownerV2, NSString **outID, NSString **outName) {
    NSDictionary *data = SPJSONDict(ownerV2[@"data"]);
    NSString *username = SPJSONString(data[@"username"]);
    NSString *uri = SPJSONString(data[@"uri"]);
    NSString *name = SPJSONString(data[@"name"]);
    *outID = username ?: SPURIIDFromURIOfKind(uri, @"user") ?: @"";
    *outName = name ?: username ?: @"";
}

static void ExtractPlaylistImage(NSDictionary *imagesDict, NSString **outLarge, NSString **outSmall) {
    NSArray *items = SPJSONArray(imagesDict[@"items"]);
    NSDictionary *first = SPJSONDict(items.firstObject);
    SPExtractPathfinderImages(first, outLarge, outSmall);
}

+ (instancetype)playlistFromPathfinderDict:(NSDictionary *)dict {
    if (!dict) return nil;
    NSString *uri = SPJSONString(dict[@"uri"]);
    // Strict kind check drops playlist folders (`spotify:user:<u>:folder:<h>`).
    NSString *playlistID = SPURIIDFromURIOfKind(uri, @"playlist");
    if (!playlistID.length) return nil;

    NSString *ownerID = nil, *ownerName = nil;
    ExtractOwner(SPJSONDict(dict[@"ownerV2"]), &ownerID, &ownerName);
    NSString *artLarge = nil, *artSmall = nil;
    ExtractPlaylistImage(SPJSONDict(dict[@"images"]), &artLarge, &artSmall);

    return [[self alloc] initWithPlaylistID:playlistID
                                        uri:uri
                                       name:SPJSONString(dict[@"name"]) ?: @""
                        playlistDescription:SPNormalizePlaylistDescription(SPJSONString(dict[@"description"]))
                                    ownerID:ownerID
                                  ownerName:ownerName
                                 artworkURL:artLarge
                            artworkSmallURL:artSmall
                                   isPublic:YES
                                      items:@[]
                            totalTrackCount:0
                              detailsLoaded:NO];
}

+ (NSArray<SPTrack *> *)tracksFromPathfinderContentsUnion:(NSDictionary *)unionDict
                                                 itemsOut:(NSArray<SPPlaylistItem *> **)itemsOut
                                                 totalOut:(NSInteger *)totalOut
                                              rawCountOut:(NSInteger *)rawCountOut {
    NSDictionary *content = SPJSONDict(unionDict[@"content"]);
    NSArray *rawItems = SPJSONArray(content[@"items"]);
    if (totalOut) *totalOut = SPJSONInt(content[@"totalCount"], (NSInteger)rawItems.count);
    if (rawCountOut) *rawCountOut = (NSInteger)rawItems.count;

    NSMutableArray<SPTrack *> *tracks = [NSMutableArray arrayWithCapacity:rawItems.count];
    NSMutableArray<SPPlaylistItem *> *items = [NSMutableArray arrayWithCapacity:rawItems.count];
    for (id raw in rawItems) {
        NSDictionary *entry = SPJSONDict(raw);
        if (!entry) continue;
        NSDictionary *itemV2 = SPJSONDict(entry[@"itemV2"]);
        SPTrack *track = [SPTrack trackFromPathfinderPlaylistTrack:SPJSONDict(itemV2[@"data"])];
        if (!track) continue;
        NSString *uid = SPJSONString(entry[@"uid"]) ?: @"";
        double addedAt = SPParseISO8601Timestamp(SPJSONString(SPJSONDict(entry[@"addedAt"])[@"isoString"]));
        [tracks addObject:track];
        [items addObject:[[SPPlaylistItem alloc] initWithTrackID:track.trackID uid:uid addedAt:addedAt]];
    }
    if (itemsOut) *itemsOut = [items copy];
    return [tracks copy];
}

+ (instancetype)playlistFromPathfinderUnion:(NSDictionary *)unionDict
                                  tracksOut:(NSArray<SPTrack *> **)tracksOut
                                   errorOut:(NSError **)errorOut {
    if (!unionDict) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"SPModel" code:404 userInfo:@{NSLocalizedDescriptionKey : @"Empty playlistV2"}];
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
    NSString *playlistID = SPURIIDFromURIOfKind(uri, @"playlist");
    if (!playlistID.length) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"SPModel" code:404 userInfo:@{NSLocalizedDescriptionKey : @"Playlist missing uri/id"}];
        return nil;
    }

    NSString *ownerID = nil, *ownerName = nil;
    ExtractOwner(SPJSONDict(unionDict[@"ownerV2"]), &ownerID, &ownerName);
    NSString *artLarge = nil, *artSmall = nil;
    ExtractPlaylistImage(SPJSONDict(unionDict[@"images"]), &artLarge, &artSmall);

    NSArray<SPPlaylistItem *> *items = nil;
    NSInteger totalCount = 0;
    NSArray<SPTrack *> *tracks = [self tracksFromPathfinderContentsUnion:unionDict
                                                                itemsOut:&items
                                                                totalOut:&totalCount
                                                             rawCountOut:NULL];
    if (tracksOut) *tracksOut = tracks;

    return [[self alloc] initWithPlaylistID:playlistID
                                        uri:uri
                                       name:SPJSONString(unionDict[@"name"]) ?: @""
                        playlistDescription:SPNormalizePlaylistDescription(SPJSONString(unionDict[@"description"]))
                                    ownerID:ownerID
                                  ownerName:ownerName
                                 artworkURL:artLarge
                            artworkSmallURL:artSmall
                                   isPublic:YES
                                      items:items ?: @[]
                            totalTrackCount:totalCount
                              detailsLoaded:YES];
}

@end
