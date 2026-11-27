// Immutable Spotify track model and Pathfinder/spclient decoders (zero retained raw JSON).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPTrack : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *trackID;
@property (nonatomic, readonly, copy) NSString *uri;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy, nullable) NSString *albumID;
@property (nonatomic, readonly, copy, nullable) NSString *albumName;
@property (nonatomic, readonly, copy, nullable) NSString *artistID;
@property (nonatomic, readonly, copy) NSString *artistName;
@property (nonatomic, readonly, copy) NSArray<NSString *> *artistNames;
@property (nonatomic, readonly) NSInteger durationMs;
@property (nonatomic, readonly) NSInteger trackNumber;
@property (nonatomic, readonly) NSInteger discNumber;
@property (nonatomic, readonly, copy, nullable) NSString *artworkURL;
@property (nonatomic, readonly, copy, nullable) NSString *artworkSmallURL;
@property (nonatomic, readonly) BOOL playable;
@property (nonatomic, readonly, copy, nullable) NSString *unplayableReason;

- (instancetype)initWithTrackID:(NSString *)trackID
                            uri:(NSString *)uri
                           name:(NSString *)name
                        albumID:(nullable NSString *)albumID
                      albumName:(nullable NSString *)albumName
                       artistID:(nullable NSString *)artistID
                     artistName:(NSString *)artistName
                    artistNames:(NSArray<NSString *> *)artistNames
                     durationMs:(NSInteger)durationMs
                    trackNumber:(NSInteger)trackNumber
                     discNumber:(NSInteger)discNumber
                     artworkURL:(nullable NSString *)artworkURL
                artworkSmallURL:(nullable NSString *)artworkSmallURL
                       playable:(BOOL)playable
               unplayableReason:(nullable NSString *)unplayableReason NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes a Pathfinder Track (search, searchDesktop, userTopContent).
+ (nullable instancetype)trackFromPathfinderDict:(nullable NSDictionary *)dict;

/// Decodes a track from `getAlbum` `tracksV2.items[].track`.
+ (nullable instancetype)trackFromPathfinderAlbumTrack:(nullable NSDictionary *)dict
                                               albumID:(NSString *)albumID
                                             albumName:(nullable NSString *)albumName
                                            artworkURL:(nullable NSString *)artworkURL
                                       artworkSmallURL:(nullable NSString *)artworkSmallURL;

/// Decodes a track from `fetchPlaylist` / `fetchPlaylistContents` `itemV2.data`.
+ (nullable instancetype)trackFromPathfinderPlaylistTrack:(nullable NSDictionary *)dict;

/// Decodes `spclient` `metadata/4/track/{gid}` keyed by `requestedID`.
+ (nullable instancetype)trackFromSpclientDict:(nullable NSDictionary *)dict requestedID:(NSString *)requestedID;
@end

NS_ASSUME_NONNULL_END
