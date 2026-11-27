// Immutable Home shelf, Home page, and User Profile models with Pathfinder decoders.
#import <Foundation/Foundation.h>

#import "model/album.h"
#import "model/artist.h"
#import "model/playlist.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPShelfItemKind) {
    SPShelfItemAlbum = 0,
    SPShelfItemArtist = 1,
    SPShelfItemPlaylist = 2,
};

@interface SPShelfItem : NSObject <NSCopying>
@property (nonatomic, readonly) SPShelfItemKind kind;
@property (nonatomic, readonly, copy) NSString *entityID;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *subtitle;
@property (nonatomic, readonly, copy, nullable) NSString *artworkURL;

- (instancetype)initWithKind:(SPShelfItemKind)kind
                    entityID:(NSString *)entityID
                       title:(NSString *)title
                    subtitle:(nullable NSString *)subtitle
                  artworkURL:(nullable NSString *)artworkURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPHomeShelf : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *shelfID;
@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly) BOOL isRecentlyPlayed;
@property (nonatomic, readonly, copy) NSArray<SPShelfItem *> *items;

- (instancetype)initWithShelfID:(NSString *)shelfID
                          title:(nullable NSString *)title
               isRecentlyPlayed:(BOOL)isRecentlyPlayed
                          items:(NSArray<SPShelfItem *> *)items NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPHomePage : NSObject
@property (nonatomic, readonly, copy) NSArray<SPHomeShelf *> *shelves;
@property (nonatomic, readonly, copy) NSArray<SPAlbum *> *albums;
@property (nonatomic, readonly, copy) NSArray<SPArtist *> *artists;
@property (nonatomic, readonly, copy) NSArray<SPPlaylist *> *playlists;

- (instancetype)initWithShelves:(NSArray<SPHomeShelf *> *)shelves
                         albums:(NSArray<SPAlbum *> *)albums
                        artists:(NSArray<SPArtist *> *)artists
                      playlists:(NSArray<SPPlaylist *> *)playlists NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes a Pathfinder `home` response (`{data:{home:{...}}}`).
/// Rejects non-`HomeResponsePayload` union members (e.g. `GenericError` returned as HTTP 200).
+ (nullable instancetype)homePageFromPathfinderJSON:(nullable NSDictionary *)root errorOut:(NSError *_Nullable *_Nullable)errorOut;
@end

@interface SPUserProfile : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *username;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *uri;
@property (nonatomic, readonly, copy, nullable) NSString *avatarURL;

- (instancetype)initWithUsername:(NSString *)username
                     displayName:(NSString *)displayName
                             uri:(NSString *)uri
                       avatarURL:(nullable NSString *)avatarURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (nullable instancetype)profileFromPathfinderJSON:(nullable NSDictionary *)root;
@end

NS_ASSUME_NONNULL_END
