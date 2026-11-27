// Immutable Spotify track model and Pathfinder/spclient decoders.
#import "model/track.h"
#import "model/json.h"

static void ExtractPathfinderArtists(NSDictionary *artistsDict,
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

static void ExtractPlayability(NSDictionary *playabilityDict, BOOL *outPlayable, NSString **outReason) {
    if (!playabilityDict) {
        *outPlayable = YES;
        *outReason = nil;
        return;
    }
    BOOL playable = SPJSONBool(playabilityDict[@"playable"], YES);
    *outPlayable = playable;
    *outReason = playable ? nil : SPJSONString(playabilityDict[@"reason"]);
}

@implementation SPTrack

- (instancetype)initWithTrackID:(NSString *)trackID
                            uri:(NSString *)uri
                           name:(NSString *)name
                        albumID:(NSString *)albumID
                      albumName:(NSString *)albumName
                       artistID:(NSString *)artistID
                     artistName:(NSString *)artistName
                    artistNames:(NSArray<NSString *> *)artistNames
                     durationMs:(NSInteger)durationMs
                    trackNumber:(NSInteger)trackNumber
                     discNumber:(NSInteger)discNumber
                     artworkURL:(NSString *)artworkURL
                artworkSmallURL:(NSString *)artworkSmallURL
                       playable:(BOOL)playable
               unplayableReason:(NSString *)unplayableReason {
    if (!(self = [super init])) return nil;
    _trackID = [trackID copy];
    _uri = [uri copy];
    _name = [name copy];
    _albumID = [albumID copy];
    _albumName = [albumName copy];
    _artistID = [artistID copy];
    _artistName = [artistName copy];
    _artistNames = [artistNames copy];
    _durationMs = durationMs;
    _trackNumber = trackNumber;
    _discNumber = discNumber;
    _artworkURL = [artworkURL copy];
    _artworkSmallURL = [artworkSmallURL copy];
    _playable = playable;
    _unplayableReason = [unplayableReason copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPTrack.class]) return NO;
    return [_trackID isEqualToString:((SPTrack *)object)->_trackID];
}

- (NSUInteger)hash { return _trackID.hash; }

+ (instancetype)trackFromPathfinderDict:(NSDictionary *)dict {
    if (!dict) return nil;
    NSString *uri = SPJSONString(dict[@"uri"]);
    NSString *trackID = SPJSONString(dict[@"id"]) ?: SPURIIDFromURIOfKind(uri, @"track") ?: SPURIIDFromURI(uri);
    if (!trackID.length) return nil;
    if (!uri.length) uri = [NSString stringWithFormat:@"spotify:track:%@", trackID];

    NSString *name = SPJSONString(dict[@"name"]) ?: @"";
    NSDictionary *album = SPJSONDict(dict[@"albumOfTrack"]);
    NSString *albumURI = SPJSONString(album[@"uri"]);
    NSString *albumID = SPJSONString(album[@"id"]) ?: SPURIIDFromURI(albumURI);
    NSString *albumName = SPJSONString(album[@"name"]);
    NSString *artLarge = nil, *artSmall = nil;
    SPExtractPathfinderImages(SPJSONDict(album[@"coverArt"]), &artLarge, &artSmall);

    NSArray<NSString *> *artistNames = nil;
    NSString *firstArtistID = nil;
    ExtractPathfinderArtists(SPJSONDict(dict[@"artists"]), &artistNames, &firstArtistID);

    NSDictionary *dur = SPJSONDict(dict[@"duration"]) ?: SPJSONDict(dict[@"trackDuration"]);
    NSInteger durationMs = SPJSONInt(dur[@"totalMilliseconds"], 0);

    BOOL playable = YES;
    NSString *reason = nil;
    ExtractPlayability(SPJSONDict(dict[@"playability"]), &playable, &reason);

    return [[self alloc] initWithTrackID:trackID
                                     uri:uri
                                    name:name
                                 albumID:albumID
                               albumName:albumName
                                artistID:firstArtistID
                              artistName:artistNames.firstObject ?: @"Unknown"
                             artistNames:artistNames
                              durationMs:durationMs
                             trackNumber:SPJSONInt(dict[@"trackNumber"], 0)
                              discNumber:SPJSONInt(dict[@"discNumber"], 0)
                              artworkURL:artLarge
                         artworkSmallURL:artSmall
                                playable:playable
                        unplayableReason:reason];
}

+ (instancetype)trackFromPathfinderAlbumTrack:(NSDictionary *)dict
                                      albumID:(NSString *)albumID
                                    albumName:(NSString *)albumName
                                   artworkURL:(NSString *)artworkURL
                              artworkSmallURL:(NSString *)artworkSmallURL {
    if (!dict) return nil;
    NSString *uri = SPJSONString(dict[@"uri"]);
    NSString *trackID = SPURIIDFromURIOfKind(uri, @"track") ?: SPURIIDFromURI(uri);
    if (!trackID.length || !uri.length) return nil;

    NSArray<NSString *> *artistNames = nil;
    NSString *firstArtistID = nil;
    ExtractPathfinderArtists(SPJSONDict(dict[@"artists"]), &artistNames, &firstArtistID);

    NSInteger durationMs = SPJSONInt(SPJSONDict(dict[@"duration"])[@"totalMilliseconds"], 0);
    BOOL playable = YES;
    NSString *reason = nil;
    ExtractPlayability(SPJSONDict(dict[@"playability"]), &playable, &reason);

    return [[self alloc] initWithTrackID:trackID
                                     uri:uri
                                    name:SPJSONString(dict[@"name"]) ?: @""
                                 albumID:albumID
                               albumName:albumName
                                artistID:firstArtistID
                              artistName:artistNames.firstObject ?: @"Unknown"
                             artistNames:artistNames
                              durationMs:durationMs
                             trackNumber:SPJSONInt(dict[@"trackNumber"], 0)
                              discNumber:SPJSONInt(dict[@"discNumber"], 0)
                              artworkURL:artworkURL
                         artworkSmallURL:artworkSmallURL
                                playable:playable
                        unplayableReason:reason];
}

+ (instancetype)trackFromPathfinderPlaylistTrack:(NSDictionary *)dict {
    if (!dict) return nil;
    // Reject non-tracks such as episodes or tombstones lacking a spotify:track: URI.
    NSString *uri = SPJSONString(dict[@"uri"]);
    NSString *trackID = SPURIIDFromURIOfKind(uri, @"track");
    if (!trackID.length) return nil;
    return [self trackFromPathfinderDict:dict];
}

+ (instancetype)trackFromSpclientDict:(NSDictionary *)dict requestedID:(NSString *)requestedID {
    if (!dict || !requestedID.length) return nil;
    NSString *name = SPJSONString(dict[@"name"]);
    if (!name.length) return nil;

    NSDictionary *album = SPJSONDict(dict[@"album"]);
    NSString *albumID = SPHexGIDToBase62(SPJSONString(album[@"gid"]));
    NSString *albumName = SPJSONString(album[@"name"]);
    NSString *artLarge = nil, *artSmall = nil;
    SPExtractSpclientImages(SPJSONArray(SPJSONDict(album[@"cover_group"])[@"image"]), &artLarge, &artSmall);

    NSMutableArray<NSString *> *artistNames = [NSMutableArray new];
    NSString *firstArtistID = nil;
    for (id raw in SPJSONArray(dict[@"artist"])) {
        NSDictionary *a = SPJSONDict(raw);
        if (!a) continue;
        NSString *aname = SPJSONString(a[@"name"]);
        if (aname.length) [artistNames addObject:aname];
        if (!firstArtistID) firstArtistID = SPHexGIDToBase62(SPJSONString(a[@"gid"]));
    }

    // Withheld only when a restriction allows no countries for premium AND no relinked alternative exists.
    BOOL withheld = NO;
    NSArray *alternatives = SPJSONArray(dict[@"alternative"]);
    if (alternatives.count == 0) {
        for (id raw in SPJSONArray(dict[@"restriction"])) {
            NSDictionary *r = SPJSONDict(raw);
            NSString *allowed = SPJSONString(r[@"countries_allowed"]);
            if (allowed && allowed.length == 0) {
                NSArray *catalogues = SPJSONArray(r[@"catalogue_str"]);
                if (!catalogues || [catalogues containsObject:@"premium"]) {
                    withheld = YES;
                    break;
                }
            }
        }
    }

    return [[self alloc] initWithTrackID:requestedID
                                     uri:[NSString stringWithFormat:@"spotify:track:%@", requestedID]
                                    name:name
                                 albumID:albumID
                               albumName:albumName
                                artistID:firstArtistID
                              artistName:artistNames.firstObject ?: @"Unknown"
                             artistNames:artistNames
                              durationMs:SPJSONInt(dict[@"duration"], 0)
                             trackNumber:SPJSONInt(dict[@"number"], 0)
                              discNumber:SPJSONInt(dict[@"disc_number"], 0)
                              artworkURL:artLarge
                         artworkSmallURL:artSmall
                                playable:!withheld
                        unplayableReason:withheld ? @"COUNTRY_RESTRICTED" : nil];
}

@end
