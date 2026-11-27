// Immutable Spotify album model and Pathfinder decoders (zero retained raw JSON).
#import <Foundation/Foundation.h>

#import "model/track.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPAlbum : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *albumID;
@property (nonatomic, readonly, copy) NSString *uri;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy, nullable) NSString *albumType;
@property (nonatomic, readonly, copy, nullable) NSString *artistID;
@property (nonatomic, readonly, copy) NSString *artistName;
@property (nonatomic, readonly, copy) NSArray<NSString *> *artistNames;
@property (nonatomic, readonly, copy, nullable) NSString *releaseDate;
@property (nonatomic, readonly, copy, nullable) NSString *artworkURL;
@property (nonatomic, readonly, copy, nullable) NSString *artworkSmallURL;
@property (nonatomic, readonly, copy) NSArray<NSString *> *trackIDs;
@property (nonatomic, readonly) NSInteger totalTrackCount;
@property (nonatomic, readonly) NSInteger totalDurationMs;
@property (nonatomic, readonly) BOOL detailsLoaded;

- (instancetype)initWithAlbumID:(NSString *)albumID
                            uri:(NSString *)uri
                           name:(NSString *)name
                      albumType:(nullable NSString *)albumType
                       artistID:(nullable NSString *)artistID
                     artistName:(NSString *)artistName
                    artistNames:(NSArray<NSString *> *)artistNames
                    releaseDate:(nullable NSString *)releaseDate
                     artworkURL:(nullable NSString *)artworkURL
                artworkSmallURL:(nullable NSString *)artworkSmallURL
                       trackIDs:(NSArray<NSString *> *)trackIDs
                totalTrackCount:(NSInteger)totalTrackCount
                totalDurationMs:(NSInteger)totalDurationMs
                  detailsLoaded:(BOOL)detailsLoaded NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes a summary PathfinderAlbum (search, libraryV3, home).
+ (nullable instancetype)albumFromPathfinderDict:(nullable NSDictionary *)dict;

/// Decodes a full `getAlbum` response (`data.albumUnion`) plus its ordered tracks.
/// Sets `errorOut` when `__typename` is `NotFound` or another error union member.
+ (nullable instancetype)albumFromPathfinderUnion:(nullable NSDictionary *)unionDict
                                        tracksOut:(NSArray<SPTrack *> *_Nullable *_Nullable)tracksOut
                                         errorOut:(NSError *_Nullable *_Nullable)errorOut;

/// Decodes an artist discography release entry.
+ (nullable instancetype)albumFromPathfinderRelease:(nullable NSDictionary *)dict
                                           artistID:(nullable NSString *)artistID
                                         artistName:(nullable NSString *)artistName;
@end

NS_ASSUME_NONNULL_END
