// Immutable Spotify album model and Pathfinder decoders.
#import "model/album.h"
#import "model/json.h"

@implementation SPAlbum

- (instancetype)initWithAlbumID:(NSString *)albumID
                            uri:(NSString *)uri
                           name:(NSString *)name
                      albumType:(NSString *)albumType
                       artistID:(NSString *)artistID
                     artistName:(NSString *)artistName
                    artistNames:(NSArray<NSString *> *)artistNames
                    releaseDate:(NSString *)releaseDate
                     artworkURL:(NSString *)artworkURL
                artworkSmallURL:(NSString *)artworkSmallURL
                       trackIDs:(NSArray<NSString *> *)trackIDs
                totalTrackCount:(NSInteger)totalTrackCount
                totalDurationMs:(NSInteger)totalDurationMs
                  detailsLoaded:(BOOL)detailsLoaded {
    if (!(self = [super init])) return nil;
    _albumID = [albumID copy];
    _uri = [uri copy];
    _name = [name copy];
    _albumType = [albumType copy];
    _artistID = [artistID copy];
    _artistName = [artistName copy];
    _artistNames = [artistNames copy];
    _releaseDate = [releaseDate copy];
    _artworkURL = [artworkURL copy];
    _artworkSmallURL = [artworkSmallURL copy];
    _trackIDs = [trackIDs copy];
    _totalTrackCount = totalTrackCount;
    _totalDurationMs = totalDurationMs;
    _detailsLoaded = detailsLoaded;
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPAlbum.class]) return NO;
    return [_albumID isEqualToString:((SPAlbum *)object)->_albumID];
}

- (NSUInteger)hash { return _albumID.hash; }

static void ExtractAlbumArtists(NSDictionary *artistsDict,
                                NSArray<NSString *> **outNames,
                                NSString **outFirstID) {
    NSArray *items = SPJSONArray(artistsDict[@"items"]);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:items.count];
    NSString *firstID = nil;
    for (id raw in items) {
        NSDictionary *item = SPJSONDict(raw);
        if (!item) continue;
        NSString *name = SPJSONString(SPJSONDict(item[@"profile"])[@"name"]);
        if (name.length) [names addObject:name];
        if (!firstID) {
            firstID = SPJSONString(item[@"id"]) ?: SPURIIDFromURI(SPJSONString(item[@"uri"]));
        }
    }
    *outNames = [names copy];
    *outFirstID = firstID;
}

+ (instancetype)albumFromPathfinderDict:(NSDictionary *)dict {
    if (!dict) return nil;
    NSString *uri = SPJSONString(dict[@"uri"]);
    NSString *albumID = SPJSONString(dict[@"id"]) ?: SPURIIDFromURIOfKind(uri, @"album") ?: SPURIIDFromURI(uri);
    if (!albumID.length) return nil;
    if (!uri.length) uri = [NSString stringWithFormat:@"spotify:album:%@", albumID];

    NSString *artLarge = nil, *artSmall = nil;
    SPExtractPathfinderImages(SPJSONDict(dict[@"coverArt"]), &artLarge, &artSmall);
    NSArray<NSString *> *artistNames = nil;
    NSString *firstArtistID = nil;
    ExtractAlbumArtists(SPJSONDict(dict[@"artists"]), &artistNames, &firstArtistID);

    return [[self alloc] initWithAlbumID:albumID
                                     uri:uri
                                    name:SPJSONString(dict[@"name"]) ?: @""
                               albumType:[SPJSONString(dict[@"type"]) lowercaseString]
                                artistID:firstArtistID
                              artistName:artistNames.firstObject ?: @"Unknown"
                             artistNames:artistNames
                             releaseDate:SPFormatPathfinderReleaseDate(SPJSONDict(dict[@"date"]))
                              artworkURL:artLarge
                         artworkSmallURL:artSmall
                                trackIDs:@[]
                         totalTrackCount:0
                         totalDurationMs:0
                           detailsLoaded:NO];
}

+ (instancetype)albumFromPathfinderUnion:(NSDictionary *)unionDict
                               tracksOut:(NSArray<SPTrack *> **)tracksOut
                                errorOut:(NSError **)errorOut {
    if (!unionDict) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"SPModel" code:404 userInfo:@{NSLocalizedDescriptionKey : @"Empty albumUnion"}];
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
    NSString *albumID = SPJSONString(unionDict[@"id"]) ?: SPURIIDFromURIOfKind(uri, @"album") ?: SPURIIDFromURI(uri);
    if (!albumID.length) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"SPModel" code:404 userInfo:@{NSLocalizedDescriptionKey : @"Album missing uri/id"}];
        return nil;
    }
    if (!uri.length) uri = [NSString stringWithFormat:@"spotify:album:%@", albumID];

    NSString *name = SPJSONString(unionDict[@"name"]) ?: @"";
    NSString *artLarge = nil, *artSmall = nil;
    SPExtractPathfinderImages(SPJSONDict(unionDict[@"coverArt"]), &artLarge, &artSmall);

    NSArray<NSString *> *artistNames = nil;
    NSString *firstArtistID = nil;
    ExtractAlbumArtists(SPJSONDict(unionDict[@"artists"]), &artistNames, &firstArtistID);

    NSDictionary *tracksV2 = SPJSONDict(unionDict[@"tracksV2"]);
    NSArray *rawItems = SPJSONArray(tracksV2[@"items"]);
    NSMutableArray<SPTrack *> *tracks = [NSMutableArray arrayWithCapacity:rawItems.count];
    NSMutableArray<NSString *> *trackIDs = [NSMutableArray arrayWithCapacity:rawItems.count];
    NSInteger totalDuration = 0;
    for (id raw in rawItems) {
        NSDictionary *entry = SPJSONDict(raw);
        NSDictionary *tDict = SPJSONDict(entry[@"track"]);
        SPTrack *t = [SPTrack trackFromPathfinderAlbumTrack:tDict
                                                    albumID:albumID
                                                  albumName:name
                                                 artworkURL:artLarge
                                            artworkSmallURL:artSmall];
        if (!t) continue;
        [tracks addObject:t];
        [trackIDs addObject:t.trackID];
        totalDuration += t.durationMs;
    }
    if (tracksOut) *tracksOut = [tracks copy];

    NSInteger totalCount = SPJSONInt(tracksV2[@"totalCount"], (NSInteger)tracks.count);
    return [[self alloc] initWithAlbumID:albumID
                                     uri:uri
                                    name:name
                               albumType:[SPJSONString(unionDict[@"type"]) lowercaseString]
                                artistID:firstArtistID
                              artistName:artistNames.firstObject ?: @"Unknown"
                             artistNames:artistNames
                             releaseDate:SPFormatPathfinderReleaseDate(SPJSONDict(unionDict[@"date"]))
                              artworkURL:artLarge
                         artworkSmallURL:artSmall
                                trackIDs:trackIDs
                         totalTrackCount:totalCount
                         totalDurationMs:totalDuration
                           detailsLoaded:YES];
}

+ (instancetype)albumFromPathfinderRelease:(NSDictionary *)dict
                                  artistID:(NSString *)artistID
                                artistName:(NSString *)artistName {
    if (!dict) return nil;
    NSString *uri = SPJSONString(dict[@"uri"]);
    NSString *albumID = SPJSONString(dict[@"id"]) ?: SPURIIDFromURIOfKind(uri, @"album") ?: SPURIIDFromURI(uri);
    if (!albumID.length) return nil;
    if (!uri.length) uri = [NSString stringWithFormat:@"spotify:album:%@", albumID];

    NSString *artLarge = nil, *artSmall = nil;
    SPExtractPathfinderImages(SPJSONDict(dict[@"coverArt"]), &artLarge, &artSmall);
    NSInteger trackCount = SPJSONInt(SPJSONDict(dict[@"tracks"])[@"totalCount"], 0);
    NSString *resolvedArtist = artistName.length ? artistName : @"Unknown";

    return [[self alloc] initWithAlbumID:albumID
                                     uri:uri
                                    name:SPJSONString(dict[@"name"]) ?: @""
                               albumType:[SPJSONString(dict[@"type"]) lowercaseString]
                                artistID:artistID
                              artistName:resolvedArtist
                             artistNames:@[ resolvedArtist ]
                             releaseDate:SPFormatPathfinderReleaseDate(SPJSONDict(dict[@"date"]))
                              artworkURL:artLarge
                         artworkSmallURL:artSmall
                                trackIDs:@[]
                         totalTrackCount:trackCount
                         totalDurationMs:0
                           detailsLoaded:NO];
}

@end
