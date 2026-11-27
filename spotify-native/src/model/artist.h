// Immutable Spotify artist model and Pathfinder decoders (zero retained raw JSON).
#import <Foundation/Foundation.h>

#import "model/album.h"
#import "model/track.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPArtist : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *artistID;
@property (nonatomic, readonly, copy) NSString *uri;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy, nullable) NSString *artworkURL;
@property (nonatomic, readonly, copy, nullable) NSString *artworkSmallURL;
@property (nonatomic, readonly, copy) NSArray<NSString *> *albumIDs;
@property (nonatomic, readonly, copy) NSArray<NSString *> *topTrackIDs;
@property (nonatomic, readonly) BOOL detailsLoaded;

- (instancetype)initWithArtistID:(NSString *)artistID
                             uri:(NSString *)uri
                            name:(NSString *)name
                      artworkURL:(nullable NSString *)artworkURL
                 artworkSmallURL:(nullable NSString *)artworkSmallURL
                        albumIDs:(NSArray<NSString *> *)albumIDs
                     topTrackIDs:(NSArray<NSString *> *)topTrackIDs
                   detailsLoaded:(BOOL)detailsLoaded NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithArtistID:(NSString *)artistID
                             uri:(NSString *)uri
                            name:(NSString *)name
                      artworkURL:(nullable NSString *)artworkURL
                 artworkSmallURL:(nullable NSString *)artworkSmallURL
                        albumIDs:(NSArray<NSString *> *)albumIDs
                   detailsLoaded:(BOOL)detailsLoaded;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes a summary PathfinderArtist (search, libraryV3, home, userTopContent).
+ (nullable instancetype)artistFromPathfinderDict:(nullable NSDictionary *)dict;

/// Decodes `queryArtistOverview` or `queryArtistDiscographyAll` (`data.artistUnion`),
/// returning deduplicated discography albums in `albumsOut` and popular tracks in `topTracksOut`.
+ (nullable instancetype)artistFromPathfinderUnion:(nullable NSDictionary *)unionDict
                                         albumsOut:(NSArray<SPAlbum *> *_Nullable *_Nullable)albumsOut
                                      topTracksOut:(NSArray<SPTrack *> *_Nullable *_Nullable)topTracksOut
                                          errorOut:(NSError *_Nullable *_Nullable)errorOut;
+ (nullable instancetype)artistFromPathfinderUnion:(nullable NSDictionary *)unionDict
                                         albumsOut:(NSArray<SPAlbum *> *_Nullable *_Nullable)albumsOut
                                          errorOut:(NSError *_Nullable *_Nullable)errorOut;
@end

NS_ASSUME_NONNULL_END
