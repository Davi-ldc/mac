// Immutable Spotify playlist & playlist item models and Pathfinder decoders (zero retained raw JSON).
#import <Foundation/Foundation.h>

#import "model/track.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SPLikedSongsPlaylistURI;
extern NSString *const SPLikedSongsCollectionURI;

@interface SPPlaylistItem : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *trackID;
@property (nonatomic, readonly, copy) NSString *uid;
@property (nonatomic, readonly) double addedAt;

- (instancetype)initWithTrackID:(NSString *)trackID uid:(NSString *)uid addedAt:(double)addedAt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPPlaylist : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *playlistID;
@property (nonatomic, readonly, copy) NSString *uri;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy, nullable) NSString *playlistDescription;
@property (nonatomic, readonly, copy) NSString *ownerID;
@property (nonatomic, readonly, copy) NSString *ownerName;
@property (nonatomic, readonly, copy, nullable) NSString *artworkURL;
@property (nonatomic, readonly, copy, nullable) NSString *artworkSmallURL;
@property (nonatomic, readonly) BOOL isPublic;
@property (nonatomic, readonly, copy) NSArray<SPPlaylistItem *> *items;
@property (nonatomic, readonly) NSInteger totalTrackCount;
@property (nonatomic, readonly) BOOL detailsLoaded;

- (instancetype)initWithPlaylistID:(NSString *)playlistID
                               uri:(NSString *)uri
                              name:(NSString *)name
               playlistDescription:(nullable NSString *)playlistDescription
                           ownerID:(NSString *)ownerID
                         ownerName:(NSString *)ownerName
                        artworkURL:(nullable NSString *)artworkURL
                   artworkSmallURL:(nullable NSString *)artworkSmallURL
                          isPublic:(BOOL)isPublic
                             items:(NSArray<SPPlaylistItem *> *)items
                   totalTrackCount:(NSInteger)totalTrackCount
                     detailsLoaded:(BOOL)detailsLoaded NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes a summary PathfinderPlaylist (search, libraryV3, home). Drops playlist folders by kind-checking the URI.
+ (nullable instancetype)playlistFromPathfinderDict:(nullable NSDictionary *)dict;

/// Decodes `fetchPlaylist` (`data.playlistV2`) plus its tracks. Sets `errorOut` on `NotFound`/error union members.
+ (nullable instancetype)playlistFromPathfinderUnion:(nullable NSDictionary *)unionDict
                                           tracksOut:(NSArray<SPTrack *> *_Nullable *_Nullable)tracksOut
                                            errorOut:(NSError *_Nullable *_Nullable)errorOut;

/// Decodes `fetchPlaylistContents` (`data.playlistV2`), used for Liked Songs and subsequent playlist pages.
+ (NSArray<SPTrack *> *)tracksFromPathfinderContentsUnion:(nullable NSDictionary *)unionDict
                                                 itemsOut:(NSArray<SPPlaylistItem *> *_Nullable *_Nullable)itemsOut
                                                 totalOut:(NSInteger *_Nullable)totalOut
                                              rawCountOut:(NSInteger *_Nullable)rawCountOut;
@end

NS_ASSUME_NONNULL_END
