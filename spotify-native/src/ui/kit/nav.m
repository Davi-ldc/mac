// Immutable navigation route value object.
#import "ui/kit/nav.h"

@implementation SPRoute

+ (instancetype)home { return [[self alloc] initWithKind:SPRouteHome entityID:nil]; }
+ (instancetype)search { return [[self alloc] initWithKind:SPRouteSearch entityID:nil]; }
+ (instancetype)favorites { return [[self alloc] initWithKind:SPRouteFavorites entityID:nil]; }
+ (instancetype)albums { return [[self alloc] initWithKind:SPRouteAlbums entityID:nil]; }
+ (instancetype)artists { return [[self alloc] initWithKind:SPRouteArtists entityID:nil]; }
+ (instancetype)playlists { return [[self alloc] initWithKind:SPRoutePlaylists entityID:nil]; }
+ (instancetype)queue { return [[self alloc] initWithKind:SPRouteQueue entityID:nil]; }
+ (instancetype)speakers { return [[self alloc] initWithKind:SPRouteSpeakers entityID:nil]; }
+ (instancetype)profile { return [[self alloc] initWithKind:SPRouteProfile entityID:nil]; }
+ (instancetype)albumWithID:(NSString *)albumID { return [[self alloc] initWithKind:SPRouteAlbumDetail entityID:albumID]; }
+ (instancetype)artistWithID:(NSString *)artistID { return [[self alloc] initWithKind:SPRouteArtistDetail entityID:artistID]; }
+ (instancetype)playlistWithID:(NSString *)playlistID { return [[self alloc] initWithKind:SPRoutePlaylistDetail entityID:playlistID]; }

- (instancetype)initWithKind:(SPRouteKind)kind entityID:(NSString *)entityID {
    if (!(self = [super init])) return nil;
    _kind = kind;
    _entityID = [entityID copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:SPRoute.class]) return NO;
    SPRoute *other = (SPRoute *)object;
    if (_kind != other->_kind) return NO;
    return (_entityID == other->_entityID) || (_entityID && other->_entityID && [_entityID isEqualToString:other->_entityID]);
}

- (NSUInteger)hash {
    return (NSUInteger)_kind * 31u ^ _entityID.hash;
}

@end
