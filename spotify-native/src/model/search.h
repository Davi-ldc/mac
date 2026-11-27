// Immutable search results & typeahead suggestion models (`searchDesktop` + `searchSuggestions`).
#import <Foundation/Foundation.h>

#import "model/album.h"
#import "model/artist.h"
#import "model/playlist.h"
#import "model/track.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPSearchSuggestionKind) {
    SPSearchSuggestionQuery = 0,
    SPSearchSuggestionTrack = 1,
    SPSearchSuggestionAlbum = 2,
    SPSearchSuggestionArtist = 3,
    SPSearchSuggestionPlaylist = 4,
};

@interface SPSearchSuggestion : NSObject <NSCopying>
@property (nonatomic, readonly) SPSearchSuggestionKind kind;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, copy, nullable) NSString *entityID;
@property (nonatomic, readonly, copy, nullable) NSString *subtitle;
@property (nonatomic, readonly, copy, nullable) NSString *artworkURL;

- (instancetype)initWithKind:(SPSearchSuggestionKind)kind
                        text:(NSString *)text
                    entityID:(nullable NSString *)entityID
                    subtitle:(nullable NSString *)subtitle
                  artworkURL:(nullable NSString *)artworkURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SPSearchResults : NSObject
@property (nonatomic, readonly, copy) NSString *query;
@property (nonatomic, readonly, copy) NSArray<SPSearchSuggestion *> *topHits;
@property (nonatomic, readonly, copy) NSArray<SPTrack *> *tracks;
@property (nonatomic, readonly, copy) NSArray<SPAlbum *> *albums;
@property (nonatomic, readonly, copy) NSArray<SPArtist *> *artists;
@property (nonatomic, readonly, copy) NSArray<SPPlaylist *> *playlists;
@property (nonatomic, readonly) NSInteger tracksTotal;
@property (nonatomic, readonly) NSInteger albumsTotal;
@property (nonatomic, readonly) NSInteger artistsTotal;
@property (nonatomic, readonly) NSInteger playlistsTotal;
@property (nonatomic, readonly, copy) NSArray<SPSearchSuggestion *> *suggestions;
@property (nonatomic, readonly) BOOL isLocalOnly;

- (instancetype)initWithQuery:(NSString *)query
                      topHits:(NSArray<SPSearchSuggestion *> *)topHits
                       tracks:(NSArray<SPTrack *> *)tracks
                       albums:(NSArray<SPAlbum *> *)albums
                      artists:(NSArray<SPArtist *> *)artists
                    playlists:(NSArray<SPPlaylist *> *)playlists
                  tracksTotal:(NSInteger)tracksTotal
                  albumsTotal:(NSInteger)albumsTotal
                 artistsTotal:(NSInteger)artistsTotal
               playlistsTotal:(NSInteger)playlistsTotal
                  suggestions:(NSArray<SPSearchSuggestion *> *)suggestions
                  isLocalOnly:(BOOL)isLocalOnly NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes a single-request `searchDesktop` Pathfinder response (`data.searchV2`).
+ (instancetype)resultsFromSearchDesktopJSON:(nullable NSDictionary *)root query:(NSString *)query;

/// Decodes `searchSuggestions` typeahead entries (`data.searchV2.topResultsV2.itemsV2`).
+ (NSArray<SPSearchSuggestion *> *)suggestionsFromSearchSuggestionsJSON:(nullable NSDictionary *)root;

/// Category pagination decoders for `searchTracks`, `searchAlbums`, `searchArtists`, `searchPlaylists`.
+ (NSArray<SPTrack *> *)tracksPageFromSearchJSON:(nullable NSDictionary *)root totalOut:(NSInteger *_Nullable)totalOut sentOut:(NSInteger *_Nullable)sentOut;
+ (NSArray<SPAlbum *> *)albumsPageFromSearchJSON:(nullable NSDictionary *)root totalOut:(NSInteger *_Nullable)totalOut sentOut:(NSInteger *_Nullable)sentOut;
+ (NSArray<SPArtist *> *)artistsPageFromSearchJSON:(nullable NSDictionary *)root totalOut:(NSInteger *_Nullable)totalOut sentOut:(NSInteger *_Nullable)sentOut;
+ (NSArray<SPPlaylist *> *)playlistsPageFromSearchJSON:(nullable NSDictionary *)root totalOut:(NSInteger *_Nullable)totalOut sentOut:(NSInteger *_Nullable)sentOut;

/// Merges immediate local library results with remote `searchDesktop` & `searchSuggestions`, deduplicated by ID.
+ (instancetype)mergedLocalResults:(SPSearchResults *)local
                     remoteResults:(nullable SPSearchResults *)remote
                       suggestions:(nullable NSArray<SPSearchSuggestion *> *)suggestions;
@end

NS_ASSUME_NONNULL_END
